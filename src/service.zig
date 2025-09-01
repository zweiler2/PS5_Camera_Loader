const std = @import("std");
const c = @cImport({
    // Force direct usage of W functions (for MINGW)
    // istead of using the __MINGW_NAME_AW macro
    // https://github.com/ziglang/zig/issues/9180
    @cDefine("CreateEvent", "CreateEventW");
    @cDefine("RegisterDeviceNotification", "RegisterDeviceNotificationW");
    @cDefine("CreateService", "CreateServiceW");
    @cDefine("OpenSCManager", "OpenSCManagerW");
    @cDefine("StartServiceCtrlDispatcher", "StartServiceCtrlDispatcherW");
    @cDefine("RegisterServiceCtrlHandlerEx", "RegisterServiceCtrlHandlerExW");

    // Architecture defines (for MSVC)
    @cDefine("_M_AMD64", "100");
    @cDefine("_AMD64_", "1");
    @cDefine("_WIN64", "1");

    // Include core Windows headers
    @cInclude("windef.h");
    @cInclude("winbase.h");
    @cInclude("winuser.h");
    @cInclude("winsvc.h");
    @cInclude("dbt.h");
});

const SERVICE_NAMEW = L("PS5CameraFirmwareLoader");
const LOADER_PATH = "C:\\PS5_Camera_Loader\\PS5_Camera_Loader.exe";
const FIRMWARE_PATH = "C:\\PS5_Camera_Loader\\firmware.bin";

const GUID_DEVINTERFACE_USBBOOT: c.GUID =
    .{
        .Data1 = 0x932F61A9,
        .Data2 = 0x6CF0,
        .Data3 = 0x6FAF,
        .Data4 = .{ 0x88, 0x61, 0xDA, 0x0D, 0x8B, 0x02, 0x3C, 0x5F },
    };

var service_status_handle: c.SERVICE_STATUS_HANDLE = undefined;
var service_status: c.SERVICE_STATUS = undefined;
var service_stop_event: c.HANDLE = null;

pub fn main() !u8 {
    const service_table: [2]c.SERVICE_TABLE_ENTRYW = .{
        .{ .lpServiceName = @ptrCast(@constCast(SERVICE_NAMEW)), .lpServiceProc = serviceMain },
        .{ .lpServiceName = null, .lpServiceProc = null },
    };

    if (c.StartServiceCtrlDispatcherW(&service_table) == c.FALSE) {
        return @intCast(c.GetLastError());
    }

    return 0;
}

fn launchFirmwareLoader() bool {
    const cmdline = [_][]const u8{ LOADER_PATH, FIRMWARE_PATH };

    var process: std.process.Child = .init(&cmdline, std.heap.page_allocator);
    process.spawn() catch {
        return false;
    };

    _ = process.wait() catch {
        return false;
    };

    return true;
}

fn serviceMain(argc: c.DWORD, argv: [*c]c.LPWSTR) callconv(.c) void {
    _ = argc;
    _ = argv;

    service_status_handle = c.RegisterServiceCtrlHandlerExW(
        SERVICE_NAMEW,
        serviceCrtlHandlerEx,
        null,
    );
    if (service_status_handle == null) {
        return;
    }

    service_status = .{
        .dwServiceType = c.SERVICE_WIN32,
        .dwCurrentState = c.SERVICE_RUNNING,
        .dwControlsAccepted = c.SERVICE_ACCEPT_STOP,
        .dwWin32ExitCode = 0,
        .dwServiceSpecificExitCode = 0,
        .dwCheckPoint = 0,
        .dwWaitHint = 0,
    };

    if (c.SetServiceStatus(service_status_handle, &service_status) == c.FALSE) {
        return;
    }

    // Create a stop event to wait on
    service_stop_event = c.CreateEvent(null, c.TRUE, c.FALSE, null);
    defer _ = c.CloseHandle(service_stop_event);
    if (service_stop_event == null) {
        service_status.dwCurrentState = c.SERVICE_STOPPED;
        service_status.dwWin32ExitCode = c.GetLastError();
        _ = c.SetServiceStatus(service_status_handle, &service_status);
        return;
    }

    service_status.dwCurrentState = c.SERVICE_RUNNING;
    if (c.SetServiceStatus(service_status_handle, &service_status) == c.FALSE) {
        return;
    }

    // Create a worker thread to handle device events
    const thread_handle: c.HANDLE = c.CreateThread(null, 0, serviceWorkerThread, null, 0, null);
    defer _ = c.CloseHandle(thread_handle);
    if (thread_handle == null) {
        service_status.dwCurrentState = c.SERVICE_STOPPED;
        service_status.dwWin32ExitCode = c.GetLastError();
        _ = c.SetServiceStatus(service_status_handle, &service_status);
        return;
    }

    _ = c.WaitForSingleObject(thread_handle, c.INFINITE);

    service_status.dwCurrentState = c.SERVICE_STOPPED;
    service_status.dwWin32ExitCode = 0;
    _ = c.SetServiceStatus(service_status_handle, &service_status);
}

