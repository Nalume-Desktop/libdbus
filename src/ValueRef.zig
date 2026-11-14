//! One immutable borrowed value. All copies borrow the same live, unchanged message.
const std = @import("std");
const c = @import("dbus_c");
const Iter = @import("Iter.zig");
const types = @import("types.zig");
const Message = @import("Message.zig");
const Self = @This();
cursor: Iter,
pub fn kind(self: Self) types.Type {
    return self.cursor.peek().?;
}
pub fn as(self: Self, comptime T: type) Iter.Error!T {
    var copy = self.cursor;
    return copy.read(T);
}
pub fn bytes(self: Self) Iter.Error![]const u8 {
    var copy = self.cursor;
    return copy.readBytes();
}
pub fn enter(self: Self, container: types.ContainerType) Iter.Error!Iter {
    var copy = self.cursor;
    return copy.enter(container);
}
/// Unwrap exactly one variant, preserving any nested variant.
pub fn unwrapVariant(self: Self) Iter.Error!Self {
    var child = try self.enter(.variant);
    const result = try child.value();
    try child.skip();
    try child.expectEnd();
    return result;
}
pub fn signatureAlloc(self: Self, allocator: std.mem.Allocator) ![:0]u8 {
    return self.cursor.signatureAlloc(allocator);
}
/// libdbus allocates this signature; no persistent allocation is retained.
pub fn hasSignature(self: Self, signature: []const u8) error{OutOfMemory}!bool {
    var copy = self.cursor.raw;
    const actual = c.dbus_message_iter_get_signature(&copy);
    if (actual == null) return error.OutOfMemory;
    defer c.dbus_free(actual);
    return std.mem.eql(u8, std.mem.span(actual), signature);
}
/// Keeps the entire backing message alive, without deep-copying the value.
pub fn retain(self: Self) RetainedValue {
    return .{ .message = Message.fromBorrowed(self.cursor.message), .borrowed = self };
}
pub const RetainedValue = struct {
    message: Message,
    borrowed: Self,
    pub fn view(self: *const RetainedValue) Self {
        std.debug.assert(self.message.pointer != null);
        return self.borrowed;
    }
    pub fn deinit(self: *RetainedValue) void {
        self.message.deinit();
    }
};
