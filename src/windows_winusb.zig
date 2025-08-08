const std = @import("std");
const main_file = @import("main.zig");
const c = @cImport({
    @cInclude("windows.h");
    @cInclude("winusb.h");
    @cInclude("setupapi.h");
});

// Windows GUID for the device interface
// {932F61A9-6CF0-6FAF-8861-DA0D8B023C5F}
const DEVICE_INTERFACE_GUID = c.GUID{
    .Data1 = 0x932F61A9,
    .Data2 = 0x6CF0,
    .Data3 = 0x6FAF,
    .Data4 = .{ 0x88, 0x61, 0xDA, 0x0D, 0x8B, 0x02, 0x3C, 0x5F },
};

pub fn loader(allocator: std.mem.Allocator, firmware_file: *const std.fs.File) !void {
    // Get device info set
    const dev_info = c.SetupDiGetClassDevsW(
        &DEVICE_INTERFACE_GUID,
        null,
        null,
        c.DIGCF_PRESENT | c.DIGCF_DEVICEINTERFACE,
    );
    if (dev_info == c.INVALID_HANDLE_VALUE) {
        std.log.err("Failed to get device info", .{});
        return error.DeviceInfoError;
    }
    defer _ = c.SetupDiDestroyDeviceInfoList(dev_info);

    var device_interface_data = c.SP_DEVICE_INTERFACE_DATA{
        .cbSize = @sizeOf(c.SP_DEVICE_INTERFACE_DATA),
        .InterfaceClassGuid = undefined,
        .Flags = undefined,
        .Reserved = undefined,
    };

    // Enumerate device interfaces
    if (c.SetupDiEnumDeviceInterfaces(
        dev_info,
        null,
        &DEVICE_INTERFACE_GUID,
        0,
        &device_interface_data,
    ) == 0) {
        std.log.err("Failed to enumerate device interfaces\n\tIs the firmware already loaded?", .{});
        return error.DeviceEnumerationError;
    }

    // Get required size for device interface detail
    var required_size: c.DWORD = undefined;
    _ = c.SetupDiGetDeviceInterfaceDetailW(
        dev_info,
        &device_interface_data,
        null,
        0,
        &required_size,
        null,
    );

    // Allocate memory for device interface detail with proper alignment
    const detail_align = @alignOf(c.SP_DEVICE_INTERFACE_DETAIL_DATA_W);
    const device_interface_detail = try allocator.alignedAlloc(u8, detail_align, required_size);
    defer allocator.free(device_interface_detail);

    var detail = @as(*c.SP_DEVICE_INTERFACE_DETAIL_DATA_W, @ptrCast(device_interface_detail.ptr));
    detail.cbSize = @sizeOf(c.SP_DEVICE_INTERFACE_DETAIL_DATA_W);

    // Get device interface detail
    if (c.SetupDiGetDeviceInterfaceDetailW(
        dev_info,
        &device_interface_data,
        detail,
        required_size,
        null,
        null,
    ) == 0) {
        std.log.err("Failed to get device interface detail", .{});
        return error.DeviceDetailError;
    }

    // Open device
    const device_handle = c.CreateFileW(
        &detail.DevicePath,
        c.GENERIC_WRITE | c.GENERIC_READ,
        c.FILE_SHARE_WRITE | c.FILE_SHARE_READ,
        null,
        c.OPEN_EXISTING,
        c.FILE_ATTRIBUTE_NORMAL | c.FILE_FLAG_OVERLAPPED,
        null,
    );
    if (device_handle == c.INVALID_HANDLE_VALUE) {
        std.log.err("Failed to open device", .{});
        return error.DeviceOpenError;
    }
    defer _ = c.CloseHandle(device_handle);

    // Initialize WinUSB
    var winusb_handle: c.WINUSB_INTERFACE_HANDLE = undefined;
    if (c.WinUsb_Initialize(device_handle, &winusb_handle) == 0) {
        std.log.err("Failed to initialize WinUSB", .{});
        return error.WinUSBInitError;
    }
    defer _ = c.WinUsb_Free(winusb_handle);

    // Upload firmware
    try uploadFirmware(winusb_handle, firmware_file);

    try std.io.getStdOut().writer().print("Finished uploading firmware!\n", .{});
}

fn uploadFirmware(winusb_dev_handle: c.WINUSB_INTERFACE_HANDLE, firmware_file: *const std.fs.File) !void {
    const file_size: u64 = try firmware_file.getEndPos();
    try firmware_file.seekTo(0);

    var chunk: [main_file.CHUNK_SIZE]u8 = [_]u8{0} ** main_file.CHUNK_SIZE;
    var index: u16 = 0x14;
    var value: u16 = 0;

    var pos: u32 = 0;
    while (pos < file_size) {
        const size: u16 = @min(main_file.CHUNK_SIZE, file_size - pos);
        _ = try firmware_file.read(chunk[0..@intCast(size)]);

        try winUsbControlTransfer(
            winusb_dev_handle,
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
    try winUsbControlTransfer(
        winusb_dev_handle,
        0x40,
        0x0,
        0x2200,
        0x8018,
        1,
        &chunk,
    );
}

fn winUsbControlTransfer(
    dev_handle: c.WINUSB_INTERFACE_HANDLE,
    bm_request_type: u8,
    b_request: u8,
    w_value: u16,
    w_index: u16,
    w_length: u16,
    data: [*]u8,
) !void {
    const setup = c.WINUSB_SETUP_PACKET{
        .RequestType = bm_request_type,
        .Request = b_request,
        .Value = w_value,
        .Index = w_index,
        .Length = w_length,
    };

    var bytes_transferred: c.ULONG = undefined;
    if (c.WinUsb_ControlTransfer(
        dev_handle,
        setup,
        data,
        w_length,
        &bytes_transferred,
        null,
    ) == 0) {
        std.log.err("USB transfer error: {}", .{c.GetLastError()});
        return error.TransferError;
    }

    if (bytes_transferred == 0) {
        std.log.err("No bytes transferred", .{});
        return error.NoBytesTransferred;
    } else if (bytes_transferred != w_length) {
        std.log.err("Transfer incomplete: got {d} bytes, expected {d}", .{ bytes_transferred, w_length });
        return error.IncompleteTransfer;
    }
}
