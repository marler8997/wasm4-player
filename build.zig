const std = @import("std");

const Wasm = enum { zware, bytebox};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wasm = b.option(Wasm, "wasm", "The wasm backend") orelse .zware;

    const zware_dep = b.dependency("zware", .{});
    const zigx_dep = b.dependency("zigx", .{});

    const build_options = b.addOptions();
    build_options.addOption(Wasm, "wasm", wasm);

    {
        const exe = b.addExecutable(.{
            .name = "wasm4-player",
            .root_source_file = .{ .path = "player.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.addOptions("build_options", build_options);
        switch (wasm) {
            .zware => exe.addModule("zware", zware_dep.module("zware")),
            .bytebox => exe.addModule("bytebox", b.createModule(.{
                .source_file = .{ .path = "bytebox/src/core.zig" },
            })),
        }
        exe.addModule("x", zigx_dep.module("zigx"));
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}
