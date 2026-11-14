//! Private owned connection with a borrowed Io backend; no built-in polling thread.
//! The backend must outlive all calls and callbacks. Do not replace it while connected.
//! Initialize thread support before concurrent use of ANY libdbus API.
//! Stop/join drivers and finish/cancel callers before deinit. Do not copy ownership.
const std = @import("std");
const c = @import("dbus_c");
const Message = @import("Message.zig");
const NativeError = @import("Error.zig");
const PendingCall = @import("PendingCall.zig");
const Driver = @import("Driver.zig");
const Self = @This();
pointer: ?*c.DBusConnection,
io: std.Io,
attached: bool = false,

pub const Bus = enum(c.DBusBusType) { session = c.DBUS_BUS_SESSION, system = c.DBUS_BUS_SYSTEM, starter = c.DBUS_BUS_STARTER };
pub const Timeout = union(enum) {
    default,
    milliseconds: u31,
    infinite,
    fn native(self: Timeout) error{InvalidTimeout}!c_int {
        return switch (self) {
            .default => c.DBUS_TIMEOUT_USE_DEFAULT,
            .milliseconds => |ms| if (ms == std.math.maxInt(u31)) error.InvalidTimeout else @intCast(ms),
            .infinite => c.DBUS_TIMEOUT_INFINITE,
        };
    }
};
pub const CallOptions = struct { timeout: Timeout = .default };
pub const SendError = error{ OutOfMemory, Disconnected, AlreadySent };

/// Idempotent. Call before spawning threads that can enter libdbus.
pub fn initThreads() error{OutOfMemory}!void {
    if (c.dbus_threads_init_default() == 0) return error.OutOfMemory;
}

/// Establishes and registers a private bus connection. This startup operation is
/// native/blocking and is not Io-cancelable. detail must be unset; failures retain it.
pub fn connect(io: std.Io, bus: Bus, detail: *NativeError) error{ OutOfMemory, ConnectFailed }!Self {
    try initThreads();
    const p = c.dbus_bus_get_private(@backingInt(bus), detail.out()) orelse return error.ConnectFailed;
    c.dbus_connection_set_exit_on_disconnect(p, 0);
    return .{ .pointer = p, .io = io };
}
/// Open a private address, optionally performing the bus Hello registration.
/// register_bus=false is for peer-to-peer connections. Startup may block.
pub fn open(io: std.Io, address: [:0]const u8, register_bus: bool, detail: *NativeError) error{ OutOfMemory, InvalidAddress, ConnectFailed }!Self {
    if (std.mem.indexOfScalar(u8, address, 0) != null) return error.InvalidAddress;
    try initThreads();
    const p = c.dbus_connection_open_private(address.ptr, detail.out()) orelse return error.ConnectFailed;
    c.dbus_connection_set_exit_on_disconnect(p, 0);
    if (register_bus and c.dbus_bus_register(p, detail.out()) == 0) {
        c.dbus_connection_close(p);
        c.dbus_connection_unref(p);
        return error.ConnectFailed;
    }
    return .{ .pointer = p, .io = io };
}
pub fn raw(self: *const Self) *c.DBusConnection {
    return self.pointer.?;
}
pub fn isConnected(self: *const Self) bool {
    return c.dbus_connection_get_is_connected(self.raw()) != 0;
}
pub fn uniqueName(self: *const Self) ?[:0]const u8 {
    const p = c.dbus_bus_get_unique_name(self.raw());
    return if (p == null) null else std.mem.span(p);
}
/// Initiates shutdown. Keep dispatching the local Disconnected signal to wake
/// pending waiters, or cancel them explicitly before stopping the driver.
pub fn close(self: *Self) void {
    if (self.pointer) |p| if (c.dbus_connection_get_is_connected(p) != 0) {
        c.dbus_connection_close(p);
    };
}
pub fn deinit(self: *Self) void {
    if (self.pointer == null) return;
    self.detachDriver();
    self.close();
    c.dbus_connection_unref(self.raw());
    self.pointer = null;
}
fn checkSend(self: *const Self, message: *const Message) SendError!void {
    if (!self.isConnected()) return error.Disconnected;
    if (message.serial() != 0) return error.AlreadySent;
}
/// Enqueue only; the driver writes the bytes. Sending locks the native message.
pub fn send(self: *Self, message: *const Message) SendError!u32 {
    try self.checkSend(message);
    var serial: u32 = 0;
    if (c.dbus_connection_send(self.raw(), message.raw(), &serial) == 0) return error.OutOfMemory;
    return serial;
}
pub fn startCall(self: *Self, request: *const Message, options: CallOptions) (SendError || error{ InvalidRequest, InvalidTimeout })!PendingCall {
    if (request.kind() != .method_call or request.noReply()) return error.InvalidRequest;
    try self.checkSend(request);
    var pending: ?*c.DBusPendingCall = null;
    if (c.dbus_connection_send_with_reply(self.raw(), request.raw(), &pending, try options.timeout.native()) == 0) return error.OutOfMemory;
    return .{ .pointer = pending orelse return error.Disconnected, .connection = self.raw() };
}
/// Ordinary sequential function; callers may use io.async(Self.call, ...).
/// Does not read sockets, run dispatch, or flush. An independent driver is required.
pub fn call(self: *Self, request: *const Message, options: CallOptions) !Message {
    var pending = try self.startCall(request, options);
    defer pending.deinit();
    return pending.wait(self.io);
}
/// Lifecycle and dispatch must share one serialized execution context.
pub fn subscribe(self: *Self, allocator: std.mem.Allocator, match: @import("SignalMatch.zig"), handler: @import("Subscription.zig").Handler, options: @import("Subscription.zig").Options) !@import("Subscription.zig") {
    return @import("Subscription.zig").init(allocator, self, match, handler, options);
}

