//! Follows one well-known name. Serialized lifecycle and callback rules match Subscription.
//! owner() borrows mutable storage: copy it before a call that can dispatch changes.
const std = @import("std");
const c = @import("dbus_c");
const Connection = @import("Connection.zig");
const Message = @import("Message.zig");
const Subscription = @import("Subscription.zig");
const Remote = @import("Remote.zig");
const types = @import("types.zig");
const Self = @This();
state: ?*State = null,
pub const Change = struct { owner: ?[:0]const u8, generation: u64 };
pub const Handler = struct { context: ?*anyopaque, callback: *const fn (?*anyopaque, Change) void };
pub fn handler(context: anytype, comptime callback: fn (@TypeOf(context), Change) void) Handler {
    const Adapter = struct {
        fn invoke(raw: ?*anyopaque, change: Change) void {
            callback(@ptrCast(@alignCast(raw.?)), change);
        }
    };
    return .{ .context = context, .callback = Adapter.invoke };
}
const State = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    name: [:0]u8,
    callback: ?Handler,
    subscription: Subscription = .{},
    disconnected: Subscription = .{},
    owner_buffer: [256]u8 = undefined,
    owner_len: usize = 0,
    epoch: u64 = 0,
    refs: usize = 1,
    pending: ?@import("PendingCall.zig") = null,
    query_epoch: u64 = 0,
    ready: bool = false,
    options: Remote.Options,
    fn release(self: *State) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
    fn set(self: *State, value: []const u8) void {
        if (value.len >= self.owner_buffer.len) return;
        @memcpy(self.owner_buffer[0..value.len], value);
        self.owner_buffer[value.len] = 0;
        self.owner_len = value.len;
        self.epoch +%= 1;
        if (self.callback) |callback| callback.callback(callback.context, .{ .owner = self.owner(), .generation = self.epoch });
    }
    fn owner(self: *State) ?[:0]const u8 {
        return if (self.owner_len == 0) null else self.owner_buffer[0..self.owner_len :0];
    }
    fn changed(self: *State, message: *const Message) void {
        self.refs += 1;
        defer self.release();
        if (!std.mem.eql(u8, message.signature().bytes, "sss")) return;
        var body = message.iter();
        const name = (body.read(types.String) catch return).bytes;
        if (!std.mem.eql(u8, name, self.name)) return;
        _ = body.read(types.String) catch return;
        const new_owner = (body.read(types.String) catch return).bytes;
        if (new_owner.len != 0 and (new_owner[0] != ':' or c.dbus_validate_bus_name(new_owner.ptr, null) == 0)) return;
        self.set(new_owner);
    }
    fn disconnect(self: *State, _: *const Message) void {
        if (self.connection.isConnected()) return;
        self.refs += 1;
        defer self.release();
        self.set("");
    }
};
pub fn init(allocator: std.mem.Allocator, connection: *Connection, name: [:0]const u8, callback: ?Handler, options: Remote.Options) anyerror!Self {
    var result = try begin(allocator, connection, name, callback, options);
    errdefer result.deinit();
    _ = try result.advance(true);
    return result;
}
/// No waits or dispatch. pollReady advances installation and the initial owner
/// query. Callback/context and remote_error lifetimes match Subscription.begin.
/// owner()==null before readiness does not prove that the name is unowned.
pub fn begin(allocator: std.mem.Allocator, connection: *Connection, name: [:0]const u8, callback: ?Handler, options: Remote.Options) anyerror!Self {
    try (@import("SignalMatch.zig"){ .sender = .{ .name = name } }).validate();
    if (options.remote_error) |detail| detail.deinit();
    const state = try allocator.create(State);
    const owned_name = allocator.dupeSentinel(u8, name, 0) catch |err| {
        allocator.destroy(state);
        return err;
    };
    state.* = .{ .allocator = allocator, .connection = connection, .name = owned_name, .callback = callback, .options = options };
    var result: Self = .{ .state = state };
    errdefer result.deinit();
    state.disconnected = try Subscription.begin(allocator, connection, .{ .path = "/org/freedesktop/DBus/Local", .interface = "org.freedesktop.DBus.Local", .member = "Disconnected" }, Subscription.handler(state, State.disconnect), .{ .local_only = true });
    state.subscription = try Subscription.begin(allocator, connection, .{ .sender = .{ .unique = "org.freedesktop.DBus" }, .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "NameOwnerChanged", .arg0 = state.name }, Subscription.handler(state, State.changed), .{ .timeout = options.timeout, .remote_error = options.remote_error });
    return result;
}
pub fn pollReady(self: *Self) anyerror!bool {
    return self.advance(false);
}
/// Shared initialization driver. wait=true requires independently progressing Io.
pub fn advance(self: *Self, wait: bool) anyerror!bool {
    const state = self.state orelse return error.Canceled;
    state.refs += 1;
    defer state.release();
    errdefer self.deinit();
    if (state.ready) return true;
    if (!try state.subscription.advance(wait)) return false;
    if (self.state == null) return error.Canceled;
    if (state.pending == null) {
        state.query_epoch = state.epoch;
        const bus = try Remote.init(state.connection, .{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus" });
        var request = try bus.methodCall("GetNameOwner");
        defer request.deinit();
        var writer = request.writer();
        defer writer.deinit();
        try writer.write(types.String{ .bytes = state.name });
        try writer.finish();
        state.pending = try state.connection.startCall(&request, .{ .timeout = state.options.timeout });
    }
    var reply = if (wait) try state.pending.?.wait(state.connection.io) else (try state.pending.?.takeReply() orelse return false);
    state.pending = null;
    defer reply.deinit();
    if (self.state == null) return error.Canceled;
    var initial_owner: []const u8 = "";
    if (reply.kind() == .error_reply) {
        if (!std.mem.eql(u8, reply.errorName() orelse "", "org.freedesktop.DBus.Error.NameHasNoOwner")) {
            if (state.options.remote_error) |detail| detail.capture(&reply);
            return error.RemoteError;
        }
    } else {
        if (reply.kind() != .method_return or !std.mem.eql(u8, reply.signature().bytes, "s")) return error.InvalidReply;
        var body = reply.iter();
        const owner_name = (try body.read(types.String)).bytes;
        if (owner_name.len == 0 or owner_name.len > 255 or c.dbus_validate_bus_name(owner_name.ptr, null) == 0) return error.InvalidReply;
        initial_owner = owner_name;
    }
    state.ready = true;
    state.options.remote_error = null;
    if (state.epoch == state.query_epoch) state.set(initial_owner);
    if (self.state == null) return error.Canceled;
    return true;
}
pub fn owner(self: *const Self) ?[:0]const u8 {
    const state = self.state orelse return null;
    if (!state.connection.isConnected()) return null;
    return state.owner();
}
pub fn generation(self: *const Self) u64 {
    return self.state.?.epoch;
}
pub fn deinit(self: *Self) void {
    const state = self.state orelse return;
    self.state = null;
    if (state.pending) |*pending| pending.deinit();
    state.subscription.deinit();
    state.disconnected.deinit();
    state.release();
}
