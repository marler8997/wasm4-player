const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zware_dep = b.dependency("zware", .{});
    const zigx_dep = b.dependency("zigx", .{});

    {
        const exe = b.addExecutable(.{
            .name = "wasm4-vm",
            .root_source_file = .{ .path = "vm.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.addModule("zware", zware_dep.module("zware"));
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
