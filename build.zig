const std = @import("std");

pub fn add_erlang_paths(b: *std.Build, root_paths: []const u8) !void {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    var it = std.mem.tokenizeScalar(u8, root_paths, ':');
    while (it.next()) |maybe_dir_path| {
        if (std.mem.indexOf(u8, maybe_dir_path, "\x00")) |_| continue;
        const name = std.fs.path.basename(maybe_dir_path);
        if (std.mem.eql(u8, "sbin", name)) continue;

        const dir_path = if (std.mem.eql(u8, "bin", name))
            b.pathJoin(&.{ std.fs.path.dirname(maybe_dir_path).?, "lib" })
        else
            maybe_dir_path;

        var dir = cwd.openDir(io, dir_path, .{}) catch continue;
        defer dir.close(io);

        var erlang = dir.openDir(
            io,
            "erlang/lib",
            .{ .iterate = true },
        ) catch continue;
        defer erlang.close(io);

        var erlang_it = erlang.iterate();
        while (try erlang_it.next(io)) |erlang_lib| {
            if (erlang_lib.kind == .directory) {
                const prefix = try erlang.realPathFileAlloc(
                    io,
                    erlang_lib.name,
                    b.allocator,
                );
                b.addSearchPrefix(prefix);
            }
        }
    }
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (b.graph.environ_map.get("LIBRARY_PATH")) |lib_path| {
        try add_erlang_paths(b, lib_path);
    }
    if (b.graph.environ_map.get("PATH")) |path| {
        try add_erlang_paths(b, path);
    }

    const root_file = b.path("src/erlang.zig");

    const zerl = b.addModule("zerl", .{
        .root_source_file = root_file,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const ei_options: std.Build.Module.LinkSystemLibraryOptions = .{
        .needed = true,
        .preferred_link_mode = .static,
    };
    // TODO: package erlang's C libs
    zerl.linkSystemLibrary("ei", ei_options);

    const lib_unit_tests = b.addTest(.{ .root_module = zerl });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
