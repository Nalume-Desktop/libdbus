//! Run ONLY under the build's private dbus-run-session test runner.
const std = @import("std");
const t = std.testing;
const d = @import("libdbus");
const PollDriver = @import("test_support/PollDriver.zig");
const WaitIo = @import("test_support/WaitIo.zig");
test {
    _ = @import("client_integration_tests.zig");
    _ = @import("server_integration_tests.zig");
}

fn connect(io: std.Io) !d.Connection {
    var detail = try d.Error.init();
    defer detail.deinit();
    return d.Connection.connect(io, .session, &detail);
}
fn busRequest(member: [:0]const u8) !d.Message {
    return d.Message.methodCall(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = member });
}
fn ignoredRequest(server: *d.Connection) !d.Message {
    return d.Message.methodCall(.{ .destination = server.uniqueName().?, .path = "/test", .interface = "org.example.Test", .member = "NeverReply" });
}

test "call supports direct and Io async use, preserving remote errors" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var driver: PollDriver = undefined;
    var waits: WaitIo = .{ .driver = &driver };
    const io = waits.io();
    var conn = try connect(io);
    defer conn.deinit();
    try t.expect(conn.isConnected());
    try t.expect(conn.uniqueName() != null);
    driver = .{ .connection = &conn, .clock_io = backend.io() };
    try driver.attach();
    defer driver.detach();
    var request = try busRequest("GetId");
    defer request.deinit();
    var reply = try conn.call(&request, .{ .timeout = .{ .milliseconds = 2000 } });
    defer reply.deinit();
    try t.expectEqual(d.Message.Kind.method_return, reply.kind());
    var body = reply.iter();
    try t.expect((try body.read(d.String)).bytes.len != 0);
    try body.expectEnd();
    try t.expectError(error.AlreadySent, conn.send(&request));
    for (0..32) |_| {
        var next = try busRequest("ListNames");
        defer next.deinit();
        var future = io.async(d.Connection.call, .{ &conn, &next, d.Connection.CallOptions{ .timeout = .{ .milliseconds = 2000 } } });
        var response = try future.await(io);
        defer response.deinit();
        try t.expectEqualStrings("as", response.signature().bytes);
    }
    var invalid = try busRequest("NoSuchMethod");
    defer invalid.deinit();
    var remote = try conn.call(&invalid, .{});
    defer remote.deinit();
    try t.expectEqual(d.Message.Kind.error_reply, remote.kind());
    try t.expectEqualStrings("org.freedesktop.DBus.Error.UnknownMethod", remote.errorName().?);
    try t.expect(remote.errorText() != null);
    try t.expect(waits.wait_count > 0);
    try t.expect(driver.watch_handles > 0);
}

// Observe a real Threaded Io wait. The owner pauses the reactor while canceling.
// For disconnect, defer waiter cleanup until the owner finishes driving the signal.
const WaitTask = struct {
    pending: ?*d.PendingCall = null,
    base: std.Io = undefined,
    started: std.Io.Event = .unset,
    notified: std.Io.Event = .unset,
    allow_cleanup: std.Io.Event = .is_set,
    const vtable: std.Io.VTable = blk: {
        var value = std.Io.failing.vtable.*;
        value.futexWait = wait;
        value.futexWake = wake;
        break :blk value;
    };
    fn runCall(self: *WaitTask, conn: *d.Connection, request: *const d.Message, io: std.Io) !d.Message {
        self.base = io;
        defer self.started.set(io);
        return conn.call(request, .{ .timeout = .{ .milliseconds = 1000 } });
    }
    fn run(self: *WaitTask, io: std.Io) !d.Message {
        self.base = io;
        defer self.started.set(io); // Also signal if setup fails before waiting.
        return self.pending.?.wait(.{ .userdata = self, .vtable = &vtable });
    }
    fn wait(data: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self: *WaitTask = @ptrCast(@alignCast(data.?));
        self.started.set(self.base);
        while (@atomicLoad(u32, ptr, .acquire) == expected) {
            self.base.vtable.futexWait(self.base.userdata, ptr, expected, timeout) catch |err| {
                self.allow_cleanup.waitUncancelable(self.base);
                return err;
            };
        }
        self.allow_cleanup.waitUncancelable(self.base);
    }
    fn wake(data: ?*anyopaque, ptr: *const u32, count: u32) void {
        const self: *WaitTask = @ptrCast(@alignCast(data.?));
        self.base.vtable.futexWake(self.base.userdata, ptr, count);
        self.notified.set(self.base);
    }
};

