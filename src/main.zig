const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        try @import("windows.zig").windowsInit();
    } else if (builtin.os.tag == .linux or builtin.os.tag.isDarwin()) {
        try @import("linux.zig").linuxInit();
    } else {
        std.debug.print("Unsupported OS\n", .{});
    }
}
