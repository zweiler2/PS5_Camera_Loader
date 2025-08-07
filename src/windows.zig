const std = @import("std");
const c = @cImport({
    @cInclude("windows.h");
    @cInclude("winusb.h");
    @cInclude("setupapi.h");
});

const CHUNK_SIZE = 512; // Bulk transfers are limited to 512 bytes per USB standard

const vendor_id = 0x05a9;
const product_id = 0x0580;

// Windows GUID for the device interface
// {932F61A9-6CF0-6FAF-8861-DA0D8B023C5F}
const DEVICE_INTERFACE_GUID = c.GUID{
    .Data1 = 0x932F61A9,
    .Data2 = 0x6CF0,
    .Data3 = 0x6FAF,
    .Data4 = .{ 0x88, 0x61, 0xDA, 0x0D, 0x8B, 0x02, 0x3C, 0x5F },
};

pub fn windowsInit() !void {
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
        return error.NoFirmwarePath;
    };

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
    try uploadFirmware(winusb_handle, firmware_path);

    try std.io.getStdOut().writer().print("Finished uploading firmware!\n", .{});
}

fn uploadFirmware(winusb_handle: c.WINUSB_INTERFACE_HANDLE, firmware_path: [:0]const u8) !void {
    const firmware_file: std.fs.File = try std.fs.cwd().openFile(firmware_path, .{});
    defer firmware_file.close();

    const file_size: u64 = try firmware_file.getEndPos();
    try firmware_file.seekTo(0);

    var chunk: [CHUNK_SIZE]u8 = [_]u8{0} ** CHUNK_SIZE;
    var index: u16 = 0x14;
    var value: u16 = 0;

    var pos: u32 = 0;
    while (pos < file_size) {
        const size: u16 = @min(CHUNK_SIZE, file_size - pos);
        _ = try firmware_file.read(chunk[0..@intCast(size)]);

        try winUsbControlTransfer(
            winusb_handle,
            0x40, // bmRequestType
            0x0, // bRequest
            value, // wValue
            index, // wIndex
            size, // wLength
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
        winusb_handle,
        0x40, // bmRequestType
        0x0, // bRequest
        0x2200, // wValue
        0x8018, // wIndex
        1, // wLength
        &chunk,
    );
}

fn winUsbControlTransfer(
    handle: c.WINUSB_INTERFACE_HANDLE,
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
        handle,
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
