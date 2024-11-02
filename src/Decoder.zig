const std = @import("std");
const erl = @import("erlang.zig");

const assert = std.debug.assert;
const ei = erl.ei;
const testing = std.testing;

const Decoder = @This();

pub const Error = std.mem.Allocator.Error || error{
    could_not_decode_string,
    decoding_atom,
    decoding_tuple,
    wrong_tuple_size,
    decoding_map,
    too_many_map_entries,
    too_few_map_entries,
    missing_field_in_struct,
    decoding_double,
    decoding_signed_integer,
    decoding_unsigned_integer,
    integer_out_of_bounds,
    invalid_tag_to_enum,
    could_not_decode_enum,
    could_not_get_type,
    invalid_union_tag,
    wrong_arity_for_tuple,
    failed_to_receive_payload,
    unknown_tuple_tag,
    unsupported_pointer_type,
    decoding_list_in_pointer_1,
    decoding_list_in_pointer_2,
    decoded_improper_list,
    decoding_list_in_array_1,
    wrong_array_size,
    decoding_list_in_array_2,
    decoding_boolean,
    invalid_pid,
};

buf: *ei.ei_x_buff,
index: *c_int,
allocator: std.mem.Allocator,

fn parse_string(self: Decoder) Error![:0]const u8 {
    var length: c_int = 0;
    var ty: c_int = 0;
    try erl.validate(
        error.could_not_get_type,
        ei.ei_get_type(self.buf.buff, self.index, &ty, &length),
    );
    if (ty != ei.ERL_STRING_EXT) return error.could_not_decode_string;

    const u_length: c_uint = @intCast(length);

    const buffer = try self.allocator.allocSentinel(u8, u_length, 0);
    errdefer self.allocator.free(buffer);

    try erl.validate(
        error.could_not_decode_string,
        ei.ei_decode_string(self.buf.buff, self.index, buffer.ptr),
    );
    return buffer;
}

test parse_string {
    var buf: ei.ei_x_buff = undefined;
    try erl.validate(error.create_new_decode_buff, ei.ei_x_new(&buf));
    defer _ = ei.ei_x_free(&buf);

    const written: [:0]const u8 = "We are the champions";

    var index: c_int = 0;
    try erl.encoder.write_any(&buf, written);

    const decoder = Decoder{
        .buf = &buf,
        .index = &index,
        .allocator = testing.allocator,
    };

    const read = try decoder.parse([:0]const u8);
    defer testing.allocator.free(read);

    try testing.expectEqualStrings(written, read);
}

fn parse_tuple(self: Decoder, comptime T: type) Error!T {
    const type_info = @typeInfo(T).Struct;
    comptime assert(type_info.is_tuple);
    var value: T = undefined;
    var size: c_int = 0;
    try erl.validate(
        error.decoding_tuple,
        ei.ei_decode_tuple_header(self.buf.buff, self.index, &size),
    );
    if (type_info.fields.len != size) return error.wrong_tuple_size;
    inline for (&value) |*elem| {
        elem.* = try self.parse(@TypeOf(elem.*));
    }
    return value;
}

test parse_tuple {
    // We need the comptime field here in 0.13.0 because of a bug.
    // Problem is fixed in zig master.
    const Point = struct { comptime enum { point } = .point, i32, i32 };
    const point = Point{ .point, 413, 612 };

    var buf: ei.ei_x_buff = undefined;
    try erl.validate(error.create_new_decode_buff, ei.ei_x_new(&buf));
    defer _ = ei.ei_x_free(&buf);

    var index: c_int = 0;
    try erl.encoder.write_any(&buf, point);

    const decoder = Decoder{
        .buf = &buf,
        .index = &index,
        .allocator = testing.failing_allocator,
    };

    try testing.expectEqual(point, decoder.parse_tuple(Point));
}