fn driveWaiter(driver: *PollDriver, task: *WaitTask) !void {
    const deadline = driver.now() + 3000;
    while (!task.notified.isSet()) {
        const remaining = deadline - driver.now();
        if (remaining <= 0) return error.TestDeadlineExceeded;
        try driver.step(@intCast(remaining));
    }
}

test "Io cancellation cleans up without breaking subsequent calls" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var driver: PollDriver = undefined;
    var waits: WaitIo = .{ .driver = &driver };
    var conn = try connect(waits.io());
    defer conn.deinit();
    var server = try connect(io); // Deliberately never dispatches the incoming method.
    defer server.deinit();
    driver = .{ .connection = &conn, .clock_io = io };
    try driver.attach();
    defer driver.detach();
    for (0..16) |_| {
        var request = try ignoredRequest(&server);
        defer request.deinit();
        var pending = try conn.startCall(&request, .{ .timeout = .{ .milliseconds = 1000 } });
        defer pending.deinit();
        var task: WaitTask = .{ .pending = &pending };
        var future = try io.concurrent(WaitTask.run, .{ &task, io });
        // No fallible exit before cancel joins the task and releases its borrowed inputs.
        task.started.waitUncancelable(io);
        const result = future.cancel(io);
        if (result) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.ExpectedCancellation;
        } else |err| try t.expectEqual(error.Canceled, err);
        for (driver.timers) |timer| try t.expectEqual(null, timer);
    }
    var request = try busRequest("GetId");
    defer request.deinit();
    var reply = try conn.call(&request, .{});
    defer reply.deinit();
    try t.expectEqual(d.Message.Kind.method_return, reply.kind());
}

test "completed-before-wait, nonblocking take and disconnected pending calls" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var conn = try connect(io);
    defer conn.deinit();
    var driver: PollDriver = .{ .connection = &conn, .clock_io = io };
    try driver.attach();
    defer driver.detach();
    var request = try busRequest("GetId");
    defer request.deinit();
    var pending = try conn.startCall(&request, .{ .timeout = .{ .milliseconds = 1000 } });
    defer pending.deinit();
    try driver.runUntil(&pending);
    var reply = try pending.wait(io); // No completion callback was installed when reply arrived.
    defer reply.deinit();
    try t.expectEqual(d.Message.Kind.method_return, reply.kind());
    var next = try busRequest("ListNames");
    defer next.deinit();
    var polling = try conn.startCall(&next, .{ .timeout = .{ .milliseconds = 1000 } });
    defer polling.deinit();
    try driver.runUntil(&polling);
    var polled = (try polling.takeReply()).?;
    defer polled.deinit();
    try t.expectEqualStrings("as", polled.signature().bytes);
    var server = try connect(io);
    defer server.deinit();
    var slow = try ignoredRequest(&server);
    defer slow.deinit();
    var disconnected = try conn.startCall(&slow, .{ .timeout = .infinite });
    defer disconnected.deinit();
    conn.close();
    for (0..100) |_| {
        if (disconnected.isCompleted()) break;
        _ = conn.dispatch(32);
    }
    try t.expect(disconnected.isCompleted());
    try t.expectError(error.Disconnected, disconnected.wait(io));
    var fresh = try busRequest("GetId");
    defer fresh.deinit();
    try t.expectError(error.Disconnected, conn.startCall(&fresh, .{}));
}

