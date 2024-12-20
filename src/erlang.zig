pub const ei = @cImport({
    @cInclude("ei.h");
});

const std = @import("std");
pub const Decoder = @import("Decoder.zig");
pub const encoder = @import("encoder.zig");

pub const Send_Error = std.mem.Allocator.Error || encoder.Error || error{
    could_not_send_to_pid,
    could_not_send_to_named_process,
};

pub const Node = struct {
    const name_length = 64;
    pub const max_buffer_size = 50;
    c_node: ei.ei_cnode,
    fd: i32,
    node_name: [name_length:0]u8,

    pub fn init(cookie: [:0]const u8) !Node {
        var src_node_name: [name_length / 2]u8 = undefined;
        std.crypto.random.bytes(&src_node_name);
        var tempNode: Node = .{
            .c_node = undefined,
            .fd = undefined,
            .node_name = std.fmt.bytesToHex(src_node_name, .lower) ++ [0:0]u8{},
        };

        const creation = std.time.timestamp() + 1;
        const creation_u: u64 = @bitCast(creation);
        const check = ei.ei_connect_init(
            &tempNode.c_node,
            &tempNode.node_name,
            cookie.ptr,
            @truncate(creation_u),
        );
        try validate(error.ei_connect_init_failed, check);

        return tempNode;
    }

    pub fn receive(ec: *Node, comptime T: type, allocator: std.mem.Allocator) !T {
        var msg: ei.erlang_msg = undefined;
        var buf: ei.ei_x_buff = undefined;
        var index: i32 = 0;

        // FIXME: hidden allocation
        try validate(error.create_new_decode_buff, ei.ei_x_new(&buf));
        defer _ = ei.ei_x_free(&buf);

        while (true) {
            const got: i32 = ei.ei_xreceive_msg(ec.fd, &msg, &buf);
            if (got == ei.ERL_TICK)
                continue;
            if (got == ei.ERL_ERROR) {
                return error.got_error_receiving_message;
            }
            break;
        }

        try validate(error.decoding_version, ei.ei_decode_version(buf.buff, &index, null));
        return (Decoder{
            .buf = &buf,
            .index = &index,
            .allocator = allocator,
        }).parse(T);
    }

    pub fn send(ec: *Node, destination: anytype, data: anytype) Send_Error!void {
        var buf: ei.ei_x_buff = undefined;

        // TODO: get rid of hidden allocation
        try validate(error.OutOfMemory, ei.ei_x_new_with_version(&buf));
        defer _ = ei.ei_x_free(&buf);

        try encoder.write_any(&buf, data);
        const Destination = @TypeOf(destination);
        if (Destination == ei.erlang_pid) {
            try validate(
                error.could_not_send_to_pid,
                ei.ei_send(ec.fd, @constCast(&destination), buf.buff, buf.index),
            );
        } else if (Destination == *ei.erlang_pid or Destination == *const ei.erlang_pid) {
            try validate(
                error.could_not_send_to_pid,
                ei.ei_send(ec.fd, @constCast(destination), buf.buff, buf.index),
            );
        } else {
            const destination_name: [*:0]u8 = @constCast(destination);
            try validate(
                error.could_not_send_to_named_process,
                ei.ei_reg_send(&ec.c_node, ec.fd, destination_name, buf.buff, buf.index),
            );
        }
    }

    pub fn self(ec: *Node) !*ei.erlang_pid {
        return if (ei.ei_self(&ec.c_node)) |pid|
            pid
        else
            error.could_not_find_self;
    }
};

pub fn validate(
    comptime error_tag: anytype,
    result_value: c_int,
) @TypeOf(error_tag)!void {
    if (result_value < 0) {
        return error_tag;
    }
}

pub fn establish_connection(ec: *Node, process_name: []const u8, ip: []const u8) !void {
    var buffer: [Node.max_buffer_size:0]u8 = .{0} ** Node.max_buffer_size;
    std.mem.copyForwards(u8, &buffer, process_name);
    buffer[process_name.len] = '@';
    std.mem.copyForwards(u8, buffer[process_name.len + 1 ..], ip);
    const sockfd = ei.ei_connect(&ec.c_node, &buffer);
    try validate(error.ei_connect_failed, sockfd);
    ec.fd = sockfd;
}

pub fn With_Pid(comptime T: type) type {
    return std.meta.Tuple(&.{ ei.erlang_pid, T });
}

test {
    _ = encoder;
    _ = Decoder;
}
