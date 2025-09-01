const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("libusb.h");
});

// Bulk transfers are limited to 512 bytes per USB standard
pub const CHUNK_SIZE = 512;

pub const VENDOR_ID = 0x05A9;
pub const PRODUCT_ID = 0x0580;

// Device only has one 1 USB interface (see `lsusb` output)
const INTERFACE_NUM = 0;

pub fn main() !void {
    // Create an allocator
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator: std.mem.Allocator = arena.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: std.fs.File.Writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout: *std.io.Writer = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: std.fs.File.Writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr: *std.io.Writer = &stderr_writer.interface;

    // Get arguments with proper cross-platform support
    var args: std.process.ArgIterator = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name but store it for error message
    const prog_name: [:0]const u8 = args.next() orelse return error.NoProgramName;

    // Get firmware path argument
    const firmware_path: [:0]const u8 = args.next() orelse {
        try stderr.print(
            \\Please provide a firmware file path!
            \\Usage: {s} <path{c}to{c}firmware_file.bin>
            \\
        , .{ prog_name, std.fs.path.sep, std.fs.path.sep });
        try stderr.flush();
        std.process.exit(1);
    };

    const firmware_file: std.fs.File = try std.fs.cwd().openFile(firmware_path, .{});
    defer firmware_file.close();

    var libusb_context: ?*c.libusb_context = null;
    var rc: c_int = c.libusb_init(&libusb_context);

    if (c.libusb_set_option(libusb_context, c.LIBUSB_OPTION_LOG_LEVEL, c.LIBUSB_LOG_LEVEL_ERROR) != c.LIBUSB_SUCCESS) {
        try stderr.print("Failed to set libusb log level", .{});
        try stderr.flush();
    }

    if (rc != c.LIBUSB_SUCCESS) {
        try stderr.print("Failed to initialize libusb: {s}\n", .{getLibusbError(rc)});
        try stderr.flush();
        return error.LibUsbInitFailed;
    }
    defer c.libusb_exit(libusb_context);

    const libusb_dev_handle: ?*c.libusb_device_handle = c.libusb_open_device_with_vid_pid(libusb_context, VENDOR_ID, PRODUCT_ID);
    if (libusb_dev_handle == null) {
        try stderr.print("Could not open device\n", .{});
        try stderr.flush();
        return error.DeviceNotFound;
    }
    defer c.libusb_close(libusb_dev_handle);

    // Can't claim the device if the operating system is using it
    if (builtin.os.tag != .windows) {
        if (c.libusb_kernel_driver_active(libusb_dev_handle, INTERFACE_NUM) != c.LIBUSB_SUCCESS) {
            if (c.libusb_detach_kernel_driver(libusb_dev_handle, INTERFACE_NUM) != c.LIBUSB_SUCCESS) {
                try stderr.print("Failed to detach kernel driver: {s}\n", .{getLibusbError(rc)});
                try stderr.flush();
                return error.KernelDriverDetachFailed;
            }
            try stdout.print("Detaching kernel driver!\n", .{});
            try stdout.flush();
        }
    }

    rc = c.libusb_claim_interface(libusb_dev_handle, INTERFACE_NUM);
    if (rc != c.LIBUSB_SUCCESS) {
        try stderr.print("Failed to claim interface: {s}\n", .{getLibusbError(rc)});
        try stderr.flush();
        return error.InterfaceClaimFailed;
    }
    defer blk: {
        const release_interface: c_int = c.libusb_release_interface(libusb_dev_handle, INTERFACE_NUM);
        if (release_interface == c.LIBUSB_ERROR_NO_DEVICE) {
            break :blk;
        } else if (release_interface != c.LIBUSB_SUCCESS) {
            stderr.print("Failed to release libusb interface: {s}\n", .{getLibusbError(release_interface)}) catch {};
            stderr.flush() catch {};
        }
    }

    // Upload firmware
    try uploadFirmware(libusb_dev_handle, &firmware_file, stderr);

    try stdout.print("Finished uploading firmware!\n", .{});
    try stdout.flush();
}

