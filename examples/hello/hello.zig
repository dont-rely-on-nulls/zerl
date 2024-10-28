const std = @import("std");
const zerl = @import("zerl");

const Reply = union(enum) {
    ok: [:0]const u8,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const stderr = std.io.getStdErr().writer();

    try stderr.print("Running hello example...\n", .{});

    if (zerl.ei.ei_init() != 0) return error.ei_init_failed;
    var node = try zerl.Node.init("hello_cookie");
    try zerl.establish_connection(&node, "hello", "localhost");

    try stderr.print("Connected.\n", .{});

    const self = try node.self();
    const message = zerl.With_Pid([]const u8){ self.*, "Hello, World!" };
    try node.send("echo", message);

    const reply = try node.receive(Reply, allocator);
    try stderr.print("\nGot back: {s}\n", .{reply.ok});
    try node.send("echo", .die);
}
