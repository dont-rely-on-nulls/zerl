pub const ei = @cImport({
    @cInclude("ei.h");
});

const std = @import("std");
pub const receiver = @import("receiver.zig");
pub const sender = @import("sender.zig");

// TODO: move these elsewhere, maybe make them into parameters
pub const process_name = "server";
pub const server_name = process_name ++ "@localhost";

pub const Send_Error = sender.Error || error{
    // TODO: rid the world of these terrible names
    new_with_version,
    reg_send_failed,
};

pub const Node = struct {
    const name_length = 10;
    pub const max_buffer_size = 50;
    c_node: ei.ei_cnode,
    fd: i32,
    node_name: [name_length:0]u8,
    cookie: [:0]const u8 = "cookie",

    pub fn init() !Node {
        var tempNode: Node = .{
            .c_node = undefined,
            .fd = undefined,
            .node_name = .{0} ** name_length,
        };

        var src_node_name: [name_length / 2]u8 = undefined;
        std.crypto.random.bytes(&src_node_name);
        const encoder = std.base64.Base64Encoder.init(std.base64.standard_alphabet_chars, null);
        _ = encoder.encode(&tempNode.node_name, &src_node_name);

        const creation = std.time.timestamp() + 1;
        const creation_u: u64 = @bitCast(creation);
        const check = ei.ei_connect_init(
            &tempNode.c_node,
            &tempNode.node_name,
            tempNode.cookie.ptr,
            @truncate(creation_u),
        );
        try validate(error.ei_connect_init_failed, check);

        return tempNode;
    }

    pub fn receive(ec: *Node, comptime T: type, allocator: std.mem.Allocator) !T {
        return receiver.run(T, allocator, ec);
    }

    pub fn send(ec: *Node, destination: anytype, data: anytype) Send_Error!void {
        var buf: ei.ei_x_buff = undefined;
        // TODO: get rid of hidden allocation
        try validate(error.new_with_version, ei.ei_x_new_with_version(&buf));
        defer _ = ei.ei_x_free(&buf);

        try sender.send_payload(&buf, data);
        const Destination = @TypeOf(destination);
        if (Destination == ei.erlang_pid) {
            try validate(
                error.reg_send_failed,
                ei.ei_send(ec.fd, &destination, buf.buff, buf.index),
            );
        } else if (Destination == *ei.erlang_pid or Destination == *const ei.erlang_pid) {
            try validate(
                error.reg_send_failed,
                ei.ei_send(ec.fd, destination, buf.buff, buf.index),
            );
        } else {
            const destination_name: [*:0]u8 = @constCast(destination);
            try validate(
                error.reg_send_failed_to_master,
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

pub fn validate(error_tag: anytype, result_value: c_int) !void {
    if (result_value < 0) {
        return error_tag;
    }
}

pub fn establish_connection(ec: *Node, ip: []const u8) !void {
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
