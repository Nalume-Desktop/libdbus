//! Structured bus match with matching local checks. All strings are borrowed here.
const std = @import("std");
const c = @import("dbus_c");
const Message = @import("Message.zig");
const types = @import("types.zig");
const Self = @This();
pub const Sender = union(enum) { unique: [:0]const u8, name: [:0]const u8 };
sender: ?Sender = null,
path: ?[:0]const u8 = null,
path_namespace: ?[:0]const u8 = null,
interface: ?[:0]const u8 = null,
member: ?[:0]const u8 = null,
arg0: ?[:0]const u8 = null,
fn noNul(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, 0) == null;
}
pub fn validate(self: Self) !void {
    if (self.path != null and self.path_namespace != null) return error.ConflictingPaths;
    for ([_]?[:0]const u8{ self.path, self.path_namespace }) |path| if (path) |s| {
        if (!noNul(s) or c.dbus_validate_path(s.ptr, null) == 0) return error.InvalidPath;
    };
    if (self.interface) |s| if (!noNul(s) or c.dbus_validate_interface(s.ptr, null) == 0) return error.InvalidInterface;
    if (self.member) |s| if (!noNul(s) or c.dbus_validate_member(s.ptr, null) == 0) return error.InvalidMember;
    if (self.arg0) |s| if (!noNul(s) or c.dbus_validate_utf8(s.ptr, null) == 0) return error.InvalidText;
    if (self.sender) |sender| {
        const s = switch (sender) {
            .unique, .name => |s| s,
        };
        if (!noNul(s) or c.dbus_validate_bus_name(s.ptr, null) == 0) return error.InvalidDestination;
        switch (sender) {
            .unique => if (s[0] != ':' and !std.mem.eql(u8, s, "org.freedesktop.DBus")) return error.InvalidUniqueName,
            .name => if (s[0] == ':') return error.InvalidWellKnownName,
        }
    }
}
fn field(out: *std.Io.Writer, name: []const u8, text: []const u8) !void {
    try out.print(",{s}='", .{name});
    for (text) |byte| {
        // Within quotes backslash is literal; apostrophes are escaped outside quotes.
        if (byte == 39) try out.writeAll(&.{ 39, 92, 39, 39 }) else try out.writeByte(byte);
    }
    try out.writeByte(39);
}
pub fn ruleAlloc(self: Self, allocator: std.mem.Allocator) ![:0]u8 {
    try self.validate();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    // Allocating writer failures can only be allocation failures here.
    out.writer.writeAll("type='signal'") catch return error.OutOfMemory;
    if (self.sender) |sender| field(&out.writer, "sender", switch (sender) {
        .unique, .name => |s| s,
    }) catch return error.OutOfMemory;
    if (self.path) |s| field(&out.writer, "path", s) catch return error.OutOfMemory;
    if (self.path_namespace) |s| field(&out.writer, "path_namespace", s) catch return error.OutOfMemory;
    if (self.interface) |s| field(&out.writer, "interface", s) catch return error.OutOfMemory;
    if (self.member) |s| field(&out.writer, "member", s) catch return error.OutOfMemory;
    if (self.arg0) |s| field(&out.writer, "arg0", s) catch return error.OutOfMemory;
    return allocator.dupeSentinel(u8, out.written(), 0);
}
pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
    var result = self;
    inline for (.{ "path", "path_namespace", "interface", "member", "arg0" }) |key| {
        if (@field(self, key)) |s| @field(result, key) = try allocator.dupeSentinel(u8, s, 0);
    }
    if (self.sender) |sender| result.sender = switch (sender) {
        .unique => |s| .{ .unique = try allocator.dupeSentinel(u8, s, 0) },
        .name => |s| .{ .name = try allocator.dupeSentinel(u8, s, 0) },
    };
    return result;
}
/// resolved_owner must be current when sender is a well-known name.
pub fn matches(self: Self, message: *const Message, resolved_owner: ?[:0]const u8) bool {
    if (message.kind() != .signal) return false;
    if (self.sender) |sender| {
        const expected = switch (sender) {
            .unique => |s| s,
            .name => resolved_owner orelse return false,
        };
        if (!std.mem.eql(u8, expected, message.sender() orelse return false)) return false;
    }
    if (self.path) |s| if (!std.mem.eql(u8, s, message.path() orelse return false)) return false;
    if (self.path_namespace) |s| {
        const path = message.path() orelse return false;
        if (!std.mem.eql(u8, s, path) and !(std.mem.startsWith(u8, path, s) and (s.len == 1 or (path.len > s.len and path[s.len] == '/')))) return false;
    }
    if (self.interface) |s| if (!std.mem.eql(u8, s, message.interface() orelse return false)) return false;
    if (self.member) |s| if (!std.mem.eql(u8, s, message.member() orelse return false)) return false;
    if (self.arg0) |s| {
        var body = message.iter();
        const first = body.read(types.String) catch return false;
        if (!std.mem.eql(u8, s, first.bytes)) return false;
    }
    return true;
}
