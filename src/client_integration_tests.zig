//! Uses the enclosing integration runner's isolated session bus only.
const std = @import("std");
const t = std.testing;
const d = @import("libdbus");
const Driver = @import("test_support/PollDriver.zig");
const Harness = struct {
    conn: d.Connection = undefined,
    driver: Driver = undefined,
    waits: Driver.WaitIo = undefined,
    fn init(self: *Harness, io: std.Io) !void {
        self.waits = .{ .driver = &self.driver };
        var detail = try d.Error.init();
        defer detail.deinit();
        self.conn = try d.Connection.connect(self.waits.io(), .session, &detail);
        errdefer self.conn.deinit();
        self.driver = .{ .connection = &self.conn, .clock_io = io };
        try self.driver.attach();
    }
    fn deinit(self: *Harness) void {
        self.driver.detach();
        self.conn.deinit();
    }
    fn bus(self: *Harness) !d.Remote {
        return d.Remote.init(&self.conn, .{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus" });
    }
    fn sync(self: *Harness) !void {
        const remote = try self.bus();
        var request = try remote.methodCall("GetId");
        defer request.deinit();
        var reply = try remote.call(&request, .{});
        defer reply.deinit();
    }
    fn name(self: *Harness, value: [:0]const u8, acquire: bool) !void {
        const remote = try self.bus();
        var request = try remote.methodCall(if (acquire) "RequestName" else "ReleaseName");
        defer request.deinit();
        var writer = request.writer();
        defer writer.deinit();
        try writer.write(d.String{ .bytes = value });
        if (acquire) try writer.write(@as(u32, d.c.DBUS_NAME_FLAG_DO_NOT_QUEUE));
        try writer.finish();
        var reply = try remote.call(&request, .{});
        defer reply.deinit();
        var body = reply.iter();
        try t.expectEqual(@as(u32, 1), try body.read(u32));
    }
    fn emit(self: *Harness, arg: [:0]const u8, destination: ?[:0]const u8) !void {
        var signal = try d.Message.signal("/test/child", "org.example.Test", "Changed");
        defer signal.deinit();
        if (destination) |dest| try t.expect(d.c.dbus_message_set_destination(signal.raw(), dest.ptr) != 0);
        var writer = signal.writer();
        defer writer.deinit();
        try writer.write(d.String{ .bytes = arg });
        try writer.finish();
        _ = try self.conn.send(&signal);
        try self.sync();
    }
};
const Recorder = struct {
    count: usize = 0,
    own: ?*d.Subscription = null,
    other: ?*d.Subscription = null,
    held: ?d.Message = null,
    fn signal(self: *Recorder, message: *const d.Message) void {
        self.count += 1;
        if (self.held == null) self.held = message.ref();
        if (self.other) |subscription| subscription.deinit();
        if (self.own) |subscription| subscription.deinit();
    }
    fn deinit(self: *Recorder) void {
        if (self.held) |*message| message.deinit();
    }
};
test "subscriptions broadcast, retain callback messages, and safely unsubscribe self and another" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var client: Harness = .{};
    try client.init(backend.io());
    defer client.deinit();
    var server: Harness = .{};
    try server.init(backend.io());
    defer server.deinit();
    const match: d.SignalMatch = .{ .sender = .{ .unique = server.conn.uniqueName().? }, .path_namespace = "/test", .member = "Changed" };
    var first: Recorder = .{};
    defer first.deinit();
    var second: Recorder = .{};
    defer second.deinit();
    var third: Recorder = .{};
    defer third.deinit();
    var a = try client.conn.subscribe(t.allocator, match, d.signalHandler(&first, Recorder.signal), .{});
    defer a.deinit();
    var b = try client.conn.subscribe(t.allocator, match, d.signalHandler(&second, Recorder.signal), .{});
    defer b.deinit();
    var survivor = try client.conn.subscribe(t.allocator, match, d.signalHandler(&third, Recorder.signal), .{});
    defer survivor.deinit();
    first.own = &a;
    first.other = &b;
    try server.emit("one", null);
    try client.sync();
    try t.expectEqual(@as(usize, 1), first.count);
    try t.expectEqual(@as(usize, 0), second.count);
    try t.expectEqual(@as(usize, 1), third.count);
    try server.emit("two", null);
    try client.sync();
    try t.expectEqual(@as(usize, 1), first.count);
    try t.expectEqual(@as(usize, 2), third.count);
    var body = first.held.?.iter();
    try t.expectEqualStrings("one", (try body.read(d.String)).bytes);
    survivor.deinit();
    try client.sync();
    // RemoveMatch must have balanced each of the three identical AddMatch rules.
    var detail: d.RemoteError = .{};
    defer detail.deinit();
    const rule = try match.ruleAlloc(t.allocator);
    defer t.allocator.free(rule);
    const remote = try client.bus();
    var remove = try remote.methodCall("RemoveMatch");
    defer remove.deinit();
    var writer = remove.writer();
    defer writer.deinit();
    try writer.write(d.String{ .bytes = rule });
    try writer.finish();
    try t.expectError(error.RemoteError, remote.call(&remove, .{ .remote_error = &detail }));
    try t.expectEqualStrings("org.freedesktop.DBus.Error.MatchRuleNotFound", detail.name().?);
}
test "match quoting reaches the broker and local filtering rejects other argument values" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var client: Harness = .{};
    try client.init(backend.io());
    defer client.deinit();
    var server: Harness = .{};
    try server.init(backend.io());
    defer server.deinit();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const literal = "it's\\literal,not=a-rule";
    var subscription = try client.conn.subscribe(t.allocator, .{ .arg0 = literal, .member = "Changed" }, d.signalHandler(&recorder, Recorder.signal), .{});
    defer subscription.deinit();
    try server.emit(literal, null);
    try server.emit("different", client.conn.uniqueName());
    try client.sync();
    try t.expectEqual(@as(usize, 1), recorder.count);
}
const OwnerRecorder = struct {
    count: usize = 0,
    watch: ?*d.NameWatch = null,
    fn changed(self: *OwnerRecorder, _: d.NameWatch.Change) void {
        self.count += 1;
        if (self.watch) |watch| watch.deinit();
    }
};
test "name tracking handles absence replacement old-owner unicast and disconnect" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var client: Harness = .{};
    try client.init(backend.io());
    defer client.deinit();
    var old: Harness = .{};
    try old.init(backend.io());
    defer old.deinit();
    var newer: Harness = .{};
    try newer.init(backend.io());
    defer newer.deinit();
    const service = "org.example.ClientLayer";
    var changes: OwnerRecorder = .{};
    var watch = try d.NameWatch.init(t.allocator, &client.conn, service, d.NameWatch.handler(&changes, OwnerRecorder.changed), .{});
    defer watch.deinit();
    try t.expectEqual(null, watch.owner());
    const initial = watch.generation();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var subscription = try client.conn.subscribe(t.allocator, .{ .sender = .{ .name = service }, .member = "Changed" }, d.signalHandler(&recorder, Recorder.signal), .{});
    defer subscription.deinit();
    try old.name(service, true);
    try client.sync();
    try t.expectEqualStrings(old.conn.uniqueName().?, watch.owner().?);
    try t.expect(watch.generation() > initial);
    try old.emit("old valid", null);
    try client.sync();
    try t.expectEqual(@as(usize, 1), recorder.count);
    const before = watch.generation();
    try old.name(service, false);
    try newer.name(service, true);
    try client.sync();
    try t.expectEqualStrings(newer.conn.uniqueName().?, watch.owner().?);
    try t.expect(watch.generation() >= before + 2);
    try old.emit("stale unicast", client.conn.uniqueName());
    try newer.emit("new valid", null);
    try client.sync();
    try t.expectEqual(@as(usize, 2), recorder.count);
    try t.expect(subscription.ownerGeneration().? >= 4);
    const connected = watch.generation();
    client.conn.close();
    _ = client.conn.dispatch(32);
    try t.expectEqual(null, watch.owner());
    try t.expect(watch.generation() > connected);
}
test "name watch can be destroyed from its own change callback" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var client: Harness = .{};
    try client.init(backend.io());
    defer client.deinit();
    var server: Harness = .{};
    try server.init(backend.io());
    defer server.deinit();
    var recorder: OwnerRecorder = .{};
    var watch = try d.NameWatch.init(t.allocator, &client.conn, "org.example.SelfDestruct", d.NameWatch.handler(&recorder, OwnerRecorder.changed), .{});
    defer watch.deinit();
    recorder.watch = &watch;
    try server.name("org.example.SelfDestruct", true);
    try client.sync();
    try t.expectEqual(null, watch.state);
    try t.expectEqual(@as(usize, 2), recorder.count); // Initial absence plus acquisition.
}
fn allocationScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    var client: Harness = .{};
    try client.init(io);
    defer client.deinit();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var subscription = try client.conn.subscribe(allocator, .{ .sender = .{ .name = "org.example.Allocations" }, .path_namespace = "/test" }, d.signalHandler(&recorder, Recorder.signal), .{});
    defer subscription.deinit();
}
test "subscription allocation failures roll back nested name watchers without leaking" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    try t.checkAllAllocationFailures(t.allocator, allocationScenario, .{backend.io()});
}
test "canceling AddMatch queues balanced removal and leaves the connection usable" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var client: Harness = .{};
    try client.init(backend.io());
    defer client.deinit();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    const match: d.SignalMatch = .{ .path = "/cancel", .member = "Changed" };
    client.waits.cancel_next_wait = true;
    try t.expectError(error.Canceled, client.conn.subscribe(t.allocator, match, d.signalHandler(&recorder, Recorder.signal), .{}));
    try client.sync();
    const rule = try match.ruleAlloc(t.allocator);
    defer t.allocator.free(rule);
    const remote = try client.bus();
    var request = try remote.methodCall("RemoveMatch");
    defer request.deinit();
    var writer = request.writer();
    defer writer.deinit();
    try writer.write(d.String{ .bytes = rule });
    try writer.finish();
    var detail: d.RemoteError = .{};
    defer detail.deinit();
    try t.expectError(error.RemoteError, remote.call(&request, .{ .remote_error = &detail }));
    try t.expectEqualStrings("org.freedesktop.DBus.Error.MatchRuleNotFound", detail.name().?);
    var subscription = try client.conn.subscribe(t.allocator, match, d.signalHandler(&recorder, Recorder.signal), .{});
    subscription.deinit();
    try client.sync();
}
const QueryRace = struct {
    old: *Harness,
    newer: *Harness,
    failure: ?anyerror = null,
    fired: bool = false,
    fn beforeWait(waits: *Driver.WaitIo) void {
        if (waits.wait_count != 2) return; // AddMatch confirmed; GetNameOwner is now pending.
        waits.before_wait = null;
        const self: *QueryRace = @ptrCast(@alignCast(waits.hook_context.?));
        self.fired = true;
        self.replace() catch |err| {
            self.failure = err;
        };
    }
    fn replace(self: *QueryRace) !void {
        try self.old.name("org.example.QueryRace", false);
        try self.newer.name("org.example.QueryRace", true);
    }
};
test "owner changes during initial GetNameOwner take precedence over initialization" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var client: Harness = .{};
    try client.init(backend.io());
    defer client.deinit();
    var old: Harness = .{};
    try old.init(backend.io());
    defer old.deinit();
    var newer: Harness = .{};
    try newer.init(backend.io());
    defer newer.deinit();
    try old.name("org.example.QueryRace", true);
    var race: QueryRace = .{ .old = &old, .newer = &newer };
    client.waits.before_wait = QueryRace.beforeWait;
    client.waits.hook_context = &race;
    var changes: OwnerRecorder = .{};
    var watch = try d.NameWatch.init(t.allocator, &client.conn, "org.example.QueryRace", d.NameWatch.handler(&changes, OwnerRecorder.changed), .{});
    defer watch.deinit();
    if (race.failure) |err| return err;
    try t.expect(race.fired);
    try t.expectEqualStrings(newer.conn.uniqueName().?, watch.owner().?);
    try t.expectEqual(@as(usize, 2), changes.count); // Loss and acquisition; no stale initialization callback.
}
test "broker rejected subscription rolls back and preserves remote detail" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var client: Harness = .{};
    try client.init(backend.io());
    defer client.deinit();
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var detail: d.RemoteError = .{};
    defer detail.deinit();
    const oversized: [2048:0]u8 = @splat('a');
    try t.expectError(error.RemoteError, client.conn.subscribe(t.allocator, .{ .arg0 = &oversized }, d.signalHandler(&recorder, Recorder.signal), .{ .remote_error = &detail }));
    try t.expectEqualStrings("org.freedesktop.DBus.Error.LimitsExceeded", detail.name().?);
    var subscription = try client.conn.subscribe(t.allocator, .{ .path = "/valid" }, d.signalHandler(&recorder, Recorder.signal), .{ .remote_error = &detail });
    defer subscription.deinit();
    try t.expectEqual(null, detail.reply);
    try client.sync();
}
const fd_api = struct {
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn read(fd: c_int, bytes: [*]u8, len: usize) isize;
    extern "c" fn write(fd: c_int, bytes: [*]const u8, len: usize) isize;
    extern "c" fn fcntl(fd: c_int, command: c_int, ...) c_int;
    extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
    extern "c" fn readdir(dir: *anyopaque) ?*anyopaque;
    extern "c" fn closedir(dir: *anyopaque) c_int;
};
fn openFdCount() !usize {
    const dir = fd_api.opendir("/proc/self/fd") orelse return error.OpenDirectoryFailed;
    defer _ = fd_api.closedir(dir);
    var count: usize = 0;
    while (fd_api.readdir(dir) != null) count += 1;
    return count;
}
test "Unix FD crosses private bus and survives both connections and source message" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var pipe: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), fd_api.pipe(&pipe));
    defer _ = fd_api.close(pipe[1]);
    defer if (pipe[0] >= 0) {
        _ = fd_api.close(pipe[0]);
    };
    var received: ?d.UnixFd = null;
    defer if (received) |fd| {
        _ = fd_api.close(fd.fd);
    };
    {
        var client: Harness = .{};
        try client.init(backend.io());
        defer client.deinit();
        var server: Harness = .{};
        try server.init(backend.io());
        defer server.deinit();
        try t.expect(d.c.dbus_connection_can_send_type(server.conn.raw(), d.c.DBUS_TYPE_UNIX_FD) != 0);
        var recorder: Recorder = .{};
        defer recorder.deinit();
        var subscription = try client.conn.subscribe(t.allocator, .{ .sender = .{ .unique = server.conn.uniqueName().? }, .member = "Descriptor" }, d.signalHandler(&recorder, Recorder.signal), .{});
        defer subscription.deinit();
        {
            var message = try d.Message.signal("/test", "org.example.Test", "Descriptor");
            defer message.deinit();
            var writer = message.writer();
            defer writer.deinit();
            try writer.write(d.UnixFd{ .fd = pipe[0] });
            try writer.finish();
            try t.expectEqual(@as(c_int, 0), fd_api.close(pipe[0]));
            pipe[0] = -1;
            _ = try server.conn.send(&message);
        }
        try server.sync();
        try client.sync();
        try t.expectEqual(@as(usize, 1), recorder.count);
        var body = recorder.held.?.iter();
        received = try body.read(d.UnixFd);
        try body.expectEnd();
        // Linux F_GETFD=1, FD_CLOEXEC=1: received descriptors must not leak across exec.
        const flags = fd_api.fcntl(received.?.fd, 1);
        try t.expect(flags >= 0 and flags & 1 != 0);
    }
    try t.expectEqual(@as(isize, 4), fd_api.write(pipe[1], "live", 4));
    var bytes: [4]u8 = undefined;
    try t.expectEqual(@as(isize, 4), fd_api.read(received.?.fd, &bytes, bytes.len));
    try t.expectEqualStrings("live", &bytes);
}
test "repeated connections name watches subscriptions and disconnects do not leak descriptors" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    // Warm native process-global initialization before measuring owned resources.
    {
        var warm: Harness = .{};
        try warm.init(backend.io());
        warm.deinit();
    }
    const before = try openFdCount();
    for (0..32) |index| {
        var client: Harness = .{};
        try client.init(backend.io());
        defer client.deinit();
        var recorder: Recorder = .{};
        defer recorder.deinit();
        var subscription = try client.conn.subscribe(t.allocator, .{ .sender = .{ .name = "org.example.RepeatedLifecycle" } }, d.signalHandler(&recorder, Recorder.signal), .{});
        defer subscription.deinit();
        try client.sync();
        if (index % 2 == 0) {
            client.conn.close();
            _ = client.conn.dispatch(32);
        }
        subscription.deinit();
        if (client.conn.isConnected()) try client.sync();
    }
    try t.expectEqual(before, try openFdCount());
}
const Burst = struct {
    count: u32 = 0,
    invalid: bool = false,
    fn signal(self: *Burst, message: *const d.Message) void {
        self.accept(message) catch {
            self.invalid = true;
        };
    }
    fn accept(self: *Burst, message: *const d.Message) !void {
        var body = message.iter();
        const sequence = try body.read(u32);
        const payload = try body.readBytes();
        try body.expectEnd();
        if (sequence != self.count or payload.len != 1024 or payload[0] != 42 or payload[1023] != 42) self.invalid = true;
        self.count += 1;
    }
};
test "signal bursts cross dispatch budgets without loss duplication or order changes" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var client: Harness = .{};
    try client.init(backend.io());
    defer client.deinit();
    var server: Harness = .{};
    try server.init(backend.io());
    defer server.deinit();
    var burst: Burst = .{};
    var subscription = try client.conn.subscribe(t.allocator, .{ .sender = .{ .unique = server.conn.uniqueName().? }, .member = "Burst" }, d.signalHandler(&burst, Burst.signal), .{});
    defer subscription.deinit();
    const payload: [1024]u8 = @splat(42);
    for (0..1024) |index| {
        var message = try d.Message.signal("/test", "org.example.Test", "Burst");
        defer message.deinit();
        var writer = message.writer();
        defer writer.deinit();
        try writer.write(@as(u32, @intCast(index)));
        try writer.writeBytes(&payload);
        try writer.finish();
        _ = try server.conn.send(&message);
        if (index % 64 == 63) {
            try server.sync();
            try client.sync();
        }
    }
    try t.expect(!burst.invalid);
    try t.expectEqual(@as(u32, 1024), burst.count);
    subscription.deinit();
    try client.sync();
    var late = try d.Message.signal("/test", "org.example.Test", "Burst");
    defer late.deinit();
    try t.expect(d.c.dbus_message_set_destination(late.raw(), client.conn.uniqueName().?.ptr) != 0);
    _ = try server.conn.send(&late);
    try server.sync();
    try client.sync();
    try t.expect(!burst.invalid);
    try t.expectEqual(@as(u32, 1024), burst.count);
}
