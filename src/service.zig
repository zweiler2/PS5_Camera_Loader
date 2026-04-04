const std = @import("std");
const zigwin32 = @import("zigwin32");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const SERVICE_NAMEW = L("PS5CameraFirmwareLoader");
const LOADER_PATH = "C:\\PS5_Camera_Loader\\PS5_Camera_Loader.exe";
const FIRMWARE_PATH = "C:\\PS5_Camera_Loader\\firmware.bin";

const GUID_DEVINTERFACE_USBBOOT: zigwin32.zig.Guid = .initString("932F61A9-6CF0-6FAF-8861-DA0D8B023C5F");

var service_status_handle: zigwin32.system.services.SERVICE_STATUS_HANDLE = undefined;
var service_status: zigwin32.system.services.SERVICE_STATUS = undefined;
var service_stop_event: std.os.windows.HANDLE = undefined;

pub fn main() !u8 {
    const service_table: [2]zigwin32.system.services.SERVICE_TABLE_ENTRYW = .{
        .{ .lpServiceName = @ptrCast(@constCast(SERVICE_NAMEW)), .lpServiceProc = serviceMain },
        .{ .lpServiceName = null, .lpServiceProc = null },
    };

    if (zigwin32.system.services.StartServiceCtrlDispatcherW(&service_table[0]) == std.os.windows.FALSE) {
        return @intCast(@intFromEnum(std.os.windows.GetLastError()));
    }

    return 0;
}

fn launchFirmwareLoader() void {
    const cmdline = [_][]const u8{ LOADER_PATH, FIRMWARE_PATH };

    var process: std.process.Child = .init(&cmdline, std.heap.page_allocator);
    _ = process.spawnAndWait() catch {};
}

fn serviceMain(argc: std.os.windows.DWORD, argv: ?*?std.os.windows.LPWSTR) callconv(.winapi) void {
    _ = argc;
    _ = argv;

    service_status_handle = zigwin32.system.services.RegisterServiceCtrlHandlerExW(
        SERVICE_NAMEW,
        serviceCrtlHandlerEx,
        null,
    );

    service_status = .{
        .dwServiceType = .{ .WIN32_OWN_PROCESS = 1 },
        .dwCurrentState = .RUNNING,
        .dwControlsAccepted = zigwin32.system.services.SERVICE_ACCEPT_STOP,
        .dwWin32ExitCode = 0,
        .dwServiceSpecificExitCode = 0,
        .dwCheckPoint = 0,
        .dwWaitHint = 0,
    };

    if (zigwin32.system.services.SetServiceStatus(service_status_handle, &service_status) == std.os.windows.FALSE) {
        return;
    }

    // Create a stop event to wait on
    service_stop_event = zigwin32.system.threading.CreateEventW(null, std.os.windows.TRUE, std.os.windows.FALSE, null) orelse
        {
            service_status.dwCurrentState = .STOPPED;
            service_status.dwWin32ExitCode = @intFromEnum(std.os.windows.GetLastError());
            _ = zigwin32.system.services.SetServiceStatus(service_status_handle, &service_status);
            return;
        };
    defer std.os.windows.CloseHandle(service_stop_event);

    service_status.dwCurrentState = .RUNNING;
    if (zigwin32.system.services.SetServiceStatus(service_status_handle, &service_status) == std.os.windows.FALSE) {
        return;
    }

    // Create a worker thread to handle device events
    const thread_handle: std.os.windows.HANDLE = std.os.windows.kernel32.CreateThread(null, 0, serviceWorkerThread, null, 0, null) orelse {
        service_status.dwCurrentState = .STOPPED;
        service_status.dwWin32ExitCode = @intFromEnum(std.os.windows.GetLastError());
        _ = zigwin32.system.services.SetServiceStatus(service_status_handle, &service_status);
        return;
    };
    defer std.os.windows.CloseHandle(thread_handle);

    std.os.windows.WaitForSingleObject(thread_handle, std.os.windows.INFINITE) catch {};

    service_status.dwCurrentState = .STOPPED;
    service_status.dwWin32ExitCode = 0;
    _ = zigwin32.system.services.SetServiceStatus(service_status_handle, &service_status);
}

fn serviceCrtlHandlerEx(
    ctrl_code: std.os.windows.DWORD,
    event_type: std.os.windows.DWORD,
    event_data: ?std.os.windows.LPVOID,
    context: ?std.os.windows.LPVOID,
) callconv(.winapi) std.os.windows.DWORD {
    _ = context;

    switch (ctrl_code) {
        zigwin32.system.services.SERVICE_CONTROL_STOP => {
            service_status.dwCurrentState = .STOPPED;
            service_status.dwWin32ExitCode = 0;
            _ = zigwin32.system.services.SetServiceStatus(service_status_handle, &service_status);
            _ = zigwin32.system.threading.SetEvent(service_stop_event);
        },
        zigwin32.system.services.SERVICE_CONTROL_DEVICEEVENT => {
            if (event_type == zigwin32.system.system_services.DBT_DEVICEARRIVAL) {
                const dbch: *zigwin32.system.system_services.DEV_BROADCAST_HDR = @ptrCast(@alignCast(event_data));
                if (dbch.dbch_devicetype == .DEVICEINTERFACE) {
                    launchFirmwareLoader();
                }
            }
        },
        else => {},
    }

    return @intFromEnum(std.os.windows.Win32Error.SUCCESS);
}

fn serviceWorkerThread(param: std.os.windows.LPVOID) callconv(.winapi) std.os.windows.DWORD {
    _ = param;

    var notification_filter: zigwin32.system.system_services.DEV_BROADCAST_DEVICEINTERFACE_W = .{
        .dbcc_size = @sizeOf(zigwin32.system.system_services.DEV_BROADCAST_DEVICEINTERFACE_W),
        .dbcc_devicetype = @intFromEnum(zigwin32.system.system_services.DBT_DEVTYP_DEVICEINTERFACE),
        .dbcc_classguid = GUID_DEVINTERFACE_USBBOOT,
        .dbcc_name = .{0},
        .dbcc_reserved = 0,
    };

    const dev_notify_handle: std.os.windows.PVOID = zigwin32.ui.windows_and_messaging.RegisterDeviceNotificationW(
        @ptrFromInt(@as(usize, @intCast(service_status_handle))),
        &notification_filter,
        .SERVICE_HANDLE,
    ) orelse
        return 1;
    defer _ = zigwin32.system.system_services.UnregisterDeviceNotification(dev_notify_handle);

    while (true) {
        std.os.windows.WaitForSingleObject(service_stop_event, 100) catch |err| {
            if (err != error.WaitTimeOut) return @intFromError(err);
            continue;
        };
        break; // WAIT_OBJECT_0 was signaled
    }

    return 0;
}
