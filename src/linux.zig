const std = @import("std");
const main_file = @import("main.zig");
const c = @cImport({
    @cInclude("libusb.h");
});

pub fn loader(firmware_file: *const std.fs.File) !void {
    var libusb_context: ?*c.libusb_context = null;
    var rc: c_int = c.libusb_init(&libusb_context);

    _ = c.libusb_set_option(libusb_context, c.LIBUSB_OPTION_LOG_LEVEL, c.LIBUSB_LOG_LEVEL_WARNING);

    if (rc != c.LIBUSB_SUCCESS) {
        std.log.err("Failed to initialize libusb: {s}", .{getLibusbError(rc)});
        return error.LibUsbInitFailed;
    }
    defer c.libusb_exit(libusb_context);

    const libusb_dev_handle: ?*c.libusb_device_handle = c.libusb_open_device_with_vid_pid(libusb_context, main_file.vendor_id, main_file.product_id);
    if (libusb_dev_handle == null) {
        std.log.err("Could not open device", .{});
        return error.DeviceNotFound;
    }
    defer c.libusb_close(libusb_dev_handle);

    // Device only has one 1 USB interface (see `lsusb` output)
    const interface_num = 0;

    // Can't claim the device if the operating system is using it
    if (c.libusb_kernel_driver_active(libusb_dev_handle, interface_num) != c.LIBUSB_SUCCESS) {
        if (c.libusb_detach_kernel_driver(libusb_dev_handle, interface_num) != c.LIBUSB_SUCCESS) {
            std.log.err("Failed to detach kernel driver: {s}", .{getLibusbError(rc)});
            return error.KernelDriverDetachFailed;
        }
        try std.io.getStdOut().writer().print("Detaching kernel driver!\n", .{});
    }

    rc = c.libusb_claim_interface(libusb_dev_handle, interface_num);
    if (rc != c.LIBUSB_SUCCESS) {
        std.log.err("Failed to claim interface: {s}", .{getLibusbError(rc)});
        return error.InterfaceClaimFailed;
    }
    defer _ = c.libusb_release_interface(libusb_dev_handle, interface_num);

    // Upload firmware
    try uploadFirmware(libusb_dev_handle, firmware_file);

    try std.io.getStdOut().writer().print("Finished uploading firmware!\n", .{});
}

fn uploadFirmware(libusb_dev_handle: ?*c.libusb_device_handle, firmware_file: *const std.fs.File) !void {
    const file_size: u64 = try firmware_file.getEndPos();
    try firmware_file.seekTo(0);

    var chunk: [main_file.CHUNK_SIZE]u8 = [_]u8{0} ** main_file.CHUNK_SIZE;
    var index: u16 = 0x14;
    var value: u16 = 0;
    var pos: u32 = 0;

    while (pos < file_size) {
        const size: u16 = @min(main_file.CHUNK_SIZE, file_size - pos);
        _ = try firmware_file.read(chunk[0..@intCast(size)]);

        try libUsbControlTransfer(
            libusb_dev_handle,
            0x40,
            0x0,
            value,
            index,
            size,
            &chunk,
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
        0x40,
        0x0,
        0x2200,
        0x8018,
        1,
        &chunk,
    );
}

fn libUsbControlTransfer(
    dev_handle: ?*c.libusb_device_handle,
    bm_request_type: u8,
    b_request: u8,
    w_value: u16,
    w_index: u16,
    w_length: u16,
    data: [*c]u8,
) !void {
    const bytes_transferred: c_int = c.libusb_control_transfer(
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
    if (bytes_transferred == c.LIBUSB_ERROR_NO_DEVICE) return;

    if (bytes_transferred == 0) {
        std.log.err("No bytes transferred", .{});
        return error.NoBytesTransferred;
    } else if (bytes_transferred < 0) {
        std.log.err("USB transfer error: {s}", .{getLibusbError(bytes_transferred)});
        return error.TransferError;
    } else if (bytes_transferred > 0 and bytes_transferred != w_length) {
        std.log.err("libusb reported only {d} bytes transferred, but firmware file is {d} bytes", .{ bytes_transferred, w_length });
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
