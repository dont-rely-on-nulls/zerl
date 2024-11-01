const std = @import("std");
const erl = @import("erlang.zig");

const assert = std.debug.assert;
const ei = erl.ei;

const Decoder = @This();

pub const Error = std.mem.Allocator.Error || error{
    decoding_atom_string_length,
    message_is_not_atom_or_string,
    decoding_atom,
    decoding_tuple,
    wrong_tuple_size,
    decoding_map,
    too_many_map_entries,
    too_few_map_entries,
    missing_field_in_struct,
    decoding_double,
    decoding_signed_integer,
    signed_out_of_bounds,
    decoding_unsigned_integer,
    unsigned_out_of_bounds,
    invalid_tag_to_enum,
    could_not_decode_enum,
    decoding_get_type,
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
index: *i32,
allocator: std.mem.Allocator,

fn parse_atom_or_string(
    self: Decoder,
    erlang_fun: *const fn ([*:0]const u8, *c_int, [*:0]u8) callconv(.C) c_int,
) ![:0]const u8 {
    var length: i32 = undefined;
    var ty: i32 = undefined;
    try erl.validate(
        error.decoding_atom_string_length,
        ei.ei_get_type(self.buf.buff, self.index, &ty, &length),
    );

    if (ty != ei.ERL_STRING_EXT and ty != ei.ERL_ATOM_EXT)
        return error.message_is_not_atom_or_string;

    const u_length: u32 = @intCast(length);

    const buffer = try self.allocator.allocSentinel(u8, u_length, 0);
    errdefer self.allocator.free(buffer);
    try erl.validate(
        error.decoding_atom,
        erlang_fun(self.buf.buff, self.index, buffer.ptr),
    );
    return buffer;
}

fn parse_string(self: Decoder) ![:0]const u8 {
    return self.parse_atom_or_string(ei.ei_decode_string);
}

fn parse_atom(self: Decoder) ![:0]const u8 {
    return self.parse_atom_or_string(ei.ei_decode_atom);
}

fn parse_tuple(self: Decoder, comptime T: type) Error!T {
    const type_info = @typeInfo(T).Struct;
    comptime assert(type_info.is_tuple);
    var value: T = undefined;
    var size: i32 = 0;
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

fn parse_struct(self: Decoder, comptime T: type) Error!T {
    const type_info = @typeInfo(T).Struct;
    comptime assert(!type_info.is_tuple);
    const fields = type_info.fields;

    var value: T = undefined;
    var size: i32 = 0;
    try erl.validate(
        error.decoding_map,
        ei.ei_decode_map_header(self.buf.buff, self.index, &size),
    );
    var present_fields = std.StaticBitSet(fields.len).initEmpty();
    var counter: u32 = 0;
    if (size > fields.len) return error.too_many_map_entries;
    for (0..@intCast(size)) |_| {
        const key = try self.parse_atom();
        defer self.allocator.free(key);

        // TODO: There's probably a way to avoid this loop
        inline for (0.., fields) |idx, field| {
            if (std.mem.eql(u8, field.name, key)) {
                const current_field = &@field(value, field.name);
                const field_type = @typeInfo(field.type);
                if (field_type == .Optional) {
                    current_field.* = try self.parse(field_type.Optional.child);
                } else {
                    current_field.* = try self.parse(field.type);
                }
                present_fields.set(idx);
                counter += 1;
            }
        }
    }
    if (size < counter) return error.too_few_map_entries;
    var should_error = false;
    inline for (0.., fields) |idx, field| {
        if (!present_fields.isSet(idx)) {
            const current_field = &@field(value, field.name);
            if (field.default_value) |default| {
                current_field.* = @as(
                    *const field.type,
                    @alignCast(@ptrCast(default)),
                ).*;
            } else if (@typeInfo(field.type) == .Optional) {
                current_field.* = null;
            } else {
                std.debug.print("Missing Field in Struct {s}: {s}\n", .{
                    @typeName(T),
                    field.name,
                });
                should_error = true;
            }
        }
    }
    return if (should_error) error.missing_field_in_struct else value;
}

fn parse_int(self: Decoder, comptime T: type) Error!T {
    const item = @typeInfo(T).Int;
    var value: T = undefined;
    if (item.signedness == .signed) {
        var aux: i64 = undefined;
        try erl.validate(error.decoding_signed_integer, ei.ei_decode_long(self.buf.buff, self.index, &aux));
        if (aux <= std.math.maxInt(T) and std.math.minInt(T) <= aux) {
            value = @intCast(aux);
            return value;
        }
        return error.signed_out_of_bounds;
    } else {
        var aux: u64 = undefined;
        try erl.validate(error.decoding_unsigned_integer, ei.ei_decode_ulong(self.buf.buff, self.index, &aux));
        if (aux <= std.math.maxInt(T)) {
            value = @intCast(aux);
            return value;
        }
        return error.unsigned_out_of_bounds;
    }
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
        error.decoding_get_type,
        ei.ei_get_type(self.buf.buff, self.index, &type_tag, &atom_size),
    );
    if (max_name_length < atom_size) return error.could_not_decode_enum;

    var atom_name: [max_name_length + 1]u8 = undefined;
    try erl.validate(
        error.decoding_atom,
        ei.ei_decode_atom(self.buf.buff, self.index, &atom_name),
    );
    const name = atom_name[0..@as(c_uint, @bitCast(atom_size))];
    return tag_map.get(name) orelse error.could_not_decode_enum;
}

test parse_enum {
    const testing = std.testing;
    const Suit = enum { diamonds, clubs, hearts, spades };

    var buf: ei.ei_x_buff = undefined;
    try erl.validate(error.create_new_decode_buff, ei.ei_x_new(&buf));
    defer _ = ei.ei_x_free(&buf);

    var index: c_int = 0;

    try erl.encoder.write_any(&buf, Suit.spades);

    const spade = try (Decoder{
        .buf = &buf,
        .index = &index,
        .allocator = testing.failing_allocator,
    }).parse_enum(Suit);

    try testing.expectEqual(Suit.spades, spade);
}

fn parse_union(self: Decoder, comptime T: type) Error!T {
    const item = @typeInfo(T).Union;
    var value: T = undefined;
    var arity: i32 = 0;
    var typ: i32 = 0;
    var _v: i32 = undefined;
    try erl.validate(
        error.decoding_get_type,
        ei.ei_get_type(self.buf.buff, self.index, &typ, &_v),
    );
    const enum_type = std.meta.Tag(T);
    if (typ == ei.ERL_ATOM_EXT) {
        const tuple_name = try self.parse_enum(enum_type);
        switch (tuple_name) {
            inline else => |name| {
                inline for (item.fields) |field| {
                    if (field.type == void and comptime std.mem.eql(
                        u8,
                        field.name,
                        @tagName(name),
                    )) {
                        value = name;
                        break;
                    }
                } else return error.invalid_union_tag;
            },
        }
        return value;
    } else {
        try erl.validate(
            error.decoding_tuple,
            ei.ei_decode_tuple_header(self.buf.buff, self.index, &arity),
        );
        if (arity != 2) {
            return error.wrong_arity_for_tuple;
        }
        const tuple_name = try self.parse_enum(enum_type);
        switch (tuple_name) {
            inline else => |name| {
                inline for (item.fields) |field| {
                    if (field.type != void and comptime std.mem.eql(
                        u8,
                        field.name,
                        @tagName(name),
                    )) {
                        const tuple_value = try self.parse(field.type);
                        value = @unionInit(T, field.name, tuple_value);
                        return value;
                    }
                } else return error.failed_to_receive_payload;
            },
        }
    }
    return error.unknown_tuple_tag;
}

fn parse_pointer(self: Decoder, comptime T: type) Error!T {
    const item = @typeInfo(T).Pointer;
    var value: T = undefined;
    if (item.size != .Slice)
        return error.unsupported_pointer_type;
    var size: i32 = 0;
    try erl.validate(
        error.decoding_list_in_pointer_1,
        ei.ei_decode_list_header(self.buf.buff, self.index, &size),
    );
    const has_sentinel = item.sentinel != null;
    if (size == 0 and !has_sentinel) {
        value = &.{};
    } else {
        const usize_size: u32 = @intCast(size);
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
    var size: i32 = 0;
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
    const testing = std.testing;

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

    try testing.expectEqual(arc_numbers, try decoder.parse_array(@TypeOf(arc_numbers)));
}

fn parse_bool(self: Decoder) Error!bool {
    var bool_value: i32 = 0;
    try erl.validate(
        error.decoding_boolean,
        ei.ei_decode_boolean(self.buf.buff, self.index, &bool_value),
    );
    return bool_value != 0;
}

test parse_bool {
    const testing = std.testing;

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

    try testing.expectEqual(true, try decoder.parse_bool());
    try testing.expectEqual(false, try decoder.parse_bool());
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
