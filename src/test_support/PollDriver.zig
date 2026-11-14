//! Test-only, bounded POSIX poll driver. Not exported by the library.
//! Keep this value at a stable address until detach. Step and hooks must be
//! serialized: no connection send/close/cancel on another thread while stepping.
//! Tests may hand ownership to a waiter for cancellation while this driver is idle,
//! then join that waiter before resuming. This is not a multithreaded reactor.
const std = @import("std");
const d = @import("libdbus");
const c = d.c;
const Self = @This();
pub const WaitIo = @import("WaitIo.zig");

connection: *d.Connection,
clock_io: std.Io,
watches: [16]?*c.DBusWatch = @splat(null),
timers: [64]?*c.DBusTimeout = @splat(null),
watch_generation: [16]u64 = @splat(0),
timer_generation: [64]u64 = @splat(0),
due: [64]?i64 = @splat(null),
reject_watches: bool = false,
reject_timers: bool = false,
wake_requested: bool = false,
attached: bool = false,
stepping: bool = false,
watch_handles: usize = 0,
timeout_handles: usize = 0,

pub fn attach(self: *Self) !void {
    try self.connection.attachDriver(self.hooks());
    self.attached = true;
}
pub fn detach(self: *Self) void {
    std.debug.assert(!self.stepping);
    if (self.attached) self.connection.detachDriver();
    self.attached = false;
    for (self.watches) |watch| std.debug.assert(watch == null);
    for (self.timers) |timer| std.debug.assert(timer == null);
}
pub fn now(self: *Self) i64 {
    return std.Io.Clock.awake.now(self.clock_io).toMilliseconds();
}
fn get(data: ?*anyopaque) *Self {
    return @ptrCast(@alignCast(data.?));
}
fn addWatch(watch: ?*c.DBusWatch, data: ?*anyopaque) callconv(.c) c.dbus_bool_t {
    const self = get(data);
    if (self.reject_watches) return 0;
    for (&self.watches, 0..) |*slot, i| if (slot.* == null) {
        slot.* = watch;
        self.watch_generation[i] += 1;
        self.wake_requested = true;
        return 1;
    };
    return 0;
}
fn removeWatch(watch: ?*c.DBusWatch, data: ?*anyopaque) callconv(.c) void {
    const self = get(data);
    for (&self.watches, 0..) |*slot, i| if (slot.* == watch) {
        slot.* = null;
        self.watch_generation[i] += 1;
    };
    self.wake_requested = true;
}
fn toggleWatch(watch: ?*c.DBusWatch, data: ?*anyopaque) callconv(.c) void {
    const self = get(data);
    for (self.watches, 0..) |slot, i| if (slot == watch) {
        self.watch_generation[i] += 1;
    };
    self.wake_requested = true;
}
fn schedule(self: *Self, i: usize, raw: *c.DBusTimeout) void {
    const timer: d.Driver.Timeout = .{ .raw = raw };
    self.due[i] = if (timer.enabled()) self.now() + timer.intervalMs() else null;
}
fn addTimer(timer: ?*c.DBusTimeout, data: ?*anyopaque) callconv(.c) c.dbus_bool_t {
    const self = get(data);
    if (self.reject_timers) return 0;
    for (&self.timers, 0..) |*slot, i| if (slot.* == null) {
        slot.* = timer;
        self.timer_generation[i] += 1;
        self.schedule(i, timer.?);
        self.wake_requested = true;
        return 1;
    };
    return 0;
}
fn removeTimer(timer: ?*c.DBusTimeout, data: ?*anyopaque) callconv(.c) void {
    const self = get(data);
    for (&self.timers, 0..) |*slot, i| if (slot.* == timer) {
        slot.* = null;
        self.due[i] = null;
        self.timer_generation[i] += 1;
    };
    self.wake_requested = true;
}
fn toggleTimer(timer: ?*c.DBusTimeout, data: ?*anyopaque) callconv(.c) void {
    const self = get(data);
    for (self.timers, 0..) |slot, i| if (slot == timer) {
        self.timer_generation[i] += 1;
        self.schedule(i, timer.?);
    };
    self.wake_requested = true;
}
fn wake(data: ?*anyopaque) callconv(.c) void {
    get(data).wake_requested = true;
}
fn status(_: ?*c.DBusConnection, _: c.DBusDispatchStatus, data: ?*anyopaque) callconv(.c) void {
    wake(data);
}
pub fn hooks(self: *Self) d.Driver.Hooks {
    return .{ .context = self, .add_watch = addWatch, .remove_watch = removeWatch, .toggle_watch = toggleWatch, .add_timeout = addTimer, .remove_timeout = removeTimer, .toggle_timeout = toggleTimer, .wakeup = wake, .dispatch_status = status };
}
fn dispatch(self: *Self) !void {
    switch (self.connection.dispatch(32)) {
        .complete => {},
        .data_remains => self.wake_requested = true,
        .need_memory => return error.OutOfMemory,
    }
}

