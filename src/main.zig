const std = @import("std");
const erl = @import("erlang.zig");
const ei = erl.ei;

pub fn print_connect_server_error(message: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "Could not create a node!\n\u{1b}[31mError: \u{1b}[37m{}\n",
        .{message},
    );
}

pub fn main() !void {
    //    const connection_status = erl.ei.ei_init();
    //    if (connection_status != 0) return error.ei_init_failed;
    //    var node: erl.Node = try erl.prepare_connection();
    //    erl.establish_connection(&node) catch |error_value| {
    //        try print_connect_server_error(error_value);
    //        std.process.exit(2);
    //    };
    //
    //    const str = "Hello from Zerl!";
    //    var buf: ei.ei_x_buff = undefined;
    //    try erl.validate(error.new_with_version, ei.ei_x_new_with_version(&buf));
    //    defer _ = ei.ei_x_free(&buf);
    //
    //    try erl.sender.send_payload(&buf, &str);
    std.debug.print("Hello, World!\n", .{});
}