fn uploadFirmware(libusb_dev_handle: ?*c.libusb_device_handle, firmware_file: *const std.fs.File, stderr: *std.io.Writer) !void {
    const file_size: u64 = try firmware_file.getEndPos();
    try firmware_file.seekTo(0);

    var chunk: [CHUNK_SIZE]u8 = [_]u8{0} ** CHUNK_SIZE;
    var index: u16 = 0x14;
    var value: u16 = 0;
    var pos: u32 = 0;

    while (pos < file_size) {
        const size: u16 = @min(CHUNK_SIZE, file_size - pos);
        _ = try firmware_file.read(chunk[0..@intCast(size)]);

        try libUsbControlTransfer(
            libusb_dev_handle,
            c.LIBUSB_REQUEST_TYPE_VENDOR,
            0x0,
            value,
            index,
            size,
            &chunk,
            stderr,
        );

        if (@as(u32, value) + size > std.math.maxInt(u16)) {
            index += 1;
        }

        value = @truncate(@as(u32, value) + size);
        pos += size;
    }

    // Final transfer
    chunk[0] = 0x5b;
    try libUsbControlTransfer(
        libusb_dev_handle,
        c.LIBUSB_REQUEST_TYPE_VENDOR,
        0x0,
        0x2200,
        0x8018,
        1,
        &chunk,
        stderr,
    );
}

fn libUsbControlTransfer(
    dev_handle: ?*c.libusb_device_handle,
    request_type: u8,
    b_request: u8,
    w_value: u16,
    w_index: u16,
    w_length: u16,
    data: [*c]u8,
    stderr: *std.io.Writer,
) !void {
    const bytes_transferred: c_int = c.libusb_control_transfer(
        dev_handle,
        request_type,
        b_request,
        w_value,
        w_index,
        data,
        w_length,
        0,
    );

    // Device disconnection is expected during firmware upload
    // The device changes from Boot mode (05a9:0580) to Camera mode (05a9:058c)
    if (bytes_transferred == c.LIBUSB_ERROR_NO_DEVICE) return;

    if (bytes_transferred == 0) {
        try stderr.print("No bytes transferred", .{});
        try stderr.flush();
        return error.NoBytesTransferred;
    } else if (bytes_transferred < 0) {
        try stderr.print("USB transfer error: {s}", .{getLibusbError(bytes_transferred)});
        try stderr.flush();
        return error.TransferError;
    } else if (bytes_transferred > 0 and bytes_transferred != w_length) {
        try stderr.print("libusb reported only {d} bytes transferred, but firmware file is {d} bytes", .{ bytes_transferred, w_length });
        try stderr.flush();
        return error.IncompleteTransfer;
    }
}

fn getLibusbError(err_code: c_int) []const u8 {
    return switch (err_code) {
        c.LIBUSB_ERROR_IO => "Input/Output error",
        c.LIBUSB_ERROR_INVALID_PARAM => "Invalid parameter",
        c.LIBUSB_ERROR_ACCESS => "Access denied",
        c.LIBUSB_ERROR_NO_DEVICE => "No such device",
        c.LIBUSB_ERROR_NOT_FOUND => "Not found",
        c.LIBUSB_ERROR_BUSY => "Resource busy",
        c.LIBUSB_ERROR_TIMEOUT => "Operation timed out",
        c.LIBUSB_ERROR_OVERFLOW => "Overflow",
        c.LIBUSB_ERROR_PIPE => "Pipe error",
        c.LIBUSB_ERROR_INTERRUPTED => "Interrupted",
        c.LIBUSB_ERROR_NO_MEM => "No memory",
        c.LIBUSB_ERROR_NOT_SUPPORTED => "Not supported",
        c.LIBUSB_ERROR_OTHER => "Other error",
        else => "Unknown error",
    };
}
