const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("cards.zig"),
        .target = target,
        .optimize = optimize,
    });

    const client = b.addExecutable(.{
        .name = "cards",
        .root_module = root_module,
    });
    b.installArtifact(client);

    if (b.lazyDependency("zerl", .{
        .target = target,
        .optimize = optimize,
    })) |zerl| {
        root_module.addImport("zerl", zerl.module("zerl"));
    }

    if (b.lazyImport(@This(), "zerl")) |zerl_build| {
        if (std.posix.getenv("LIBRARY_PATH")) |lib_path| {
            try zerl_build.add_erlang_paths(b, lib_path);
        }
        if (std.posix.getenv("PATH")) |path| {
            try zerl_build.add_erlang_paths(b, path);
        }
    }

    const server_cmd = b.addSystemCommand(&.{"./dealer.erl"});
    const server_step = b.step("server", "Run the server");
    server_step.dependOn(&server_cmd.step);

    const client_cmd = b.addRunArtifact(client);
    client_cmd.step.dependOn(b.getInstallStep());

    const client_step = b.step("client", "Run the client");
    client_step.dependOn(&client_cmd.step);
}
