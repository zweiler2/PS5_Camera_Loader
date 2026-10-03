const std = @import("std");
const builtin = @import("builtin");
const libusb = @import("libusb");

// Bulk transfers are limited to 512 bytes per USB standard
pub const CHUNK_SIZE = 512;

pub const VENDOR_ID = 0x05A9;
pub const PRODUCT_ID = 0x0580;

// Device only has one 1 USB interface (see `lsusb` output)
const INTERFACE_NUM = 0;

/// Command byte that signals the end of firmware upload and
/// tells the device to start executing the uploaded firmware
const FINAL_TRANSFER_COMMAND_BYTE = 0x5b;
/// Value indicating the firmware activation command
const FINAL_TRANSFER_VALUE = 0x2200;
/// Index used for the final control transfer
const FINAL_TRANSFER_INDEX = 0x8018;

pub fn main(init: std.process.Init) !void {
    // Create an allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const check = debug_allocator.deinit();
        if (check == .leak) {
            std.debug.print("A Memory leak was detected!\n", .{});
        }
    }
    const allocator: std.mem.Allocator = debug_allocator.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout: *std.Io.Writer = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr: *std.Io.Writer = &stderr_writer.interface;

    // Get arguments with proper cross-platform support
    var args: std.process.Args.Iterator = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    // Skip program name but store it for error message
    const prog_name: [:0]const u8 = args.next() orelse
        return error.NoProgramName;

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

    var libusb_context: ?*libusb.libusb_context = null;
    var rc: c_int = libusb.libusb_init(&libusb_context);
    if (rc != libusb.LIBUSB_SUCCESS) {
        try stderr.print("Failed to initialize libusb: {s}\n", .{getLibusbError(rc)});
        try stderr.flush();
        return error.LibUsbInitFailed;
    }
    defer libusb.libusb_exit(libusb_context);

    rc = libusb.libusb_set_option(libusb_context, libusb.LIBUSB_OPTION_LOG_LEVEL, libusb.LIBUSB_LOG_LEVEL_ERROR);
    if (rc != libusb.LIBUSB_SUCCESS) {
        try stderr.print("Failed to set libusb log level: {s}\n", .{getLibusbError(rc)});
        try stderr.flush();
        return error.LibUsbSetOptionFailed;
    }

    const libusb_dev_handle: ?*libusb.libusb_device_handle = libusb.libusb_open_device_with_vid_pid(libusb_context, VENDOR_ID, PRODUCT_ID);
    if (libusb_dev_handle == null) {
        try stderr.print("Could not open device\n", .{});
        try stderr.flush();
        return error.DeviceNotFound;
    }
    defer libusb.libusb_close(libusb_dev_handle);

    // Can't claim the device if the operating system is using it
    if (builtin.os.tag != .windows) {
        rc = libusb.libusb_kernel_driver_active(libusb_dev_handle, INTERFACE_NUM);
        if (rc != libusb.LIBUSB_SUCCESS) {
            rc = libusb.libusb_detach_kernel_driver(libusb_dev_handle, INTERFACE_NUM);
            if (rc != libusb.LIBUSB_SUCCESS) {
                try stderr.print("Failed to detach kernel driver: {s}\n", .{getLibusbError(rc)});
                try stderr.flush();
                return error.KernelDriverDetachFailed;
            }
            try stdout.print("Detaching kernel driver!\n", .{});
            try stdout.flush();
        }
    }

    rc = libusb.libusb_claim_interface(libusb_dev_handle, INTERFACE_NUM);
    if (rc != libusb.LIBUSB_SUCCESS) {
        try stderr.print("Failed to claim interface: {s}\n", .{getLibusbError(rc)});
        try stderr.flush();
        return error.InterfaceClaimFailed;
    }
    defer blk: {
        const release_interface: c_int = libusb.libusb_release_interface(libusb_dev_handle, INTERFACE_NUM);
        if (release_interface == libusb.LIBUSB_ERROR_NO_DEVICE) {
            break :blk;
        } else if (release_interface != libusb.LIBUSB_SUCCESS) {
            stderr.print("Failed to release libusb interface: {s}\n", .{getLibusbError(release_interface)}) catch {};
            stderr.flush() catch {};
        }
    }

    // Upload firmware
    try uploadFirmware(init.io, libusb_dev_handle, firmware_path, stderr);

    try stdout.print("Finished uploading firmware!\n", .{});
    try stdout.flush();
}

fn uploadFirmware(io: std.Io, libusb_dev_handle: ?*libusb.libusb_device_handle, firmware_path: []const u8, stderr: *std.Io.Writer) !void {
    const firmware_file: std.Io.File = try std.Io.Dir.cwd().openFile(io, firmware_path, .{});
    defer firmware_file.close(io);

    const file_size: usize = std.math.cast(usize, try firmware_file.length(io)) orelse
        return error.FileTooLarge;

    var chunk: [CHUNK_SIZE]u8 = @splat(0);
    var index: u16 = 0x14;
    var value: u16 = 0;
    var pos: u32 = 0;

    var reader = firmware_file.reader(io, &.{});
    while (pos < file_size) {
        const size: u16 = @min(CHUNK_SIZE, file_size - pos);
        _ = try reader.interface.readSliceShort(chunk[0..@intCast(size)]);

        try libUsbControlTransfer(
            libusb_dev_handle,
            libusb.LIBUSB_REQUEST_TYPE_VENDOR,
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
    chunk[0] = FINAL_TRANSFER_COMMAND_BYTE;
    try libUsbControlTransfer(
        libusb_dev_handle,
        libusb.LIBUSB_REQUEST_TYPE_VENDOR,
        0x0,
        FINAL_TRANSFER_VALUE,
        FINAL_TRANSFER_INDEX,
        1,
        &chunk,
        stderr,
    );
}

fn libUsbControlTransfer(
    dev_handle: ?*libusb.libusb_device_handle,
    request_type: u8,
    b_request: u8,
    w_value: u16,
    w_index: u16,
    w_length: u16,
    data: [*c]u8,
    stderr: *std.Io.Writer,
) !void {
    const bytes_transferred: c_int = libusb.libusb_control_transfer(
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
    if (bytes_transferred == libusb.LIBUSB_ERROR_NO_DEVICE) return;

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
        libusb.LIBUSB_ERROR_IO => "Input/Output error",
        libusb.LIBUSB_ERROR_INVALID_PARAM => "Invalid parameter",
        libusb.LIBUSB_ERROR_ACCESS => "Access denied",
        libusb.LIBUSB_ERROR_NO_DEVICE => "No such device",
        libusb.LIBUSB_ERROR_NOT_FOUND => "Not found",
        libusb.LIBUSB_ERROR_BUSY => "Resource busy",
        libusb.LIBUSB_ERROR_TIMEOUT => "Operation timed out",
        libusb.LIBUSB_ERROR_OVERFLOW => "Overflow",
        libusb.LIBUSB_ERROR_PIPE => "Pipe error",
        libusb.LIBUSB_ERROR_INTERRUPTED => "Interrupted",
        libusb.LIBUSB_ERROR_NO_MEM => "No memory",
        libusb.LIBUSB_ERROR_NOT_SUPPORTED => "Not supported",
        libusb.LIBUSB_ERROR_OTHER => "Other error",
        else => "Unknown error",
    };
}
