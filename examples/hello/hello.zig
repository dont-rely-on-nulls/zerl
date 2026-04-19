const std = @import("std");
const zerl = @import("zerl");

const Reply = union(enum) {
    ok: [:0]const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var buf: [1024]u8 = undefined;
    var stderr_file = std.Io.File.stderr().writer(io, &buf);
    const stderr = &stderr_file.interface;

    try stderr.print("Running hello example...\n", .{});

    if (zerl.ei.ei_init() != 0) return error.ei_init_failed;
    var node = try zerl.Node.init(io, "hello_cookie");
    try zerl.establish_connection(&node, "hello", "localhost");

    try stderr.print("Connected.\n", .{});

    const self = try node.self();
    const message: zerl.With_Pid([]const u8) = .{ self.*, "Hello, World!" };
    try node.send("echo", message);

    const reply = try node.receive(Reply, arena);
    try stderr.print("\nGot back: {s}\n", .{reply.ok});
    try node.send("echo", .die);
    try stderr.flush();
}