fn serviceCrtlHandlerEx(ctrl_code: c.DWORD, event_type: c.DWORD, event_data: c.PVOID, context: c.PVOID) callconv(.c) c.DWORD {
    _ = event_type;
    _ = context;
    switch (ctrl_code) {
        c.SERVICE_CONTROL_STOP => {
            service_status.dwCurrentState = c.SERVICE_STOPPED;
            service_status.dwWin32ExitCode = 0;
            _ = c.SetServiceStatus(service_status_handle, &service_status);
            _ = c.SetEvent(service_stop_event);
        },
        c.SERVICE_CONTROL_DEVICEEVENT => {
            if (event_data) |real_event_data| {
                const pHdr: c.PDEV_BROADCAST_HDR = @ptrCast(@alignCast(real_event_data));
                if (pHdr.*.dbch_devicetype == c.DBT_DEVTYP_DEVICEINTERFACE) {
                    _ = launchFirmwareLoader();
                }
            }
        },
        else => {},
    }

    return c.NO_ERROR;
}

fn serviceWorkerThread(param: c.PVOID) callconv(.c) c.DWORD {
    _ = param;

    var notification_filter: c.DEV_BROADCAST_DEVICEINTERFACE_W = .{
        .dbcc_size = @sizeOf(c.DEV_BROADCAST_DEVICEINTERFACE),
        .dbcc_devicetype = c.DBT_DEVTYP_DEVICEINTERFACE,
        .dbcc_classguid = GUID_DEVINTERFACE_USBBOOT,
    };

    const dev_notify_handle: c.HDEVNOTIFY = c.RegisterDeviceNotification(
        service_status_handle,
        &notification_filter,
        c.DEVICE_NOTIFY_SERVICE_HANDLE,
    );

    if (dev_notify_handle == null) {
        return 1;
    }

    while (c.WaitForSingleObject(service_stop_event, 100) != c.WAIT_OBJECT_0) {
        // Service is running
        std.Thread.sleep(std.time.ns_per_ms * 100); // Prevent tight loop
    }

    if (dev_notify_handle) |real_dev_notify_handle| {
        _ = c.UnregisterDeviceNotification(real_dev_notify_handle);
    }

    return 0;
}

// zig fmt: off
fn installService() void {
    const sc_manager_handle: c.SC_HANDLE = c.OpenSCManagerW(
        null,                        // local machine
        null,                        // ServiceActive database
        c.SC_MANAGER_CREATE_SERVICE, // full access rights
    );
    defer c.CloseServiceHandle(sc_manager_handle);
    if (sc_manager_handle == null) {
        return;
    }

    const sc_service_handle: c.SC_HANDLE = c.CreateServiceW(
        sc_manager_handle,                                 // SC manager
        SERVICE_NAMEW,                                     // name of service
        SERVICE_NAMEW,                                     // service name to display
        c.SERVICE_ALL_ACCESS,                              // desired access
        c.SERVICE_WIN32_OWN_PROCESS,                       // service type
        c.SERVICE_AUTO_START,                              // start type
        c.SERVICE_ERROR_NORMAL,                            // error control type
        L("C:\\PS5_Camera_Loader\\PS5_Camera_Loader.exe"), // Path to service's binary
        null,                                              // no load ordering group
        null,                                              // no tag identifier
        null,                                              // no dependencies
        null,                                              // LocalSystem account
        null,                                              // no password
    );
    defer c.CloseServiceHandle(sc_service_handle);
    if (sc_service_handle == null) {
        return;
    }
}
// zig fmt: on

fn L(comptime str: [:0]const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(str);
}