test "external watch and timer reactor drives requests, rolls back failed install, and detaches" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var conn = try connect(backend.io());
    defer conn.deinit();
    var reactor: PollDriver = .{ .connection = &conn, .clock_io = backend.io(), .reject_watches = true };
    try t.expectError(error.OutOfMemory, reactor.attach());
    reactor.reject_watches = false;
    var request = try busRequest("GetId");
    defer request.deinit();
    var pending = try conn.startCall(&request, .{ .timeout = .{ .milliseconds = 1000 } });
    defer pending.deinit();
    reactor.reject_timers = true;
    try t.expectError(error.OutOfMemory, reactor.attach());
    for (reactor.watches) |w| try t.expectEqual(null, w);
    reactor.reject_timers = false;
    try reactor.attach();
    defer reactor.detach();
    try t.expectError(error.DriverAlreadyAttached, reactor.attach());
    try reactor.runUntil(&pending);
    var reply = (try pending.takeReply()).?;
    defer reply.deinit();
    try t.expectEqual(d.Message.Kind.method_return, reply.kind());
    var server = try connect(backend.io());
    defer server.deinit();
    var slow = try ignoredRequest(&server);
    defer slow.deinit();
    var timed = try conn.startCall(&slow, .{ .timeout = .{ .milliseconds = 30 } });
    defer timed.deinit();
    try reactor.runUntil(&timed);
    var timeout = (try timed.takeReply()).?;
    defer timeout.deinit();
    try t.expectEqualStrings("org.freedesktop.DBus.Error.NoReply", timeout.errorName().?);
    var signal = try d.Message.signal("/test", "org.example.Test", "Changed");
    defer signal.deinit();
    try t.expect(try conn.send(&signal) != 0);
    _ = conn.hasOutgoing();
    try t.expect(reactor.timeout_handles > 0);
    reactor.detach();
    for (reactor.watches) |w| try t.expectEqual(null, w);
    for (reactor.timers) |timer| try t.expectEqual(null, timer);
}

test "disconnect wakes an infinite concurrent waiter" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var server = try connect(io);
    defer server.deinit();
    for (0..16) |_| {
        var conn = try connect(io);
        defer conn.deinit();
        var driver: PollDriver = .{ .connection = &conn, .clock_io = io };
        try driver.attach();
        defer driver.detach();
        var request = try ignoredRequest(&server);
        defer request.deinit();
        var pending = try conn.startCall(&request, .{ .timeout = .infinite });
        defer pending.deinit();
        var task: WaitTask = .{ .pending = &pending, .allow_cleanup = .unset };
        var future = try io.concurrent(WaitTask.run, .{ &task, io });
        // Error exits must unblock and join the waiter before destroying its inputs.
        var joined = false;
        defer if (!joined) {
            task.allow_cleanup.set(io);
            if (future.cancel(io)) |value| {
                var unused = value;
                unused.deinit();
            } else |_| {}
        };
        task.started.waitUncancelable(io);
        conn.close();
        try driveWaiter(&driver, &task);
        task.allow_cleanup.set(io);
        const result = future.await(io);
        joined = true;
        if (result) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.ExpectedDisconnect;
        } else |err| try t.expectEqual(error.Disconnected, err);
    }
}

test "call timeout uses native timeout hooks and connection remains usable" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var driver: PollDriver = undefined;
    var waits: WaitIo = .{ .driver = &driver };
    var conn = try connect(waits.io());
    defer conn.deinit();
    var server = try connect(backend.io());
    defer server.deinit();
    driver = .{ .connection = &conn, .clock_io = backend.io() };
    try driver.attach();
    defer driver.detach();
    var slow = try ignoredRequest(&server);
    defer slow.deinit();
    var timed = try conn.call(&slow, .{ .timeout = .{ .milliseconds = 30 } });
    defer timed.deinit();
    try t.expectEqualStrings("org.freedesktop.DBus.Error.NoReply", timed.errorName().?);
    try t.expect(driver.timeout_handles > 0);
    for (driver.timers) |timer| try t.expectEqual(null, timer);
    var request = try busRequest("GetId");
    defer request.deinit();
    var reply = try conn.call(&request, .{});
    defer reply.deinit();
    try t.expectEqual(d.Message.Kind.method_return, reply.kind());
}

