//! Read-only cursor. All cursors borrow an alive, unchanged DBusMessage.
//! Successful read/enter/skip consumes ONE value; failures leave the cursor unchanged.
//! Copying a cursor creates an independent position, not a message reference.
const std = @import("std");
const c = @import("dbus_c");
const types = @import("types.zig");
const Iter = @This();

raw: c.DBusMessageIter,
message: *c.DBusMessage,
at_end: bool,

pub const Error = error{ EndOfMessage, TypeMismatch, TrailingValues, FileDescriptorUnavailable };

pub fn init(message: *c.DBusMessage) Iter {
    var result: Iter = .{ .raw = undefined, .message = message, .at_end = false };
    result.at_end = c.dbus_message_iter_init(message, &result.raw) == 0;
    return result;
}

pub fn peek(self: *const Iter) ?types.Type {
    if (self.at_end) return null;
    var raw = self.raw;
    return @fromBackingInt(@intCast(c.dbus_message_iter_get_arg_type(&raw)));
}

fn require(self: *const Iter, expected: types.Type) Error!void {
    const actual = self.peek() orelse return error.EndOfMessage;
    if (actual != expected) return error.TypeMismatch;
}

fn advance(self: *Iter) void {
    self.at_end = c.dbus_message_iter_next(&self.raw) == 0;
}

/// Reads a basic value. Strings borrow; UnixFd returns an owned duplicate.
/// No implicit conversions, allocations for strings, or custom decode dispatch.
pub fn read(self: *Iter, comptime T: type) Error!T {
    try self.require(comptime types.basicType(T));
    const result: T = if (T == bool) blk: {
        var basic: c.dbus_bool_t = undefined;
        c.dbus_message_iter_get_basic(&self.raw, &basic);
        break :blk basic != 0;
    } else if (T == types.String or T == types.ObjectPath or T == types.Signature) blk: {
        var basic: [*c]const u8 = undefined;
        c.dbus_message_iter_get_basic(&self.raw, @ptrCast(&basic));
        break :blk .{ .bytes = std.mem.span(@as([*:0]const u8, @ptrCast(basic))) };
    } else if (T == types.UnixFd) blk: {
        var fd: c_int = -1;
        c.dbus_message_iter_get_basic(&self.raw, &fd);
        if (fd < 0) return error.FileDescriptorUnavailable;
        break :blk .{ .fd = fd };
    } else blk: {
        var basic: T = undefined;
        c.dbus_message_iter_get_basic(&self.raw, &basic);
        break :blk basic;
    };
    self.advance();
    return result;
}

/// Returns an independent child cursor and consumes the container in the parent.
/// An empty array returns a child at end; it still consumes one parent value.
pub fn enter(self: *Iter, kind: types.ContainerType) Error!Iter {
    try self.require(@fromBackingInt(@intCast(@backingInt(kind))));
    var child: Iter = .{ .raw = undefined, .message = self.message, .at_end = false };
    c.dbus_message_iter_recurse(&self.raw, &child.raw);
    child.at_end = c.dbus_message_iter_get_arg_type(&child.raw) == c.DBUS_TYPE_INVALID;
    self.advance();
    return child;
}

/// The array element kind, including for empty arrays. Does not consume anything.
/// Use signatureAlloc when the full nested element signature matters.
pub fn elementType(self: *const Iter) Error!types.Type {
    try self.require(.array);
    var raw = self.raw;
    return @fromBackingInt(@intCast(c.dbus_message_iter_get_element_type(&raw)));
}

/// Reads a complete ay as a borrowed slice. Does not conflate strings with bytes.
pub fn readBytes(self: *Iter) Error![]const u8 {
    if (try self.elementType() != .byte) return error.TypeMismatch;
    var child: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&self.raw, &child);
    var bytes: ?[*]const u8 = null;
    var length: c_int = 0;
    c.dbus_message_iter_get_fixed_array(&child, @ptrCast(&bytes), &length);
    const basic: []const u8 = if (length == 0) &.{} else bytes.?[0..@intCast(length)];
    self.advance();
    return basic;
}

/// Copies the full signature of the current value (e.g. a{sv}), not remaining args.
/// Caller frees with allocator.free. Does not consume the value.
pub fn signatureAlloc(self: *const Iter, allocator: std.mem.Allocator) (Error || std.mem.Allocator.Error)![:0]u8 {
    if (self.at_end) return error.EndOfMessage;
    var raw = self.raw;
    const signature = c.dbus_message_iter_get_signature(&raw);
    if (signature == null) return error.OutOfMemory;
    defer c.dbus_free(signature);
    return allocator.dupeSentinel(u8, std.mem.span(signature), 0);
}

/// Borrow the current single value without advancing.
pub fn value(self: *const Iter) Error!@import("ValueRef.zig") {
    if (self.at_end) return error.EndOfMessage;
    return .{ .cursor = self.* };
}

pub fn nextValue(self: *Iter) Error!?@import("ValueRef.zig") {
    if (self.at_end) return null;
    const result = try self.value();
    self.advance();
    return result;
}

pub fn skip(self: *Iter) Error!void {
    if (self.at_end) return error.EndOfMessage;
    self.advance();
}

pub fn expectEnd(self: *const Iter) Error!void {
    if (!self.at_end) return error.TrailingValues;
}