fn parse_struct(self: Decoder, comptime T: type) Error!T {
    comptime assert(!@typeInfo(T).Struct.is_tuple);

    const Key = std.meta.FieldEnum(T);
    const Key_Set = std.EnumSet(Key);
    const total_keys = comptime Key_Set.initFull().count();
    if (total_keys == 0) @compileError("Cannot parse struct with no fields");

    const size: c_int = blk: {
        var size: c_int = 0;
        try erl.validate(
            error.decoding_map,
            ei.ei_decode_map_header(self.buf.buff, self.index, &size),
        );
        break :blk size;
    };
    if (total_keys < size) return error.too_many_map_entries;

    var value: T = undefined;
    var present_keys = Key_Set.initEmpty();
    for (0..@intCast(size)) |_| {
        switch (try self.parse_enum(Key)) {
            inline else => |key| {
                const current_field = &@field(value, @tagName(key));
                const field_type = @TypeOf(current_field.*);
                if (@typeInfo(field_type) == .Optional) {
                    current_field.* = try self.parse(field_type.Optional.child);
                } else {
                    current_field.* = try self.parse(field_type);
                }
                present_keys.insert(key);
            },
        }
    }
    assert(size == present_keys.count());

    var should_error = false;
    var missing_keys = present_keys.complement().iterator();
    while (missing_keys.next()) |key_rt| {
        switch (key_rt) {
            inline else => |key| {
                const field = comptime blk: {
                    for (@typeInfo(T).Struct.fields) |field| {
                        if (std.mem.eql(u8, field.name, @tagName(key)))
                            break :blk field;
                    }
                };
                const current_field = &@field(value, field.name);
                if (field.default_value) |default| {
                    current_field.* = @as(
                        *const field.type,
                        @alignCast(@ptrCast(default)),
                    ).*;
                } else if (@typeInfo(field.type) == .Optional) {
                    current_field.* = null;
                } else {
                    std.log.err("[zerl] missing field in struct {s}: {s}\n", .{
                        @typeName(T),
                        field.name,
                    });
                    should_error = true;
                }
            },
        }
    }
    return if (should_error) error.missing_field_in_struct else value;
}

test parse_struct {
    // TODO: optional fields and fields with default values
    const Point = struct { x: i32, y: i32 };
    const point = Point{ .x = 413, .y = 612 };

    var buf: ei.ei_x_buff = undefined;
    try erl.validate(error.create_new_decode_buff, ei.ei_x_new(&buf));
    defer _ = ei.ei_x_free(&buf);

    var index: c_int = 0;
    try erl.encoder.write_any(&buf, point);

    const decoder = Decoder{
        .buf = &buf,
        .index = &index,
        .allocator = testing.failing_allocator,
    };

    try testing.expectEqual(point, decoder.parse_struct(Point));
}

fn parse_int(self: Decoder, comptime T: type) Error!T {
    // TODO: support larger integer sizes
    comptime assert(@bitSizeOf(T) <= @bitSizeOf(c_longlong));
    const N, const error_tag, const decode =
        if (@typeInfo(T).Int.signedness == .signed)
        .{
            c_longlong,
            error.decoding_signed_integer,
            ei.ei_decode_longlong,
        }
    else
        .{
            c_ulonglong,
            error.decoding_unsigned_integer,
            ei.ei_decode_ulonglong,
        };

    var n: N = undefined;
    try erl.validate(error_tag, decode(self.buf.buff, self.index, &n));
    return if (std.math.minInt(T) <= n and n <= std.math.maxInt(T))
        @intCast(n)
    else
        error.integer_out_of_bounds;
}

test parse_int {
    var buf: ei.ei_x_buff = undefined;
    try erl.validate(error.create_new_decode_buff, ei.ei_x_new(&buf));
    defer _ = ei.ei_x_free(&buf);

    var index: c_int = 0;

    try erl.encoder.write_any(&buf, 413);
    try erl.encoder.write_any(&buf, -612);
    try erl.encoder.write_any(&buf, 1025);
    try erl.encoder.write_any(&buf, -111111);

    const decoder = Decoder{
        .buf = &buf,
        .index = &index,
        .allocator = testing.failing_allocator,
    };

    try testing.expectEqual(413, decoder.parse(u32));
    try testing.expectEqual(-612, decoder.parse(i32));
    try testing.expectEqual(error.integer_out_of_bounds, decoder.parse(u8));
    try testing.expectEqual(error.integer_out_of_bounds, decoder.parse(i8));
}

fn parse_float(self: Decoder, comptime T: type) Error!T {
    comptime assert(@typeInfo(T) == .Float);
    var aux: f64 = undefined;
    try erl.validate(error.decoding_double, ei.ei_decode_double(
        self.buf.buff,
        self.index,
        &aux,
    ));
    return @floatCast(aux);
}

test parse_float {
    var buf: ei.ei_x_buff = undefined;
    try erl.validate(error.create_new_decode_buff, ei.ei_x_new(&buf));
    defer _ = ei.ei_x_free(&buf);

    var index: c_int = 0;

    try erl.encoder.write_any(&buf, std.math.pi);
    try erl.encoder.write_any(&buf, std.math.pi);
    try erl.encoder.write_any(&buf, std.math.pi);

    const decoder = Decoder{
        .buf = &buf,
        .index = &index,
        .allocator = testing.failing_allocator,
    };

    try testing.expectEqual(std.math.pi, decoder.parse(f16));
    try testing.expectEqual(std.math.pi, decoder.parse(f32));
    try testing.expectEqual(std.math.pi, decoder.parse(f64));
}