/// One bounded turn. Timers use absolute monotonic deadlines; EINTR returns to the
/// caller so the next turn recomputes remaining time. No periodic 10ms busy polling.
pub fn step(self: *Self, max_wait_ms: u31) !void {
    std.debug.assert(self.attached);
    if (self.stepping) return error.ReentrantDriver;
    self.stepping = true;
    defer self.stepping = false;
    if (self.connection.dispatchStatus() == .data_remains) {
        try self.dispatch();
        return; // A waiter may now be ready; do not poll before returning to it.
    }
    if (self.connection.dispatchStatus() == .need_memory) return error.OutOfMemory;
    const snapshot = self.watches;
    const generations = self.watch_generation;
    var fds: [16]std.posix.pollfd = undefined;
    for (snapshot, 0..) |item, i| {
        fds[i] = .{ .fd = -1, .events = 0, .revents = 0 };
        if (item) |raw| {
            const watch: d.Driver.Watch = .{ .raw = raw };
            if (watch.enabled()) {
                fds[i].fd = watch.fd();
                const flags = watch.flags();
                if (flags & c.DBUS_WATCH_READABLE != 0) fds[i].events |= std.posix.POLL.IN;
                if (flags & c.DBUS_WATCH_WRITABLE != 0) fds[i].events |= std.posix.POLL.OUT;
            }
        }
    }
    const current = self.now();
    var wait_ms: i64 = max_wait_ms;
    if (self.wake_requested) wait_ms = 0;
    self.wake_requested = false;
    for (self.due) |deadline| if (deadline) |end| {
        wait_ms = @min(wait_ms, @max(0, end - current));
    };
    switch (std.posix.errno(std.c.poll(&fds, fds.len, @intCast(wait_ms)))) {
        .SUCCESS => {},
        .INTR => return,
        else => return error.PollFailed,
    }
    for (snapshot, 0..) |item, i| if (item) |raw| {
        // Removal, replacement at the same address, or a toggle invalidates old readiness.
        if (self.watch_generation[i] != generations[i] or fds[i].revents == 0) continue;
        const events = fds[i].revents;
        if (events & std.posix.POLL.NVAL != 0) return error.InvalidPollFd;
        var flags: c_uint = 0;
        if (events & std.posix.POLL.IN != 0) flags |= c.DBUS_WATCH_READABLE;
        if (events & std.posix.POLL.OUT != 0) flags |= c.DBUS_WATCH_WRITABLE;
        if (events & std.posix.POLL.ERR != 0) flags |= c.DBUS_WATCH_ERROR;
        if (events & std.posix.POLL.HUP != 0) flags |= c.DBUS_WATCH_HANGUP;
        try (d.Driver.Watch{ .raw = raw }).handle(flags);
        self.watch_handles += 1;
    };
    const timers = self.timers;
    const timer_generations = self.timer_generation;
    for (timers, 0..) |item, i| if (item) |raw| {
        if (self.timer_generation[i] != timer_generations[i]) continue;
        if (self.due[i]) |deadline| if (self.now() >= deadline) {
            self.schedule(i, raw); // handle can synchronously remove/toggle this timer.
            try (d.Driver.Timeout{ .raw = raw }).handle();
            self.timeout_handles += 1;
        };
    };
    try self.dispatch();
}
pub fn runUntil(self: *Self, pending: *d.PendingCall) !void {
    const deadline = self.now() + 3000;
    while (!pending.isCompleted()) {
        const remaining = deadline - self.now();
        if (remaining <= 0) return error.TestDeadlineExceeded;
        try self.step(@intCast(remaining));
    }
}
