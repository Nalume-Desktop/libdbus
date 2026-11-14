//! Owns the reply to Properties.Get. value() unwraps only the protocol's outer variant.
const std = @import("std");
const Message = @import("Message.zig");
const ValueRef = @import("ValueRef.zig");
const Self = @This();
message: Message,
borrowed: ValueRef,
pub fn init(message: *const Message) !Self {
    if (!std.mem.eql(u8, message.signature().bytes, "v")) return error.InvalidReply;
    const borrowed = try (try message.iter().value()).unwrapVariant();
    return .{ .message = message.ref(), .borrowed = borrowed };
}
pub fn value(self: *const Self) ValueRef {
    return self.borrowed;
}
pub fn deinit(self: *Self) void {
    self.message.deinit();
}
