//! Owns a reply reference. All getters return values borrowing that reply (FDs duplicate).
const std = @import("std");
const Message = @import("Message.zig");
const PropertyMap = @import("PropertyMap.zig");
const Self = @This();
message: Message,
map: PropertyMap,
/// Retain a message containing exactly a{sv}; also useful for custom protocol codecs.
pub fn init(message: *const Message) !Self {
    if (!std.mem.eql(u8, message.signature().bytes, "a{sv}")) return error.InvalidReply;
    var body = message.iter();
    return .{ .message = message.ref(), .map = .{ .value_ref = try body.value() } };
}
pub fn deinit(self: *Self) void {
    self.message.deinit();
}
pub fn view(self: *const Self) PropertyMap {
    return self.map;
}
pub fn get(self: *const Self, comptime T: type, name: []const u8) !T {
    return self.map.get(T, name);
}
pub fn getOptional(self: *const Self, comptime T: type, name: []const u8) !?T {
    return self.map.getOptional(T, name);
}
pub fn getBytes(self: *const Self, name: []const u8) ![]const u8 {
    return self.map.getBytes(name);
}
pub fn value(self: *const Self, name: []const u8) !@import("ValueRef.zig") {
    return self.map.value(name);
}
pub fn iterator(self: *const Self) PropertyMap.Iterator {
    return self.map.iterator();
}
