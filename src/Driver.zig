//! Borrowed event-loop hooks. libdbus calls them on the thread doing native work.
//! Keep context alive through detach; serialize installation/removal with the driver.
//! Callbacks must not dispatch, wait for replies, or reenter the connection.
const c = @import("dbus_c");

pub const Hooks = struct {
    context: ?*anyopaque = null,
    add_watch: *const fn (?*c.DBusWatch, ?*anyopaque) callconv(.c) c.dbus_bool_t,
    remove_watch: *const fn (?*c.DBusWatch, ?*anyopaque) callconv(.c) void,
    toggle_watch: *const fn (?*c.DBusWatch, ?*anyopaque) callconv(.c) void,
    add_timeout: *const fn (?*c.DBusTimeout, ?*anyopaque) callconv(.c) c.dbus_bool_t,
    remove_timeout: *const fn (?*c.DBusTimeout, ?*anyopaque) callconv(.c) void,
    toggle_timeout: *const fn (?*c.DBusTimeout, ?*anyopaque) callconv(.c) void,
    wakeup: *const fn (?*anyopaque) callconv(.c) void,
    dispatch_status: *const fn (?*c.DBusConnection, c.DBusDispatchStatus, ?*anyopaque) callconv(.c) void,
};

/// Borrowed native watch; invalid immediately after remove_watch returns.
/// Use watch identity, not fd, as registration key: several watches can share an fd.
pub const Watch = struct {
    raw: *c.DBusWatch,
    pub fn fd(self: Watch) c_int {
        return c.dbus_watch_get_unix_fd(self.raw);
    }
    pub fn enabled(self: Watch) bool {
        return c.dbus_watch_get_enabled(self.raw) != 0;
    }
    pub fn flags(self: Watch) c_uint {
        return c.dbus_watch_get_flags(self.raw);
    }
    /// Pass DBUS_WATCH_* bits, not OS poll bits. May synchronously remove/toggle watches.
    pub fn handle(self: Watch, events: c_uint) error{OutOfMemory}!void {
        if (!self.enabled()) return;
        if (c.dbus_watch_handle(self.raw, events) == 0) return error.OutOfMemory;
    }
};
pub const Timeout = struct {
    raw: *c.DBusTimeout,
    pub fn intervalMs(self: Timeout) c_int {
        return c.dbus_timeout_get_interval(self.raw);
    }
    pub fn enabled(self: Timeout) bool {
        return c.dbus_timeout_get_enabled(self.raw) != 0;
    }
    /// Invoke only when due. May synchronously remove/toggle timeout registrations.
    pub fn handle(self: Timeout) error{OutOfMemory}!void {
        if (!self.enabled()) return;
        if (c.dbus_timeout_handle(self.raw) == 0) return error.OutOfMemory;
    }
};
pub const DispatchStatus = enum(c_int) {
    data_remains = c.DBUS_DISPATCH_DATA_REMAINS,
    complete = c.DBUS_DISPATCH_COMPLETE,
    need_memory = c.DBUS_DISPATCH_NEED_MEMORY,
};
