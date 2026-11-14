//! Borrowed signature value. Validation and traversal use libdbus.
const std = @import("std");
const c = @import("dbus_c");
const Signature = @This();
pub const Iterator = @import("SignatureIter.zig");
pub const Error = error{InvalidSignature};
bytes: [:0]const u8,

pub fn validate(self: Signature) Error!void {
    if (self.bytes.len > 255 or std.mem.indexOfScalar(u8, self.bytes, 0) != null or
        c.dbus_signature_validate(self.bytes.ptr, null) == 0) return error.InvalidSignature;
}

pub fn validateSingle(self: Signature) Error!void {
    try self.validate();
    if (c.dbus_signature_validate_single(self.bytes.ptr, null) == 0) return error.InvalidSignature;
}

/// Iterator borrows the signature bytes, which must remain alive and unchanged.
pub fn iter(self: Signature) Error!Iterator {
    return Iterator.init(self);
}
