//! Exact-path server registration. Serialized lifecycle, like Subscription.
//! Connection/context must outlive registration and every callback. A callback may
//! deinit its own registration, but must not wait or recursively dispatch.
const std = @import("std");
const c = @import("dbus_c");
const Connection = @import("Connection.zig");
const Message = @import("Message.zig");
const NativeError = @import("Error.zig");
const Self = @This();
state: ?*State = null,
pub const Result = enum { handled, not_handled, need_memory };
pub const Handler = struct { context: ?*anyopaque, callback: *const fn (?*anyopaque, *const Message) Result };
pub fn handler(context: anytype, comptime callback: fn (@TypeOf(context), *const Message) Result) Handler {
    const Adapter = struct {
        fn invoke(raw: ?*anyopaque, message: *const Message) Result {
            return callback(@ptrCast(@alignCast(raw.?)), message);
        }
    };
    return .{ .context = context, .callback = Adapter.invoke };
}
const State = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    path: [:0]u8,
    handler: Handler,
    active: bool = true,
    refs: usize = 1,
    fn release(self: *State) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
    fn unregistered(_: ?*c.DBusConnection, data: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(data.?));
        self.active = false;
        self.release();
    }
    fn dispatch(_: ?*c.DBusConnection, raw: ?*c.DBusMessage, data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
        const self: *State = @ptrCast(@alignCast(data.?));
        if (!self.active) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        self.refs += 1;
        defer self.release();
        var message = Message.fromBorrowed(raw.?);
        defer message.deinit();
        if (message.kind() != .method_call) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        return switch (self.handler.callback(self.handler.context, &message)) {
            .handled => c.DBUS_HANDLER_RESULT_HANDLED,
            .not_handled => c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED,
            .need_memory => c.DBUS_HANDLER_RESULT_NEED_MEMORY,
        };
    }
};
const vtable: c.DBusObjectPathVTable = .{
    .unregister_function = State.unregistered,
    .message_function = State.dispatch,
    .dbus_internal_pad1 = null,
    .dbus_internal_pad2 = null,
    .dbus_internal_pad3 = null,
    .dbus_internal_pad4 = null,
};
/// No bus round trip. Owns a copy of path. No automatic Properties/Introspection.
/// Return not_handled for unknown methods; libdbus supplies its default error.
/// For delayed replies retain Message.ref(), return handled, then send a reply
/// through Connection. Unregistration does not cancel retained requests.
pub fn init(allocator: std.mem.Allocator, connection: *Connection, path: [:0]const u8, callback: Handler) !Self {
    if (std.mem.indexOfScalar(u8, path, 0) != null or c.dbus_validate_path(path.ptr, null) == 0) return error.InvalidObjectPath;
    if (!connection.isConnected()) return error.Disconnected;
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    const owned_path = try allocator.dupeSentinel(u8, path, 0);
    errdefer allocator.free(owned_path);
    state.* = .{ .allocator = allocator, .connection = connection, .path = owned_path, .handler = callback };
    var detail = try NativeError.init();
    defer detail.deinit();
    if (c.dbus_connection_try_register_object_path(connection.raw(), owned_path.ptr, &vtable, state, detail.out()) == 0) {
        if (detail.hasName("org.freedesktop.DBus.Error.ObjectPathInUse")) return error.ObjectPathInUse;
        if (detail.hasName("org.freedesktop.DBus.Error.NoMemory")) return error.OutOfMemory;
        return error.RegistrationFailed;
    }
    state.refs += 1; // native registration reference
    return .{ .state = state };
}
/// Stops new delivery. Safe to repeat or call from this registration's handler.
pub fn deinit(self: *Self) void {
    const state = self.state orelse return;
    self.state = null;
    if (state.active) {
        state.active = false;
        _ = c.dbus_connection_unregister_object_path(state.connection.raw(), state.path.ptr);
    }
    state.release();
}
