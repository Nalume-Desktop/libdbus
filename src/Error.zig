//! Owns native DBusError storage. Ordinary copies do not transfer/duplicate ownership.
const std = @import("std");
const c = @import("dbus_c");
const Self = @This();
pointer: ?*c.DBusError,

pub fn init() error{OutOfMemory}!Self {
    return .{ .pointer = c.zig_dbus_error_new() orelse return error.OutOfMemory };
}

pub fn deinit(self: *Self) void {
    if (self.pointer) |p| c.zig_dbus_error_delete(p);
    self.pointer = null;
}

/// Borrow for a native call. libdbus requires an unset error on entry.
pub fn out(self: *Self) *c.DBusError {
    std.debug.assert(!self.isSet());
    return self.pointer.?;
}

pub fn clear(self: *Self) void {
    c.dbus_error_free(self.pointer.?);
}
pub fn isSet(self: *const Self) bool {
    return c.dbus_error_is_set(self.pointer.?) != 0;
}
pub fn name(self: *const Self) ?[:0]const u8 {
    const p = c.zig_dbus_error_name(self.pointer.?);
    return if (p == null) null else std.mem.span(p);
}
pub fn text(self: *const Self) ?[:0]const u8 {
    const p = c.zig_dbus_error_text(self.pointer.?);
    return if (p == null) null else std.mem.span(p);
}
pub fn hasName(self: *const Self, expected: []const u8) bool {
    return if (self.name()) |n| std.mem.eql(u8, n, expected) else false;
}

/// Transfer ownership, leaving self safe to deinit (but not to inspect).
pub fn take(self: *Self) Self {
    const result = self.*;
    self.pointer = null;
    return result;
}