test "poll driver wakes a real concurrent Io waiter with a reply" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var conn = try connect(io);
    defer conn.deinit();
    var driver: PollDriver = .{ .connection = &conn, .clock_io = io };
    try driver.attach();
    defer driver.detach();
    for (0..16) |_| {
        var request = try busRequest("GetId");
        defer request.deinit();
        var pending = try conn.startCall(&request, .{ .timeout = .{ .milliseconds = 1000 } });
        defer pending.deinit();
        var task: WaitTask = .{ .pending = &pending, .allow_cleanup = .unset };
        var future = try io.concurrent(WaitTask.run, .{ &task, io });
        var joined = false;
        defer if (!joined) {
            task.allow_cleanup.set(io);
            if (future.cancel(io)) |value| {
                var unused = value;
                unused.deinit();
            } else |_| {}
        };
        task.started.waitUncancelable(io);
        try driveWaiter(&driver, &task);
        task.allow_cleanup.set(io);
        const result = future.await(io);
        joined = true;
        var reply = try result;
        defer reply.deinit();
        try t.expectEqual(d.Message.Kind.method_return, reply.kind());
        for (driver.timers) |timer| try t.expectEqual(null, timer);
    }
}

test "connection setup retains native failure detail and rejects invalid requests" {
    var detail = try d.Error.init();
    defer detail.deinit();
    try t.expectError(error.InvalidAddress, d.Connection.open(t.io, "unix:path=/a\x00b", false, &detail));
    try t.expect(!detail.isSet());
    try t.expectError(error.ConnectFailed, d.Connection.open(t.io, "not-a-transport:", false, &detail));
    try t.expect(detail.isSet());
    var conn = try connect(t.io);
    defer conn.deinit();
    var signal = try d.Message.signal("/test", "org.example.Test", "Changed");
    defer signal.deinit();
    try t.expectError(error.InvalidRequest, conn.startCall(&signal, .{}));
    var no_reply = try d.Message.methodCall(.{ .path = "/test", .member = "Get", .no_reply = true });
    defer no_reply.deinit();
    try t.expectError(error.InvalidRequest, conn.startCall(&no_reply, .{}));
    var request = try busRequest("GetId");
    defer request.deinit();
    try t.expectError(error.InvalidTimeout, conn.startCall(&request, .{ .timeout = .{ .milliseconds = std.math.maxInt(u31) } }));
    try t.expectEqual(@as(u32, 0), request.serial());
    var canceled = try conn.startCall(&request, .{});
    canceled.cancel();
    canceled.deinit();
    conn.deinit();
}

test "bound Io call cancels and then receives a reply on the same connection" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var task: WaitTask = .{};
    var conn = try connect(.{ .userdata = &task, .vtable = &WaitTask.vtable });
    defer conn.deinit();
    var server = try connect(io);
    defer server.deinit();
    var driver: PollDriver = .{ .connection = &conn, .clock_io = io };
    try driver.attach();
    defer driver.detach();

    for (0..2) |attempt| {
        // Reinitialize only after the previous waiter has joined, keeping its address stable.
        task = .{ .allow_cleanup = if (attempt == 0) .is_set else .unset };
        var request = if (attempt == 0) try ignoredRequest(&server) else try busRequest("GetId");
        defer request.deinit();
        var future = try io.concurrent(WaitTask.runCall, .{ &task, &conn, &request, io });
        var joined = false;
        defer if (!joined) {
            task.allow_cleanup.set(io);
            if (future.cancel(io)) |value| {
                var unused = value;
                unused.deinit();
            } else |_| {}
        };
        task.started.waitUncancelable(io);
        if (attempt == 0) {
            const result = future.cancel(io);
            joined = true;
            if (result) |value| {
                var unexpected = value;
                unexpected.deinit();
                return error.ExpectedCancellation;
            } else |err| try t.expectEqual(error.Canceled, err);
        } else {
            try driveWaiter(&driver, &task);
            task.allow_cleanup.set(io);
            const result = future.await(io);
            joined = true;
            var reply = try result;
            defer reply.deinit();
            try t.expectEqual(d.Message.Kind.method_return, reply.kind());
            try t.expectEqualStrings("s", reply.signature().bytes);
        }
        for (driver.timers) |timer| try t.expectEqual(null, timer);
    }
}
