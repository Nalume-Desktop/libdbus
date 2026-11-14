//! Owned registration. Lifecycle, initialization waits and dispatch must be serialized
//! in one cooperative execution context. No arbitrary cross-thread unsubscribe guarantee.
//! Connection must outlive the handle. Callbacks borrow Message/context, may deinit
//! subscriptions, but must not block, call waiting APIs, or recursively dispatch.
const std = @import("std");
const c = @import("dbus_c");
const Connection = @import("Connection.zig");
const Message = @import("Message.zig");
const SignalMatch = @import("SignalMatch.zig");
const NameWatch = @import("NameWatch.zig");
const types = @import("types.zig");
const Self = @This();
state: ?*State = null,
pub const Handler = struct { context: ?*anyopaque, callback: *const fn (?*anyopaque, *const Message) void };
pub fn handler(context: anytype, comptime callback: fn (@TypeOf(context), *const Message) void) Handler {
    const Adapter = struct {
        fn invoke(raw: ?*anyopaque, message: *const Message) void {
            callback(@ptrCast(@alignCast(raw.?)), message);
        }
    };
    return .{ .context = context, .callback = Adapter.invoke };
}
pub const Options = struct {
    timeout: Connection.Timeout = .default,
    remote_error: ?*@import("RemoteError.zig") = null,
    /// Only for local or already-routed signals. Does not install a broker rule.
    local_only: bool = false,
};
const State = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    connection: *Connection,
    match: SignalMatch,
    handler: Handler,
    refs: usize = 1,
    active: bool = true,
    installed: bool = false,
    remove_needed: bool = false,
    removal: ?Message = null,
    reserved: ?*c.DBusPreallocatedSend = null,
    owner_watch: ?NameWatch = null,
    pending: ?@import("PendingCall.zig") = null,
    ready: bool = false,
    detail: ?*@import("RemoteError.zig") = null,
    fn release(self: *State) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        if (self.removal) |*message| message.deinit();
        if (self.reserved) |reserved| c.dbus_connection_free_preallocated_send(self.connection.raw(), reserved);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn free(raw: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(raw.?));
        self.release();
    }
    fn filter(_: ?*c.DBusConnection, raw: ?*c.DBusMessage, context: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
        const self: *State = @ptrCast(@alignCast(context.?));
        if (!self.active) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        var message = Message.fromBorrowed(raw.?);
        defer message.deinit();
        const owner = if (self.owner_watch) |*watch| watch.owner() else null;
        if (self.match.matches(&message, owner)) self.handler.callback(self.handler.context, &message);
        // Native filter references defer State destruction through self-unsubscription.
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }
};
fn matchRequest(member: [:0]const u8, rule: [:0]const u8, no_reply: bool) !Message {
    var message = try Message.methodCall(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = member, .no_reply = no_reply, .auto_start = false });
    errdefer message.deinit();
    var writer = message.writer();
    defer writer.deinit();
    try writer.write(types.String{ .bytes = rule });
    try writer.finish();
    return message;
}
/// Context must already be ready: callbacks may run before installation returns.
/// The returned handle owns copied match strings. Failure removes any installed filter.
pub fn init(allocator: std.mem.Allocator, connection: *Connection, match: SignalMatch, callback: Handler, options: Options) anyerror!Self {
    var result = try begin(allocator, connection, match, callback, options);
    errdefer result.deinit();
    _ = try result.advance(true);
    return result;
}
/// Starts installation without waiting or dispatching. Drive the connection and
/// call pollReady until true. Callback context and remote_error must stay alive
/// through initialization; callbacks may arrive before readiness. deinit cancels.
pub fn begin(allocator: std.mem.Allocator, connection: *Connection, match: SignalMatch, callback: Handler, options: Options) anyerror!Self {
    try match.validate();
    if (options.remote_error) |detail| detail.deinit();
    const state = try allocator.create(State);
    state.* = .{ .allocator = allocator, .arena = .init(allocator), .connection = connection, .match = match, .handler = callback, .detail = options.remote_error };
    var result: Self = .{ .state = state };
    errdefer result.deinit();
    const arena = state.arena.allocator();
    state.match = try match.clone(arena);
    if (state.match.sender) |sender| switch (sender) {
        .name => |name| state.owner_watch = try NameWatch.begin(allocator, connection, name, null, .{ .timeout = options.timeout, .remote_error = options.remote_error }),
        .unique => {},
    };
    const rule = try state.match.ruleAlloc(arena);
    if (!options.local_only) {
        state.removal = try matchRequest("RemoveMatch", rule, true);
        state.reserved = c.dbus_connection_preallocate_send(connection.raw()) orelse return error.OutOfMemory;
    }
    if (c.dbus_connection_add_filter(connection.raw(), State.filter, state, State.free) == 0) return error.OutOfMemory;
    state.refs += 1;
    state.installed = true;
    if (!options.local_only) {
        var request = try matchRequest("AddMatch", rule, false);
        defer request.deinit();
        state.pending = try connection.startCall(&request, .{ .timeout = options.timeout });
        state.remove_needed = true;
    }
    return result;
}
/// Returns false while installing, true when ready. Errors tear down the handle.
/// Does not wait or dispatch. A ready handle stays ready until explicitly closed.
pub fn pollReady(self: *Self) anyerror!bool {
    return self.advance(false);
}
/// Internal shared state-machine driver; wait=true requires independently progressing Io.
pub fn advance(self: *Self, wait: bool) anyerror!bool {
    const state = self.state orelse return error.Canceled;
    state.refs += 1;
    defer state.release();
    errdefer self.deinit();
    if (state.ready) return true;
    if (state.owner_watch) |*watch| if (!try watch.advance(wait)) return false;
    if (self.state == null) return error.Canceled;
    if (state.pending) |*pending| {
        var reply = if (wait) try pending.wait(state.connection.io) else (try pending.takeReply() orelse return false);
        state.pending = null;
        defer reply.deinit();
        if (!state.active) return error.Canceled;
        if (reply.kind() == .error_reply) {
            // NoReply can be local: the broker may still have installed the rule.
            if (!std.mem.eql(u8, reply.errorName() orelse "", "org.freedesktop.DBus.Error.NoReply")) state.remove_needed = false;
            if (state.detail) |detail| detail.capture(&reply);
            return error.RemoteError;
        }
        if (reply.kind() != .method_return or reply.signature().bytes.len != 0) return error.InvalidReply;
    }
    if (!state.active) return error.Canceled;
    state.ready = true;
    state.detail = null;
    return true;
}
/// Stops local delivery immediately; queues preallocated RemoveMatch without waiting.
/// Repeated deinit is safe. During a callback, its already-running invocation may finish.
pub fn deinit(self: *Self) void {
    const state = self.state orelse return;
    self.state = null;
    state.active = false;
    if (state.pending) |*pending| pending.deinit();
    if (state.owner_watch) |*watch| watch.deinit();
    if (state.installed) c.dbus_connection_remove_filter(state.connection.raw(), State.filter, state);
    if (state.remove_needed) {
        c.dbus_connection_send_preallocated(state.connection.raw(), state.reserved.?, state.removal.?.raw(), null);
        state.reserved = null;
    }
    state.release();
}
pub fn ownerGeneration(self: *const Self) ?u64 {
    const state = self.state orelse return null;
    return if (state.owner_watch) |*watch| watch.generation() else null;
}