pub fn hasOutgoing(self: *const Self) bool {
    return c.dbus_connection_has_messages_to_send(self.raw()) != 0;
}
pub fn dispatchStatus(self: *const Self) Driver.DispatchStatus {
    return @fromBackingInt(@intCast(c.dbus_connection_get_dispatch_status(self.raw())));
}
/// Process at most budget queued messages. Only one driver should dispatch.
/// data_remains requires rescheduling; need_memory requires a later retry, not a spin.
pub fn dispatch(self: *Self, budget: usize) Driver.DispatchStatus {
    var status = self.dispatchStatus();
    var remaining = budget;
    while (remaining != 0 and status == .data_remains) : (remaining -= 1) {
        status = @fromBackingInt(@intCast(c.dbus_connection_dispatch(self.raw())));
    }
    return status;
}
/// Install external reactor callbacks; may synchronously add existing registrations.
/// Context is borrowed, never freed by the library. No callback may reenter the connection.
/// All callbacks must be safe on threads that send/cancel as well as the driver thread.
pub fn attachDriver(self: *Self, hooks: Driver.Hooks) error{ OutOfMemory, DriverAlreadyAttached }!void {
    if (self.attached) return error.DriverAlreadyAttached;
    if (c.dbus_connection_set_watch_functions(self.raw(), hooks.add_watch, hooks.remove_watch, hooks.toggle_watch, hooks.context, null) == 0) return error.OutOfMemory;
    errdefer _ = c.dbus_connection_set_watch_functions(self.raw(), null, null, null, null, null);
    if (c.dbus_connection_set_timeout_functions(self.raw(), hooks.add_timeout, hooks.remove_timeout, hooks.toggle_timeout, hooks.context, null) == 0) return error.OutOfMemory;
    c.dbus_connection_set_wakeup_main_function(self.raw(), hooks.wakeup, hooks.context, null);
    c.dbus_connection_set_dispatch_status_function(self.raw(), hooks.dispatch_status, hooks.context, null);
    self.attached = true;
    // Driver must inspect dispatchStatus once after attaching: registration isn't a notification.
}
/// Stop concurrent native operations first; removal callbacks invalidate registrations.
pub fn detachDriver(self: *Self) void {
    if (!self.attached) return;
    c.dbus_connection_set_wakeup_main_function(self.raw(), null, null, null);
    c.dbus_connection_set_dispatch_status_function(self.raw(), null, null, null);
    _ = c.dbus_connection_set_timeout_functions(self.raw(), null, null, null, null, null);
    _ = c.dbus_connection_set_watch_functions(self.raw(), null, null, null, null, null);
    self.attached = false;
}