fn parse_enum(self: Decoder, comptime T: type) Error!T {
    const tag_map, const max_name_length = comptime blk: {
        var tags = std.EnumSet(T).initFull();
        var max_name_length = 0;
        const enum_fields = @typeInfo(T).Enum.fields;
        if (enum_fields.len == 0) {
            @compileError("Impossible to parse enum with no fields");
        }
        for (enum_fields) |field| {
            if (ei.MAXATOMLEN < field.name.len) {
                tags.remove(@enumFromInt(field.value));
            } else {
                max_name_length = @max(max_name_length, field.name.len);
            }
        }
        if (tags.count() == 0) {
            @compileError("All enum tags longer than max atom length");
        }
        var tag_map: [tags.count()]struct { []const u8, T } = undefined;
        var tag_iter = tags.iterator();
        var tag_index = 0;
        while (tag_iter.next()) |tag| {
            tag_map[tag_index] = .{ @tagName(tag), tag };
            tag_index += 1;
        }
        break :blk .{
            std.StaticStringMap(T).initComptime(tag_map),
            max_name_length,
        };
    };

    var type_tag: c_int = 0;
    var atom_size: c_int = 0;
    try erl.validate(
        error.could_not_get_type,
        ei.ei_get_type(self.buf.buff, self.index, &type_tag, &atom_size),
    );
    if (max_name_length < atom_size) return error.could_not_decode_enum;

    var atom_name: [max_name_length + 1]u8 = undefined;
    try erl.validate(
        error.decoding_atom,
        ei.ei_decode_atom(self.buf.buff, self.index, &atom_name),
    );
    const name = atom_name[0..@as(c_uint, @intCast(atom_size))];
    return tag_map.get(name) orelse error.could_not_decode_enum;
}

test parse_enum {
    const Suit = enum { diamonds, clubs, hearts, spades };

    var buf: ei.ei_x_buff = undefined;
    try erl.validate(error.create_new_decode_buff, ei.ei_x_new(&buf));
    defer _ = ei.ei_x_free(&buf);

    var index: c_int = 0;

    try erl.encoder.write_any(&buf, Suit.spades);

    const decoder = Decoder{
        .buf = &buf,
        .index = &index,
        .allocator = testing.failing_allocator,
    };

    try testing.expectEqual(Suit.spades, decoder.parse_enum(Suit));

}

fn parse_union(self: Decoder, comptime T: type) Error!T {
    const Tag = @typeInfo(T).Union.tag_type.?;
    const fields = @typeInfo(T).Union.fields;

    var arity: c_int = 0;
    var type_tag: c_int = 0;
    var _v: c_int = undefined;
    try erl.validate(
        error.could_not_get_type,
        ei.ei_get_type(self.buf.buff, self.index, &type_tag, &_v),
    );
    if (type_tag == ei.ERL_ATOM_EXT) {
        switch (try self.parse_enum(Tag)) {
            inline else => |tag| {
                // TODO: eliminate this loop
                inline for (fields) |field| {
                    if (field.type == void and comptime std.mem.eql(
                        u8,
                        field.name,
                        @tagName(tag),
                    )) {
                        return tag;
                    }
                }
                return error.invalid_union_tag;
            },
        }
    } else {
        try erl.validate(
            error.decoding_tuple,
            ei.ei_decode_tuple_header(self.buf.buff, self.index, &arity),
        );
        if (arity != 2) {
            // TODO: https://github.com/dont-rely-on-nulls/zerl/issues/7
            return error.wrong_arity_for_tuple;
        }
        switch (try self.parse_enum(Tag)) {
            inline else => |tag| {
                inline for (fields) |field| {
                    if (field.type != void and comptime std.mem.eql(
                        u8,
                        field.name,
                        @tagName(tag),
                    )) {
                        const tuple_value = try self.parse(field.type);
                        return @unionInit(T, field.name, tuple_value);
                    }
                } else return error.failed_to_receive_payload;
            },
        }
    }
    return error.unknown_tuple_tag;
}

test parse_union {
    const Shape = union(enum) {
        circle: u32,
        square: u32,
        point: void,
    };

    const circle = Shape{ .circle = 4 };
    const square = Shape{ .square = 4 };

    var buf: ei.ei_x_buff = undefined;
    try erl.validate(error.create_new_decode_buff, ei.ei_x_new(&buf));
    defer _ = ei.ei_x_free(&buf);

    var index: c_int = 0;
    try erl.encoder.write_any(&buf, circle);
    try erl.encoder.write_any(&buf, square);
    try erl.encoder.write_any(&buf, Shape.point);

    const decoder = Decoder{
        .buf = &buf,
        .index = &index,
        .allocator = testing.failing_allocator,
    };

    try testing.expectEqual(circle, decoder.parse_union(Shape));
    try testing.expectEqual(square, decoder.parse_union(Shape));
    try testing.expectEqual(Shape.point, decoder.parse_union(Shape));
}

