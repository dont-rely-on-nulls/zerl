const std = @import("std");

fn add_erlang_paths(b: *std.Build) !void {
    const cwd = std.fs.cwd();
    if (std.posix.getenv("LIBRARY_PATH")) |lib_path| {
        var it = std.mem.tokenizeScalar(u8, lib_path, ':');
        while (it.next()) |dir_path| {
            var dir = cwd.openDir(dir_path, .{}) catch continue;
            defer dir.close();

            var erlang = dir.openDir(
                "erlang/lib",
                .{ .iterate = true },
            ) catch continue;
            defer erlang.close();

            var erlang_it = erlang.iterate();
            while (try erlang_it.next()) |erlang_lib| {
                if (erlang_lib.kind == .directory) {
                    const prefix = try erlang.realpathAlloc(
                        b.allocator,
                        erlang_lib.name,
                    );
                    b.addSearchPrefix(prefix);
                }
            }
        }
    }
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    try add_erlang_paths(b);

    const root_file = b.path("src/erlang.zig");

    const zerl = b.addModule("zerl", .{
        .root_source_file = root_file,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const ei_options = .{
        .needed = true,
        .preferred_link_mode = .static,
    };
    // TODO: package erlang's C libs
    zerl.linkSystemLibrary("ei", ei_options);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = root_file,
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.linkLibC();
    lib_unit_tests.linkSystemLibrary2("ei", ei_options);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
