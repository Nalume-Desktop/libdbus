//! Optional owned detail for convenience APIs returning error.RemoteError.
const Message = @import("Message.zig");
const Self = @This();
reply: ?Message = null,
pub fn deinit(self: *Self) void {
    if (self.reply) |*message| message.deinit();
    self.reply = null;
}
pub fn capture(self: *Self, message: *const Message) void {
    self.deinit();
    self.reply = message.ref();
}
pub fn name(self: *const Self) ?[:0]const u8 {
    return if (self.reply) |message| message.errorName() else null;
}
pub fn text(self: *const Self) ?[:0]const u8 {
    return if (self.reply) |message| message.errorText() else null;
}
