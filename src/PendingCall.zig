//! Owns a pending request. Single consumer: do not concurrently access this value.
//! wait consumes the handle on success, cancellation, or failure. Io cancellation is
//! the way to cancel a running wait; cancel/deinit are for an unconsumed handle.
const std = @import("std");
const c = @import("dbus_c");
const Message = @import("Message.zig");
const Self = @This();
pointer: ?*c.DBusPendingCall,
connection: *c.DBusConnection, // Kept alive by the native pending call.

pub fn deinit(self: *Self) void {
    if (self.pointer) |p| {
        c.dbus_pending_call_cancel(p);
        c.dbus_pending_call_unref(p);
    }
    self.pointer = null;
}
pub fn cancel(self: *Self) void {
    self.deinit();
}
/// True for an available native reply OR a disconnected connection.
/// takeReply/wait distinguish the reply from local error.Disconnected.
pub fn isCompleted(self: *const Self) bool {
    return c.dbus_pending_call_get_completed(self.pointer.?) != 0 or c.dbus_connection_get_is_connected(self.connection) == 0;
}

/// Nonblocking alternative for custom reactors. A completed reply is transferred once.
pub fn takeReply(self: *Self) error{ MissingReply, Disconnected }!?Message {
    if (c.dbus_pending_call_get_completed(self.pointer.?) == 0) {
        if (c.dbus_connection_get_is_connected(self.connection) != 0) return null;
        self.deinit();
        return error.Disconnected;
    }
    const p = self.pointer.?;
    self.pointer = null;
    defer c.dbus_pending_call_unref(p);
    return Message.adopt(c.dbus_pending_call_steal_reply(p) orelse return error.MissingReply);
}

const WaitState = struct {
    refs: std.atomic.Value(usize) = .init(2), // waiter + native notification data
    event: std.Io.Event = .unset,
    io: std.Io,
    fn release(self: *WaitState) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.c_allocator.destroy(self);
    }
    fn notify(_: ?*c.DBusPendingCall, data: ?*anyopaque) callconv(.c) void {
        const self: *WaitState = @ptrCast(@alignCast(data.?));
        self.event.set(self.io);
    }
    fn disconnected(conn: ?*c.DBusConnection, message: ?*c.DBusMessage, data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
        if (c.dbus_message_is_signal(message, "org.freedesktop.DBus.Local", "Disconnected") != 0 and
            c.dbus_connection_get_is_connected(conn) == 0)
        {
            const self: *WaitState = @ptrCast(@alignCast(data.?));
            self.event.set(self.io);
        }
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }
    fn free(data: ?*anyopaque) callconv(.c) void {
        const self: *WaitState = @ptrCast(@alignCast(data.?));
        self.release();
    }
};

/// Requires an independently progressing connection driver. Native timeout/error
/// replies remain Messages, preserving their names and bodies. Io cancellation is
/// error.Canceled and does not revoke a method already executing remotely.
/// The Io backend must remain alive while driver callbacks can still run.
pub fn wait(self: *Self, io: std.Io) (std.Io.Cancelable || error{ OutOfMemory, MissingReply, Disconnected })!Message {
    const p = self.pointer.?;
    self.pointer = null;
    const state = std.heap.c_allocator.create(WaitState) catch {
        c.dbus_pending_call_cancel(p);
        c.dbus_pending_call_unref(p);
        return error.OutOfMemory;
    };
    state.* = .{ .io = io };
    defer state.release();
    defer {
        c.dbus_pending_call_cancel(p);
        c.dbus_pending_call_unref(p);
    }
    if (c.dbus_pending_call_set_notify(p, WaitState.notify, state, WaitState.free) == 0) {
        state.release(); // native ownership was not installed
        return error.OutOfMemory;
    }
    // A per-wait filter wakes infinite calls on disconnect. Native filter ownership
    // keeps the state alive even if removal races a dispatch already in progress.
    _ = state.refs.fetchAdd(1, .monotonic);
    if (c.dbus_connection_add_filter(self.connection, WaitState.disconnected, state, WaitState.free) == 0) {
        state.release();
        return error.OutOfMemory;
    }
    defer c.dbus_connection_remove_filter(self.connection, WaitState.disconnected, state);
    // Registration does not replay earlier completion or disconnection.
    if (c.dbus_pending_call_get_completed(p) == 0) {
        if (c.dbus_connection_get_is_connected(self.connection) == 0) return error.Disconnected;
        try state.event.wait(io);
    }
    if (c.dbus_pending_call_get_completed(p) == 0 and c.dbus_connection_get_is_connected(self.connection) == 0) return error.Disconnected;
    return Message.adopt(c.dbus_pending_call_steal_reply(p) orelse return error.MissingReply);
}