fn parse_pointer(self: Decoder, comptime T: type) Error!T {
    const item = @typeInfo(T).Pointer;
    var value: T = undefined;
    if (item.size != .Slice)
        return error.unsupported_pointer_type;
    var size: c_int = 0;
    try erl.validate(
        error.decoding_list_in_pointer_1,
        ei.ei_decode_list_header(self.buf.buff, self.index, &size),
    );
    const has_sentinel = item.sentinel != null;
    if (size == 0 and !has_sentinel) {
        value = &.{};
    } else {
        const usize_size: c_uint = @intCast(size);
        const slice_buffer = if (has_sentinel)
            try self.allocator.allocSentinel(
                item.child,
                usize_size,
                item.sentinel.?,
            )
        else
            try self.allocator.alloc(
                item.child,
                usize_size,
            );
        errdefer self.allocator.free(slice_buffer);
        // TODO: We should deallocate the children
        for (slice_buffer) |*elem| {
            elem.* = try self.parse(item.child);
        }
        try erl.validate(
            error.decoding_list_in_pointer_2,
            ei.ei_decode_list_header(self.buf.buff, self.index, &size),
        );
        if (size != 0) return error.decoded_improper_list;
        value = slice_buffer;
    }

    return value;
}

fn parse_array(self: Decoder, comptime T: type) Error!T {
    const item = @typeInfo(T).Array;
    var value: T = undefined;
    var size: c_int = 0;
    try erl.validate(
        error.decoding_list_in_array_1,
        ei.ei_decode_list_header(self.buf.buff, self.index, &size),
    );
    if (item.len != size) return error.wrong_array_size;
    // TODO: We should deallocate the children
    for (0..value.len) |idx| {
        value[idx] = try self.parse(item.child);
    }
    try erl.validate(
        error.decoding_list_in_array_2,
        ei.ei_decode_list_header(self.buf.buff, self.index, &size),
    );
    if (size != 0) return error.decoded_improper_list;
    return value;
}

test parse_array {
    var buf: ei.ei_x_buff = undefined;
    try erl.validate(error.create_new_decode_buff, ei.ei_x_new(&buf));
    defer _ = ei.ei_x_free(&buf);

    var index: c_int = 0;

    const arc_numbers = [_]i32{ 413, 612, 1025, 111111 };

    try erl.encoder.write_any(&buf, arc_numbers);

    const decoder = Decoder{
        .buf = &buf,
        .index = &index,
        .allocator = testing.failing_allocator,
    };

    try testing.expectEqual(arc_numbers, decoder.parse(@TypeOf(arc_numbers)));
}

fn parse_bool(self: Decoder) Error!bool {
    var bool_value: c_int = 0;
    try erl.validate(
        error.decoding_boolean,
        ei.ei_decode_boolean(self.buf.buff, self.index, &bool_value),
    );
    return bool_value != 0;
}

test parse_bool {
    var buf: ei.ei_x_buff = undefined;
    try erl.validate(error.create_new_decode_buff, ei.ei_x_new(&buf));
    defer _ = ei.ei_x_free(&buf);

    var index: c_int = 0;

    try erl.encoder.write_any(&buf, true);
    try erl.encoder.write_any(&buf, false);

    const decoder = Decoder{
        .buf = &buf,
        .index = &index,
        .allocator = testing.failing_allocator,
    };

    try testing.expectEqual(true, decoder.parse(bool));
    try testing.expectEqual(false, decoder.parse(bool));
}

pub fn parse(self: Decoder, comptime T: type) Error!T {
    return if (T == [:0]const u8)
        self.parse_string()
    else if (T == ei.erlang_pid) blk: {
        var value: T = undefined;
        try erl.validate(
            error.invalid_pid,
            ei.ei_decode_pid(self.buf.buff, self.index, &value),
        );
        break :blk value;
    } else switch (@typeInfo(T)) {
        .Struct => |info| (if (info.is_tuple) parse_tuple else parse_struct)(self, T),
        .Int => self.parse_int(T),
        .Float => self.parse_float(T),
        .Enum => self.parse_enum(T),
        .Union => self.parse_union(T),
        .Pointer => self.parse_pointer(T),
        .Array => self.parse_array(T),
        .Bool => self.parse_bool(),
        .Void => @compileError("Void is not supported for deserialization"),
        else => @compileError("Unsupported type in deserialization"),
    };
}
