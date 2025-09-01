const std = @import("std");
const builtin = @import("builtin");

const version: std.SemanticVersion = .{ .major = 1, .minor = 0, .patch = 2 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    createFirmwareLoaderExecutable(b, target, optimize);
    if (target.result.os.tag == .windows) {
        createWindowsServiceExecutable(b, target, optimize);
    }
}

fn createFirmwareLoaderExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const exe = b.addExecutable(.{
        .name = "PS5_Camera_Loader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/loader.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .version = version,
    });
    b.installArtifact(exe);

    const libusb = b.dependency("libusb", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addIncludePath(libusb.path("libusb"));
    exe.root_module.linkLibrary(libusb.artifact("usb"));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run-loader", "Run the loader app");
    run_step.dependOn(&run_cmd.step);
}

fn createWindowsServiceExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const exe = b.addExecutable(.{
        .name = "PS5_Camera_Windows_Service",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/service.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .version = version,
    });
    b.installArtifact(exe);

    exe.root_module.linkSystemLibrary("advapi32", .{});
    exe.root_module.linkSystemLibrary("user32", .{});

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run-service", "Run the service app");
    run_step.dependOn(&run_cmd.step);
}
