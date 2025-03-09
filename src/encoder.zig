const std = @import("std");
const erl = @import("erlang.zig");

const ei = erl.ei;
const assert = std.debug.assert;

pub const Error = error{
    could_not_encode_pid,
    could_not_encode_binary,
    could_not_encode_bool,
    could_not_encode_map,
    could_not_encode_atom,
    could_not_encode_tuple,
    could_not_encode_float,
    could_not_encode_int,
    could_not_encode_uint,
    could_not_encode_list_head,
    could_not_encode_list_tail,
};

fn write_pointer(buf: *ei.ei_x_buff, data: anytype) Error!void {
    const Data = @TypeOf(data);
    const info = @typeInfo(Data).pointer;
    switch (info.size) {
        .many, .c => @compileError("unsupported pointer size"),
        .slice => {
            try erl.validate(
                error.could_not_encode_list_head,
                ei.ei_x_encode_list_header(buf, @bitCast(data.len)),
            );
            for (data) |item| try write_any(buf, item);
            try erl.validate(
                error.could_not_encode_list_tail,
                ei.ei_x_encode_list_header(buf, 0),
            );
        },
        .one => {
            const Child = info.child;
            switch (@typeInfo(Child)) {
                .bool,
                .int,
                .float,
                .@"enum",
                .pointer,
                .enum_literal,
                .comptime_int,
                .comptime_float,
                => try write_any(buf, data.*),
                .array => |array_info| try write_pointer(
                    buf,
                    @as([]const array_info.child, data),
                ),
                .@"union" => |union_info| switch (@as(union_info.tag_type.?, data.*)) {
                    inline else => |tag| {
                        inline for (union_info.fields) |field| {
                            if (comptime std.mem.eql(
                                u8,
                                field.name,
                                @tagName(tag),
                            )) {
                                const send_tuple: bool = field.type != void;
                                if (send_tuple) {
                                    try erl.validate(
                                        error.could_not_encode_tuple,
                                        ei.ei_x_encode_tuple_header(buf, 2),
                                    );
                                }
                                try write_any(buf, tag);
                                if (send_tuple) try write_any(buf, @field(data, @tagName(tag)));
                            }
                        }
                    },
                },
                .@"struct" => |struct_info| if (struct_info.is_tuple) {
                    try erl.validate(
                        error.could_not_encode_tuple,
                        ei.ei_x_encode_tuple_header(buf, struct_info.fields.len),
                    );
                    inline for (data) |field| try write_any(buf, field);
                } else {
                    const mandatory_fields = comptime blk: {
                        var count = 0;
                        for (struct_info.fields) |field| {
                            const field_info = @typeInfo(field.type);
                            if (field_info != .optional) count += 1;
                        }
                        break :blk count;
                    };
                    var present_fields: usize = mandatory_fields;
                    inline for (struct_info.fields) |field| {
                        const field_info = @typeInfo(field.type);
                        const payload = @field(data, field.name);
                        if (field_info == .optional) {
                            if (payload != null) {
                                present_fields += 1;
                            }
                        }
                    }
                    try erl.validate(
                        error.could_not_encode_map,
                        ei.ei_x_encode_map_header(buf, @bitCast(present_fields)),
                    );
                    inline for (struct_info.fields) |field| {
                        const payload = @field(data, field.name);
                        const payload_info = @typeInfo(@TypeOf(payload));
                        if (payload_info != .optional or
                            payload != null)
                        {
                            try erl.validate(
                                error.could_not_encode_atom,
                                ei.ei_x_encode_atom_len(
                                    buf,
                                    field.name.ptr,
                                    @intCast(field.name.len),
                                ),
                            );
                            const actual_payload = if (payload_info == .optional)
                                payload.?
                            else
                                payload;
                            try write_any(buf, actual_payload);
                        }
                    }
                },
                .noreturn => unreachable,
                else => @compileError("unsupported type"),
            }
        },
    }
}

pub fn write_any(buf: *ei.ei_x_buff, data: anytype) Error!void {
    const Data = @TypeOf(data);

    return if (Data == *const ei.erlang_pid or
        Data == *ei.erlang_pid or
        Data == [*c]const ei.erlang_pid or
        Data == [*c]ei.erlang_pid)
        erl.validate(
            error.could_not_encode_pid,
            ei.ei_x_encode_pid(buf, data),
        )
    else if (Data == ei.erlang_pid)
        write_any(buf, &data)
    else if (Data == []const u8 or
        Data == [:0]const u8 or
        Data == []u8 or
        Data == [:0]u8)
        erl.validate(
            error.could_not_encode_binary,
            // I think we should lean towards binaries over strings
            // TODO: make that happen
            ei.ei_x_encode_string_len(buf, data.ptr, @intCast(data.len)),
        )
    else switch (@typeInfo(Data)) {
        .bool => erl.validate(
            error.could_not_encode_bool,
            ei.ei_x_encode_boolean(buf, @intFromBool(data)),
        ),
        .comptime_int => write_any(
            buf,
            @as(if (0 <= data) c_ulonglong else c_longlong, data),
        ),
        .comptime_float => write_any(buf, @as(f64, data)),
        .int => |info| if (@bitSizeOf(c_longlong) < info.bits)
            @compileError("Integer too large")
        else if (info.signedness == .signed)
            erl.validate(
                error.could_not_encode_int,
                ei.ei_x_encode_longlong(buf, data),
            )
        else
            erl.validate(
                error.could_not_encode_uint,
                ei.ei_x_encode_ulonglong(buf, data),
            ),

        .float => |info| if (65 <= info.bits)
            @compileError("Float too large")
        else
            erl.validate(
                error.could_not_encode_float,
                ei.ei_x_encode_double(buf, data),
            ),
        .@"enum", .enum_literal => blk: {
            const name = @tagName(data);
            break :blk erl.validate(
                error.could_not_encode_atom,
                ei.ei_x_encode_atom_len(buf, name.ptr, @intCast(name.len)),
            );
        },
        .array, .@"struct", .@"union" => write_any(buf, &data),
        .pointer => write_pointer(buf, data),
        .noreturn => unreachable,
        else => @compileError("unsupported type"),
    };
}
