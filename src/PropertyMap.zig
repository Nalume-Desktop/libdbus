//! Borrowed a{sv}. Lookups scan the dictionary; iterator() supports a single pass.
const std = @import("std");
const ValueRef = @import("ValueRef.zig");
const Iter = @import("Iter.zig");
const types = @import("types.zig");
const Self = @This();
value_ref: ValueRef,
pub fn init(value_ref: ValueRef) !Self {
    if (!try value_ref.hasSignature("a{sv}")) return error.InvalidReply;
    return .{ .value_ref = value_ref };
}
pub const Entry = struct { name: [:0]const u8, value: ValueRef };
pub const Iterator = struct {
    entries: Iter,
    pub fn next(self: *Iterator) !?Entry {
        if (self.entries.peek() == null) return null;
        var entry = try self.entries.enter(.dict_entry);
        const name = (try entry.read(types.String)).bytes;
        const variant = try entry.value();
        try entry.skip();
        try entry.expectEnd();
        return .{ .name = name, .value = try variant.unwrapVariant() };
    }
};
pub fn iterator(self: Self) Iterator {
    return .{ .entries = self.value_ref.enter(.array) catch unreachable };
}
pub fn optionalValue(self: Self, name: []const u8) !?ValueRef {
    var entries = self.iterator();
    var found: ?ValueRef = null;
    while (try entries.next()) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (found != null) return error.DuplicateProperty;
        found = entry.value;
    }
    return found;
}
pub fn value(self: Self, name: []const u8) !ValueRef {
    return (try self.optionalValue(name)) orelse error.MissingProperty;
}
pub fn get(self: Self, comptime T: type, name: []const u8) !T {
    return (try self.value(name)).as(T);
}
pub fn getOptional(self: Self, comptime T: type, name: []const u8) !?T {
    const found = (try self.optionalValue(name)) orelse return null;
    return try found.as(T);
}
pub fn getBytes(self: Self, name: []const u8) ![]const u8 {
    return (try self.value(name)).bytes();
}
