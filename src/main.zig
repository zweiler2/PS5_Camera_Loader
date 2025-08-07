const std = @import("std");
const c = @cImport({
    @cInclude("libusb.h");
});

const CHUNK_SIZE = 512; // Bulk transfers are limited to 512 bytes per USB standard

const vendor_id = 0x05a9;
const product_id = 0x0580;

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

    var libusb_context: ?*c.libusb_context = null;
    var rc: c_int = c.libusb_init(&libusb_context);

    _ = c.libusb_set_option(libusb_context, c.LIBUSB_OPTION_LOG_LEVEL, c.LIBUSB_LOG_LEVEL_WARNING);

    if (rc != c.LIBUSB_SUCCESS) {
        std.log.err("Failed to initialize libusb: {s}", .{getLibusbError(rc)});
        return error.LibUsbInitFailed;
    }
    defer c.libusb_exit(libusb_context);

    const libusb_dev_handle: ?*c.libusb_device_handle = c.libusb_open_device_with_vid_pid(libusb_context, vendor_id, product_id);
    if (libusb_dev_handle == null) {
        std.log.err("Could not open device", .{});
        return error.DeviceNotFound;
    }
    defer c.libusb_close(libusb_dev_handle);

    // Device only has one 1 USB interface (see `lsusb` output)
    const interface_num = 0;

    // Can't claim the device if the operating system is using it
    if (c.libusb_kernel_driver_active(libusb_dev_handle, interface_num) != 0) {
        if (c.libusb_detach_kernel_driver(libusb_dev_handle, interface_num) != c.LIBUSB_SUCCESS) {
            std.log.err("Failed to detach kernel driver: {s}", .{getLibusbError(rc)});
            return error.KernelDriverDetachFailed;
        }
    }

    rc = c.libusb_claim_interface(libusb_dev_handle, interface_num);
    if (rc != c.LIBUSB_SUCCESS) {
        std.log.err("Failed to claim interface: {s}", .{getLibusbError(rc)});
        return error.InterfaceClaimFailed;
    }

    var chunk: [CHUNK_SIZE]u8 = [_]u8{0} ** CHUNK_SIZE;
    const usb_write_req_type: u8 = 0x40;

    // Open and read firmware file
    const firmware_file: std.fs.File = try std.fs.cwd().openFile(firmware_path, .{});
    defer firmware_file.close();

    const file_size: u64 = try firmware_file.getEndPos();
    try firmware_file.seekTo(0);

    var index: u16 = 0x14;
    var value: u16 = 0;

    var pos: u32 = 0;
    while (pos < file_size) {
        const size: u16 = @min(CHUNK_SIZE, file_size - pos);
        _ = try firmware_file.read(chunk[0..@intCast(size)]);

        try ctrlTransferWrapper(
            libusb_dev_handle,
            usb_write_req_type,
            0x0,
            value,
            index,
            &chunk,
            size,
        );

        if (@as(u32, value) + size > std.math.maxInt(u16)) {
            index += 1;
        }

        value = @truncate(@as(u32, value) + size);
        pos += size;
    }

    // Final transfer
    chunk[0] = 0x5b;
    try ctrlTransferWrapper(
        libusb_dev_handle,
        usb_write_req_type,
        0x0,
        0x2200,
        0x8018,
        &chunk,
        1,
    );

    try std.io.getStdOut().writer().print("Finished uploading firmware!\n", .{});
}

fn ctrlTransferWrapper(
    dev_handle: ?*c.libusb_device_handle,
    bm_request_type: u8,
    b_request: u8,
    w_value: u16,
    w_index: u16,
    data: [*c]u8,
    w_length: u16,
) !void {
    const bytes_written: c_int = c.libusb_control_transfer(
        dev_handle,
        bm_request_type,
        b_request,
        w_value,
        w_index,
        data,
        w_length,
        0,
    );

    // Device disconnection is expected during firmware upload
    // The device changes from Boot mode (05a9:0580) to Camera mode (05a9:058c)
    if (bytes_written == c.LIBUSB_ERROR_NO_DEVICE) return;

    if (bytes_written == 0) {
        std.log.err("No bytes transferred", .{});
        return error.NoBytesTransferred;
    } else if (bytes_written < 0) {
        std.log.err("USB transfer error: {s}", .{getLibusbError(bytes_written)});
        return error.TransferError;
    } else if (bytes_written > 0 and bytes_written != w_length) {
        std.log.err("libusb reported only {d} bytes transferred, but firmware file is {d} bytes", .{ bytes_written, w_length });
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
