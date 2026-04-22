const std = @import("std");
const win32 = @import("win32");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const SERVICE_NAMEW = L("PS5CameraFirmwareLoader");
const LOADER_PATH = "C:\\PS5_Camera_Loader\\PS5_Camera_Loader.exe";
const FIRMWARE_PATH = "C:\\PS5_Camera_Loader\\firmware.bin";

const GUID_DEVINTERFACE_USBBOOT: win32.zig.Guid = .initString("932F61A9-6CF0-6FAF-8861-DA0D8B023C5F");

var service_status_handle: win32.system.services.SERVICE_STATUS_HANDLE = undefined;
var service_status: win32.system.services.SERVICE_STATUS = undefined;
var service_stop_event: std.os.windows.HANDLE = undefined;

pub fn main() !u8 {
    const service_table: [2]win32.system.services.SERVICE_TABLE_ENTRYW = .{
        .{ .lpServiceName = @ptrCast(@constCast(SERVICE_NAMEW)), .lpServiceProc = serviceMain },
        .{ .lpServiceName = null, .lpServiceProc = null },
    };

    if (win32.system.services.StartServiceCtrlDispatcherW(&service_table[0]) == @intFromBool(false)) {
        return @intCast(@intFromEnum(std.os.windows.GetLastError()));
    }

    return 0;
}

fn launchFirmwareLoader() void {
    const cmdline = [_][]const u8{ LOADER_PATH, FIRMWARE_PATH };

    var io_threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_threaded.deinit();

    const io = io_threaded.io();

    var process: std.process.Child = std.process.spawn(io, .{
        .argv = &cmdline,
        .create_no_window = true,
    }) catch {
        return;
    };
    _ = process.wait(io) catch {};
}

fn serviceMain(argc: std.os.windows.DWORD, argv: ?*?std.os.windows.LPWSTR) callconv(.winapi) void {
    _ = argc;
    _ = argv;

    service_status_handle = win32.system.services.RegisterServiceCtrlHandlerExW(
        SERVICE_NAMEW,
        serviceCrtlHandlerEx,
        null,
    );

    service_status = .{
        .dwServiceType = .{ .WIN32_OWN_PROCESS = 1 },
        .dwCurrentState = .RUNNING,
        .dwControlsAccepted = win32.system.services.SERVICE_ACCEPT_STOP,
        .dwWin32ExitCode = 0,
        .dwServiceSpecificExitCode = 0,
        .dwCheckPoint = 0,
        .dwWaitHint = 0,
    };

    if (win32.system.services.SetServiceStatus(service_status_handle, &service_status) == @intFromBool(false)) {
        return;
    }

    // Create a stop event to wait on
    service_stop_event = win32.system.threading.CreateEventW(null, @intFromBool(true), @intFromBool(false), null) orelse
        {
            service_status.dwCurrentState = .STOPPED;
            service_status.dwWin32ExitCode = @intFromEnum(std.os.windows.GetLastError());
            _ = win32.system.services.SetServiceStatus(service_status_handle, &service_status);
            return;
        };
    defer std.os.windows.CloseHandle(service_stop_event);

    service_status.dwCurrentState = .RUNNING;
    if (win32.system.services.SetServiceStatus(service_status_handle, &service_status) == @intFromBool(false)) {
        return;
    }

    // Create a worker thread to handle device events
    const thread_handle: std.os.windows.HANDLE = win32.system.threading.CreateThread(null, 0, serviceWorkerThread, null, .{}, null) orelse {
        service_status.dwCurrentState = .STOPPED;
        service_status.dwWin32ExitCode = @intFromEnum(std.os.windows.GetLastError());
        _ = win32.system.services.SetServiceStatus(service_status_handle, &service_status);
        return;
    };
    defer std.os.windows.CloseHandle(thread_handle);

    _ = win32.system.threading.WaitForSingleObject(thread_handle, win32.system.windows_programming.INFINITE);

    service_status.dwCurrentState = .STOPPED;
    service_status.dwWin32ExitCode = 0;
    _ = win32.system.services.SetServiceStatus(service_status_handle, &service_status);
}

fn serviceCrtlHandlerEx(
    ctrl_code: std.os.windows.DWORD,
    event_type: std.os.windows.DWORD,
    event_data: ?std.os.windows.LPVOID,
    context: ?std.os.windows.LPVOID,
) callconv(.winapi) std.os.windows.DWORD {
    _ = context;

    switch (ctrl_code) {
        win32.system.services.SERVICE_CONTROL_STOP => {
            service_status.dwCurrentState = .STOPPED;
            service_status.dwWin32ExitCode = 0;
            _ = win32.system.services.SetServiceStatus(service_status_handle, &service_status);
            _ = win32.system.threading.SetEvent(service_stop_event);
        },
        win32.system.services.SERVICE_CONTROL_DEVICEEVENT => {
            if (event_type == win32.system.system_services.DBT_DEVICEARRIVAL) {
                const dbch: *win32.system.system_services.DEV_BROADCAST_HDR = @ptrCast(@alignCast(event_data));
                if (dbch.dbch_devicetype == .DEVICEINTERFACE) {
                    launchFirmwareLoader();
                }
            }
        },
        else => {},
    }

    return @intFromEnum(std.os.windows.Win32Error.SUCCESS);
}

fn serviceWorkerThread(param: ?std.os.windows.LPVOID) callconv(.winapi) std.os.windows.DWORD {
    _ = param;

    var notification_filter: win32.system.system_services.DEV_BROADCAST_DEVICEINTERFACE_W = .{
        .dbcc_size = @sizeOf(win32.system.system_services.DEV_BROADCAST_DEVICEINTERFACE_W),
        .dbcc_devicetype = @intFromEnum(win32.system.system_services.DBT_DEVTYP_DEVICEINTERFACE),
        .dbcc_classguid = GUID_DEVINTERFACE_USBBOOT,
        .dbcc_name = .{0},
        .dbcc_reserved = 0,
    };

    const dev_notify_handle: std.os.windows.PVOID = win32.ui.windows_and_messaging.RegisterDeviceNotificationW(
        @ptrFromInt(@as(usize, @intCast(service_status_handle))),
        &notification_filter,
        .SERVICE_HANDLE,
    ) orelse
        return 1;
    defer _ = win32.system.system_services.UnregisterDeviceNotification(dev_notify_handle);

    while (true) {
        const err = win32.system.threading.WaitForSingleObject(service_stop_event, 100);
        if (err != .NO_ERROR) {
            if (err != .WAIT_TIMEOUT) return @intFromEnum(err);
            continue;
        }
        break; // WAIT_OBJECT_0 was signaled
    }

    return 0;
}
