//! Minimal test Io: cooperative Event waits run the external PollDriver.
//! async executes inline (std.Io.noAsync); concurrent is unsupported. This is not
//! a general Io backend, nor a background driver. All native work stays serialized.
const std = @import("std");
const PollDriver = @import("PollDriver.zig");
const Self = @This();
driver: *PollDriver,
wait_count: usize = 0,
/// Inject cancellation at the next event wait, before advancing the driver.
cancel_next_wait: bool = false,
/// Deterministic race injection for integration tests, before driver progress.
before_wait: ?*const fn (*Self) void = null,
hook_context: ?*anyopaque = null,
const vtable: std.Io.VTable = blk: {
    var value = std.Io.failing.vtable.*;
    value.futexWait = wait;
    value.futexWake = wake;
    break :blk value;
};
pub fn io(self: *Self) std.Io {
    return .{ .userdata = self, .vtable = &vtable };
}
fn wait(data: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    std.debug.assert(timeout == .none); // PendingCall uses Event.wait, with no Io deadline.
    const self: *Self = @ptrCast(@alignCast(data.?));
    self.wait_count += 1;
    if (self.before_wait) |hook| hook(self);
    if (self.cancel_next_wait) {
        self.cancel_next_wait = false;
        return error.Canceled;
    }
    const deadline = self.driver.now() + 3000;
    while (@atomicLoad(u32, ptr, .acquire) == expected) {
        const remaining = deadline - self.driver.now();
        if (remaining <= 0) @panic("test driver: pending wait exceeded 3 seconds");
        self.driver.step(@intCast(remaining)) catch |err| std.debug.panic("test driver: {t}", .{err});
    }
}
fn wake(_: ?*anyopaque, _: *const u32, _: u32) void {
    // Same-thread dispatch already changed the Event; wait checks it after step.
}
