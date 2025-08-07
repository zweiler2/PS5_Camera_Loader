const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "PS5_Camera_Loader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const libusb = b.dependency("libusb", .{
        .target = target,
        .optimize = optimize,
        .@"system-libudev" = false,
    });
    exe.addIncludePath(libusb.path("libusb"));

    if (target.result.os.tag == .linux or target.result.os.tag.isDarwin()) {
        exe.linkLibrary(libusb.artifact("usb"));
    } else if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("setupapi");
        exe.linkSystemLibrary("winusb");
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
