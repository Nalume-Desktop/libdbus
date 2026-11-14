//! All progression is explicit; failing Io proves begin/poll paths never wait.
const std = @import("std");
const t = std.testing;
const d = @import("libdbus");
const Driver = @import("test_support/PollDriver.zig");
const Session = struct {
    connection: d.Connection = undefined,
    driver: Driver = undefined,
    fn init(self: *Session, clock: std.Io) !void {
        var detail = try d.Error.init();
        defer detail.deinit();
        self.connection = try d.Connection.connect(std.Io.failing, .session, &detail);
        errdefer self.connection.deinit();
        self.driver = .{ .connection = &self.connection, .clock_io = clock };
        try self.driver.attach();
    }
    fn deinit(self: *Session) void {
        self.driver.detach();
        self.connection.deinit();
    }
    fn reply(self: *Session, peer: *Session, pending: *d.PendingCall) !d.Message {
        const deadline = self.driver.now() + 3000;
        while (true) {
            if (try pending.takeReply()) |message| return message;
            if (self.driver.now() >= deadline) return error.TimedOut;
            try peer.driver.step(0);
            try self.driver.step(1);
        }
    }
};
const Server = struct {
    registration: d.ObjectRegistration = .{},
    request: ?d.Message = null,
    calls: usize = 0,
    fn method(self: *Server, message: *const d.Message) d.ObjectRegistration.Result {
        if (!std.mem.eql(u8, message.interface() orelse "", "org.example.Server") or !std.mem.eql(u8, message.member() orelse "", "Delayed")) return .not_handled;
        self.calls += 1;
        self.request = message.ref();
        self.registration.deinit(); // Already-running callback remains safe.
        return .handled;
    }
    fn deinit(self: *Server) void {
        self.registration.deinit();
        if (self.request) |*message| message.deinit();
    }
};
fn request(connection: *d.Connection, member: [:0]const u8) !d.Message {
    return d.Message.methodCall(.{ .destination = connection.uniqueName().?, .path = "/test/server", .interface = "org.example.Server", .member = member });
}
fn allocationCase(allocator: std.mem.Allocator, connection: *d.Connection, server: *Server) !void {
    var registration = try d.ObjectRegistration.init(allocator, connection, "/allocation", d.methodHandler(server, Server.method));
    defer registration.deinit();
}
test "registered methods support default errors self-unregistration and delayed replies" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var client: Session = .{};
    try client.init(backend.io());
    defer client.deinit();
    var service: Session = .{};
    try service.init(backend.io());
    defer service.deinit();
    var server: Server = .{};
    defer server.deinit();
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{ &service.connection, &server });
    server.registration = try d.ObjectRegistration.init(t.allocator, &service.connection, "/test/server", d.methodHandler(&server, Server.method));
    try t.expectError(error.ObjectPathInUse, d.ObjectRegistration.init(t.allocator, &service.connection, "/test/server", d.methodHandler(&server, Server.method)));
    try t.expectError(error.InvalidObjectPath, d.ObjectRegistration.init(t.allocator, &service.connection, "not/a/path", d.methodHandler(&server, Server.method)));
    var unknown = try request(&service.connection, "Unknown");
    defer unknown.deinit();
    var missing = try client.connection.startCall(&unknown, .{});
    defer missing.deinit();
    var missing_reply = try client.reply(&service, &missing);
    defer missing_reply.deinit();
    try t.expectEqualStrings("org.freedesktop.DBus.Error.UnknownMethod", missing_reply.errorName().?);
    var call = try request(&service.connection, "Delayed");
    defer call.deinit();
    var pending = try client.connection.startCall(&call, .{});
    defer pending.deinit();
    const deadline = client.driver.now() + 3000;
    while (server.request == null) {
        if (client.driver.now() >= deadline) return error.TimedOut;
        try client.driver.step(0);
        try service.driver.step(1);
    }
    try t.expectEqual(@as(usize, 1), server.calls);
    try t.expectEqual(null, server.registration.state);
    try t.expectEqual(null, try pending.takeReply());
    // Original callback and registration are gone; the retained request can reply.
    var response = try d.Message.methodReturn(&server.request.?);
    defer response.deinit();
    var writer = response.writer();
    defer writer.deinit();
    try writer.write(d.String{ .bytes = "later" });
    try writer.finish();
    _ = try service.connection.send(&response);
    server.request.?.deinit();
    server.request = null;
    var received = try client.reply(&service, &pending);
    defer received.deinit();
    var body = received.iter();
    try t.expectEqualStrings("later", (try body.read(d.String)).bytes);
    var replacement = try d.ObjectRegistration.init(t.allocator, &service.connection, "/test/server", d.methodHandler(&server, Server.method));
    replacement.deinit();
    replacement.deinit();
}
const Observer = struct {
    signals: usize = 0,
    destroy: ?*d.NameWatch = null,
    fn signal(self: *Observer, _: *const d.Message) void {
        self.signals += 1;
    }
    fn owner(self: *Observer, _: d.NameWatch.Change) void {
        if (self.destroy) |watch| watch.deinit();
    }
};
test "pollable name subscriptions initialize with failing Io and safely cancel" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var client: Session = .{};
    try client.init(backend.io());
    defer client.deinit();
    var observer: Observer = .{};
    var sub = try d.Subscription.begin(t.allocator, &client.connection, .{ .sender = .{ .name = "org.example.Absent" }, .member = "Changed" }, d.signalHandler(&observer, Observer.signal), .{});
    defer sub.deinit();
    try t.expect(!try sub.pollReady());
    const deadline = client.driver.now() + 3000;
    while (!try sub.pollReady()) {
        if (client.driver.now() >= deadline) return error.TimedOut;
        try client.driver.step(1);
    }
    try t.expect(sub.ownerGeneration() != null);
    sub.deinit();
    var canceled = try d.Subscription.begin(t.allocator, &client.connection, .{ .sender = .{ .name = "org.example.Absent" } }, d.signalHandler(&observer, Observer.signal), .{});
    canceled.deinit();
    canceled.deinit();
    try t.expectError(error.Canceled, canceled.pollReady());
    var watch = try d.NameWatch.begin(t.allocator, &client.connection, "org.example.Absent", d.NameWatch.handler(&observer, Observer.owner), .{});
    defer watch.deinit();
    observer.destroy = &watch;
    while (true) {
        _ = watch.pollReady() catch |err| {
            try t.expectEqual(error.Canceled, err);
            break;
        };
        if (client.driver.now() >= deadline) return error.TimedOut;
        try client.driver.step(1);
    }
    try t.expectEqual(null, watch.state);
}
test "pollable rejected installation preserves remote error and rolls back" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var client: Session = .{};
    try client.init(backend.io());
    defer client.deinit();
    var observer: Observer = .{};
    var detail: d.RemoteError = .{};
    defer detail.deinit();
    const oversized: [2048:0]u8 = @splat('a');
    var sub = try d.Subscription.begin(t.allocator, &client.connection, .{ .arg0 = &oversized }, d.signalHandler(&observer, Observer.signal), .{ .remote_error = &detail });
    defer sub.deinit();
    const deadline = client.driver.now() + 3000;
    while (true) {
        _ = sub.pollReady() catch |err| {
            try t.expectEqual(error.RemoteError, err);
            break;
        };
        if (client.driver.now() >= deadline) return error.TimedOut;
        try client.driver.step(1);
    }
    try t.expectEqual(null, sub.state);
    try t.expectEqualStrings("org.freedesktop.DBus.Error.LimitsExceeded", detail.name().?);
    var disconnected = try d.NameWatch.begin(t.allocator, &client.connection, "org.example.Absent", null, .{});
    defer disconnected.deinit();
    client.connection.close();
    _ = disconnected.pollReady() catch |err| {
        try t.expect(err == error.Disconnected or err == error.RemoteError);
        try t.expectEqual(null, disconnected.state);
        return;
    };
    return error.ExpectedDisconnect;
}
