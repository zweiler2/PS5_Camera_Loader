const std = @import("std");
const builtin = @import("builtin");

pub const CHUNK_SIZE = 512; // Bulk transfers are limited to 512 bytes per USB standard

pub const vendor_id = 0x05a9;
pub const product_id = 0x0580;

pub fn main() !void {
    // Create an allocator
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator: std.mem.Allocator = arena.allocator();

    // Get arguments with proper cross-platform support
    var args: std.process.ArgIterator = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name but store it for error message
    const prog_name: [:0]const u8 = args.next() orelse return error.NoProgramName;

    // Get firmware path argument
    const firmware_path: [:0]const u8 = args.next() orelse {
        std.log.err(
            \\Please provide a firmware file path.
            \\
            \\Usage:
            \\  {s} <path{c}to{c}firmware_file.bin>
        , .{ prog_name, std.fs.path.sep, std.fs.path.sep });
        std.process.exit(1);
    };

    const firmware_file: std.fs.File = try std.fs.cwd().openFile(firmware_path, .{});
    defer firmware_file.close();

    if (builtin.os.tag == .windows) {
        try @import("windows.zig").loader(allocator, &firmware_file);
    } else if (builtin.os.tag == .linux or builtin.os.tag.isDarwin()) {
        try @import("linux.zig").loader(&firmware_file);
    } else {
        std.debug.print("Unsupported OS\n", .{});
    }
}
