pub const ei = @cImport({
    @cInclude("ei.h");
});
const std = @import("std");
const erl = @import("erlang.zig");

buf: *ei.ei_x_buff,
index: *i32,
allocator: std.mem.Allocator,

// TODO: Try to make the simplest possible example using something like this to report to zig repo
//pub fn receive_atom_string(deserializer: Deserializer, allocator: std.mem.Allocator, erlang_fun: fn ([*:0]const u8, *i32, [*:0]u8) callconv(.C) c_int) ![:0]const u8 {
fn parse_atom_or_string(self: @This(), erlang_fun: *const fn ([*c]const u8, [*c]c_int, [*c]u8) callconv(.C) c_int) ![:0]const u8 {
    var length: i32 = undefined;
    var ty: i32 = undefined;
    try erl.validate(error.decoding_atom_string_length, ei.ei_get_type(self.buf.buff, self.index, &ty, &length));

    if (ty != ei.ERL_STRING_EXT and ty != ei.ERL_ATOM_EXT)
        return error.message_is_not_atom_or_string;

    const u_length: u32 = @intCast(length);

    const buffer = try self.allocator.allocSentinel(u8, u_length, 0);
    errdefer self.allocator.free(buffer);
    try erl.validate(error.decoding_atom, erlang_fun(self.buf.buff, self.index, buffer.ptr));
    return buffer;
}

fn parse_string(self: @This()) ![:0]const u8 {
    return parse_atom_or_string(self, ei.ei_decode_string);
}

fn parse_atom(self: @This()) ![:0]const u8 {
    return parse_atom_or_string(self, ei.ei_decode_atom);
}

inline fn parse_struct(self: @This(), comptime T: type, comptime item: std.builtin.Type.Struct) !T {
    var value: T = undefined;
    var size: i32 = 0;
    if (item.is_tuple) {
        try erl.validate(
            error.decoding_tuple,
            ei.ei_decode_tuple_header(self.buf.buff, self.index, &size),
        );
        if (item.fields.len != size) return error.wrong_tuple_size;
        inline for (&value) |*elem| {
            elem.* = try parse(self, @TypeOf(elem.*));
        }
    } else {
        try erl.validate(
            error.decoding_map,
            ei.ei_decode_map_header(self.buf.buff, self.index, &size),
        );
        const fields = std.meta.fields(T);
        var present_fields: [fields.len]bool = .{false} ** fields.len;
        var counter: u32 = 0;
        if (size > fields.len) return error.too_many_map_entries;
        for (0..@intCast(size)) |_| {
            const key = try parse_atom(self);
            // TODO: There's probably a way to avoid this loop
            inline for (0.., fields) |idx, field| {
                if (std.mem.eql(u8, field.name, key)) {
                    const current_field = &@field(value, field.name);
                    const field_type = @typeInfo(field.type);
                    if (field_type == .Optional) {
                        current_field.* = try parse(self, field_type.Optional.child);
                    } else {
                        current_field.* = try parse(self, field.type);
                    }
                    present_fields[idx] = true;
                    counter += 1;
                }
            }
        }
        if (size < counter) return error.too_few_map_entries;
        var should_error = false;
        inline for (present_fields, fields) |presence, field| {
            if (!presence) {
                if (@typeInfo(field.type) == .Optional) {
                    const current_field = &@field(value, field.name);
                    current_field.* = null;
                } else {
                    std.debug.print("Missing Field in Struct {s}: {s}\n", .{ @typeName(T), field.name });
                    should_error = true;
                }
            }
        }
        if (should_error) return error.missing_field_in_struct;
    }
    return value;
}

inline fn parse_int(self: @This(), comptime T: type, comptime item: std.builtin.Type.Int) !T {
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

inline fn parse_enum(self: @This(), comptime T: type, comptime item: std.builtin.Type.Enum) !T {
    const name = try parse_atom(self);
    errdefer self.allocator.free(name);
    inline for (item.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return std.meta.stringToEnum(T, name) orelse error.invalid_tag_to_enum;
        }
    }
    return error.could_not_decode_enum;
}

inline fn parse_union(self: @This(), comptime T: type, comptime item: std.builtin.Type.Union) !T {
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
        const tuple_name = try parse_enum(self, enum_type, @typeInfo(enum_type).Enum);
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
        const tuple_name = try parse_enum(self, enum_type, @typeInfo(enum_type).Enum);
        switch (tuple_name) {
            inline else => |name| {
                inline for (item.fields) |field| {
                    if (field.type != void and comptime std.mem.eql(
                        u8,
                        field.name,
                        @tagName(name),
                    )) {
                        const tuple_value = try parse(self, field.type);
                        value = @unionInit(T, field.name, tuple_value);
                        return value;
                    }
                } else return error.failed_to_receive_payload;
            },
        }
    }
    return error.unknown_tuple_tag;
}

inline fn parse_pointer(self: @This(), comptime T: type, comptime item: std.builtin.Type.Pointer) !T {
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
            elem.* = try parse(self, item.child);
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

inline fn parse_array(self: @This(), comptime T: type, comptime item: std.builtin.Type.Array) !T {
    var value: T = undefined;
    var size: i32 = 0;
    try erl.validate(
        error.decoding_list_in_array_1,
        ei.ei_decode_list_header(self.buf.buff, self.index, &size),
    );
    if (item.len != size) return error.wrong_array_size;
    // TODO: We should deallocate the children
    for (0..value.len) |idx| {
        value[idx] = try parse(self, item.child);
    }
    try erl.validate(
        error.decoding_list_in_array_2,
        ei.ei_decode_list_header(self.buf.buff, self.index, &size),
    );
    if (size != 0) return error.decoded_improper_list;
    return value;
}

inline fn parse_bool(self: @This()) !bool {
    var bool_value: i32 = 0;
    try erl.validate(
        error.decoding_boolean,
        ei.ei_decode_boolean(self.buf.buff, self.index, &bool_value),
    );
    return bool_value != 0;
}

pub fn parse(self: @This(), comptime T: type) !T {
    var value: T = undefined;
    if (T == [:0]const u8) {
        value = try parse_string(self);
    } else if (T == ei.erlang_pid) {
        try erl.validate(
            error.invalid_pid,
            ei.ei_decode_pid(self.buf.buff, self.index, &value),
        );
    } else switch (@typeInfo(T)) {
        .Struct => |item| {
            value = try parse_struct(self, T, item);
        },
        .Int => |item| {
            value = try parse_int(self, T, item);
        },
        .Enum => |item| {
            value = try parse_enum(self, T, item);
        },
        .Union => |item| {
            value = try parse_union(self, T, item);
        },
        .Pointer => |item| {
            value = try parse_pointer(self, T, item);
        },
        .Array => |item| {
            value = try parse_array(self, T, item);
        },
        .Bool => {
            value = try parse_bool(self, T);
        },
        .Void => {
            @compileError("Void is not supported for deserialization");
        },
        else => {
            @compileError("Unsupported type in deserialization");
        },
    }
    return value;
}
