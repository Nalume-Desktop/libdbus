//! Cursor over a validated signature, not message values. Borrows signature bytes.
const std = @import("std");
const c = @import("dbus_c");
const types = @import("types.zig");
const Signature = @import("Signature.zig");
const Self = @This();
raw: c.DBusSignatureIter,
at_end: bool,
pub const Error = error{ EndOfSignature, TypeMismatch, TrailingTypes };

pub fn init(signature: Signature) Signature.Error!Self {
    try signature.validate();
    var result: Self = .{ .raw = undefined, .at_end = signature.bytes.len == 0 };
    c.dbus_signature_iter_init(&result.raw, signature.bytes.ptr);
    return result;
}

pub fn peek(self: *const Self) ?types.Type {
    if (self.at_end) return null;
    return @fromBackingInt(@intCast(c.dbus_signature_iter_get_current_type(&self.raw)));
}

pub fn skip(self: *Self) Error!void {
    if (self.at_end) return error.EndOfSignature;
    self.at_end = c.dbus_signature_iter_next(&self.raw) == 0;
}

/// Recurse into array/struct/dict-entry and consume it in the parent.
/// 'v' has no contained signature here: only message Iter can enter a variant.
pub fn enter(self: *Self, kind: types.ContainerType) Error!Self {
    const actual = self.peek() orelse return error.EndOfSignature;
    if (kind == .variant or @backingInt(actual) != @backingInt(kind)) return error.TypeMismatch;
    var child: Self = .{ .raw = undefined, .at_end = false };
    c.dbus_signature_iter_recurse(&self.raw, &child.raw);
    child.at_end = c.dbus_signature_iter_get_current_type(&child.raw) == c.DBUS_TYPE_INVALID;
    try self.skip();
    return child;
}

pub fn elementType(self: *const Self) Error!types.Type {
    const actual = self.peek() orelse return error.EndOfSignature;
    if (actual != .array) return error.TypeMismatch;
    return @fromBackingInt(@intCast(c.dbus_signature_iter_get_element_type(&self.raw)));
}

pub fn signatureAlloc(self: *const Self, allocator: std.mem.Allocator) (Error || std.mem.Allocator.Error)![:0]u8 {
    if (self.at_end) return error.EndOfSignature;
    const bytes = c.dbus_signature_iter_get_signature(&self.raw);
    if (bytes == null) return error.OutOfMemory;
    defer c.dbus_free(bytes);
    return allocator.dupeSentinel(u8, std.mem.span(bytes), 0);
}

pub fn expectEnd(self: *const Self) Error!void {
    if (!self.at_end) return error.TrailingTypes;
}
