//! Borrowed standard signal body. Retain the source Message to keep this view.
const std = @import("std");
const Message = @import("Message.zig");
const Iter = @import("Iter.zig");
const types = @import("types.zig");
const PropertyMap = @import("PropertyMap.zig");
const Self = @This();
interface: [:0]const u8,
changed: PropertyMap,
invalidated: StringList,
pub const StringList = struct {
    cursor: Iter,
    pub fn next(self: *StringList) !?[:0]const u8 {
        if (self.cursor.peek() == null) return null;
        return (try self.cursor.read(types.String)).bytes;
    }
};
pub fn checkSignal(message: *const Message, interface: []const u8, member: []const u8, signature: []const u8) !void {
    if (message.kind() != .signal or !std.mem.eql(u8, message.interface() orelse "", interface) or !std.mem.eql(u8, message.member() orelse "", member) or !std.mem.eql(u8, message.signature().bytes, signature)) return error.InvalidSignal;
}
pub fn init(message: *const Message) !Self {
    try checkSignal(message, "org.freedesktop.DBus.Properties", "PropertiesChanged", "sa{sv}as");
    var body = message.iter();
    const interface = (try body.read(types.String)).bytes;
    const changed = try PropertyMap.init((try body.nextValue()).?);
    const invalidated = try body.enter(.array);
    try body.expectEnd();
    return .{ .interface = interface, .changed = changed, .invalidated = .{ .cursor = invalidated } };
}
