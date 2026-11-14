//! Exclusive append cursor. Do not copy/move a Writer while it has an open child.
//! Close all containers before reading/sending the message. abandon poisons the message.
const std = @import("std");
const c = @import("dbus_c");
const types = @import("types.zig");
const Self = @This();

raw: c.DBusMessageIter,
parent: ?*Self = null,
child: ?*Self = null,
kind: ?types.ContainerType = null,
active: bool = true,
failed: bool = false,
// Expected contents, copied so caller-provided signatures need not outlive open().
schema: [256]u8 = @splat(0),
schema_len: ?usize = null,
position: usize = 0,
// Signature of completed contents (arrays need only their declared element schema).
actual: [256]u8 = @splat(0),
actual_len: usize = 0,
count: usize = 0,
depth: usize = 0,
array_depth: usize = 0,
struct_depth: usize = 0,

pub const Error = error{
    OutOfMemory,
    InvalidSignature,
    InvalidString,
    InvalidObjectPath,
    InvalidFileDescriptor,
    FileDescriptorWriteFailed,
    ArrayTooLong,
    TypeMismatch,
    InvalidContainer,
    IncompleteContainer,
    SignatureTooLong,
    NestingTooDeep,
    ActiveChild,
    ClosedWriter,
    FailedWriter,
    NotContainer,
};

/// Caller must supply an unlocked message and ensure exclusive mutation until finish().
pub fn init(message: *c.DBusMessage) Self {
    var result: Self = .{ .raw = undefined };
    c.dbus_message_iter_init_append(message, &result.raw);
    const existing = std.mem.span(c.dbus_message_get_signature(message));
    @memcpy(result.actual[0..existing.len], existing);
    result.actual_len = existing.len;
    return result;
}

fn root(self: *Self) *Self {
    var current = self;
    while (current.parent) |parent| current = parent;
    return current;
}

fn ready(self: *Self) Error!void {
    if (!self.active) return error.ClosedWriter;
    if (self.root().failed) return error.FailedWriter;
    if (self.child != null) return error.ActiveChild;
}

// Token boundary only: input has already been validated by libdbus.
fn firstLength(bytes: []const u8) usize {
    var i: usize = 0;
    while (bytes[i] == 'a') : (i += 1) {}
    if (bytes[i] != '(' and bytes[i] != '{') return i + 1;
    var nesting: usize = 1;
    i += 1;
    while (nesting != 0) : (i += 1) {
        if (bytes[i] == '(' or bytes[i] == '{') nesting += 1;
        if (bytes[i] == ')' or bytes[i] == '}') nesting -= 1;
    }
    return i;
}

fn expected(self: *Self) Error!?[]const u8 {
    const len = self.schema_len orelse return null;
    if (self.position == len) return error.TypeMismatch;
    const remaining = self.schema[self.position..len];
    return remaining[0..firstLength(remaining)];
}

fn check(self: *Self, signature: []const u8) Error!void {
    if (try self.expected()) |want| {
        if (!std.mem.eql(u8, want, signature)) return error.TypeMismatch;
    }
    if (self.kind != .array and self.actual_len + signature.len > 255) return error.SignatureTooLong;
}

fn record(self: *Self, signature: []const u8) void {
    if (self.kind != .array) {
        @memcpy(self.actual[self.actual_len..][0..signature.len], signature);
        self.actual_len += signature.len;
        if (self.schema_len != null) self.position += signature.len;
    }
    self.count += 1;
}

fn nativeFailure(self: *Self) Error {
    self.root().failed = true;
    return error.OutOfMemory;
}

/// Copies string bytes and duplicates FDs into libdbus; ownership of input stays with caller.
pub fn write(self: *Self, value: anytype) Error!void {
    try self.ready();
    const T = @TypeOf(value);
    const kind = comptime types.basicType(T);
    const signature = [_]u8{@intCast(@backingInt(kind))};
    try self.check(&signature);
    if (T == types.String or T == types.ObjectPath or T == types.Signature) {
        if (T == types.Signature) {
            try value.validate();
        } else {
            if (std.mem.indexOfScalar(u8, value.bytes, 0) != null) return error.InvalidString;
            if (T == types.String) {
                if (c.dbus_validate_utf8(value.bytes.ptr, null) == 0) return error.InvalidString;
            } else if (c.dbus_validate_path(value.bytes.ptr, null) == 0) return error.InvalidObjectPath;
        }
        const pointer = value.bytes.ptr;
        if (c.dbus_message_iter_append_basic(&self.raw, @backingInt(kind), @ptrCast(&pointer)) == 0) return self.nativeFailure();
    } else if (T == bool) {
        const boolean: c.dbus_bool_t = @intFromBool(value);
        if (c.dbus_message_iter_append_basic(&self.raw, @backingInt(kind), &boolean) == 0) return self.nativeFailure();
    } else if (T == types.UnixFd) {
        if (value.fd < 0) return error.InvalidFileDescriptor;
        if (c.dbus_message_iter_append_basic(&self.raw, @backingInt(kind), &value.fd) == 0) {
            self.root().failed = true;
            return error.FileDescriptorWriteFailed; // C does not distinguish dup failure from OOM.
        }
    } else {
        if (c.dbus_message_iter_append_basic(&self.raw, @backingInt(kind), &value) == 0) return self.nativeFailure();
    }
    self.record(&signature);
}

/// Arrays take one element signature (including {kv}); variants take one value signature.
/// Struct/dict-entry take null. 'out' must be distinct, unoccupied storage, kept stable until closed.
pub fn open(self: *Self, kind: types.ContainerType, signature: ?[:0]const u8, out: *Self) Error!void {
    try self.ready();
    var ancestor: ?*Self = self;
    while (ancestor) |item| : (ancestor = item.parent) {
        if (item == out) return error.InvalidContainer;
    }
    const arrays = self.array_depth + @intFromBool(kind == .array);
    const structs = self.struct_depth + @intFromBool(kind == .structure or kind == .dict_entry);
    if (self.depth >= 64 or arrays > 32 or structs > 32) return error.NestingTooDeep;
    var outer: [256]u8 = @splat(0);
    var outer_len: usize = 1;
    outer[0] = switch (kind) {
        .array => 'a',
        .variant => 'v',
        .structure => '(',
        .dict_entry => '{',
    };
    if (kind == .array or kind == .variant) {
        const contents = signature orelse return error.InvalidSignature;
        if (contents.len > 254 and kind == .array) return error.SignatureTooLong;
        if (kind == .array) {
            @memcpy(outer[1..][0..contents.len], contents);
            outer_len += contents.len;
            try (types.Signature{ .bytes = outer[0..outer_len :0] }).validateSingle();
        } else try (types.Signature{ .bytes = contents }).validateSingle();
        try self.check(outer[0..outer_len]);
    } else {
        if (signature != null) return error.InvalidSignature;
        if (kind == .dict_entry and self.kind != .array) return error.InvalidContainer;
        if (try self.expected()) |want| {
            if (want[0] != outer[0]) return error.TypeMismatch;
        } else if (kind == .dict_entry) return error.InvalidContainer;
    }
    out.* = .{ .raw = undefined, .parent = self, .kind = kind, .depth = self.depth + 1, .array_depth = arrays, .struct_depth = structs };
    const contents: ?[]const u8 = if (signature) |s| s else if (try self.expected()) |want| want[1 .. want.len - 1] else null;
    if (contents) |s| {
        @memcpy(out.schema[0..s.len], s);
        out.schema_len = s.len;
    }
    if (c.dbus_message_iter_open_container(&self.raw, @backingInt(kind), if (signature) |s| s.ptr else null, &out.raw) == 0) {
        out.active = false;
        return self.nativeFailure();
    }
    self.child = out;
}

/// Validation failures leave the container open so missing values can be supplied.
/// Native failures invalidate the container and poison the whole message.
pub fn close(self: *Self) Error!void {
    try self.ready();
    const parent = self.parent orelse return error.NotContainer;
    if (self.kind != .array) {
        if (self.schema_len) |len| {
            if (self.position != len) return error.IncompleteContainer;
        }
        if (self.kind == .structure and self.count == 0) return error.IncompleteContainer;
    }
    var signature: [256]u8 = @splat(0);
    var len: usize = 1;
    switch (self.kind.?) {
        .variant => signature[0] = 'v',
        .array => {
            signature[0] = 'a';
            len += self.schema_len.?;
            @memcpy(signature[1..len], self.schema[0..self.schema_len.?]);
        },
        .structure, .dict_entry => |kind| {
            len = self.actual_len + 2;
            if (len > 255) return error.SignatureTooLong;
            signature[0] = if (kind == .structure) '(' else '{';
            @memcpy(signature[1 .. len - 1], self.actual[0..self.actual_len]);
            signature[len - 1] = if (kind == .structure) ')' else '}';
        },
    }
    if (self.kind != .dict_entry) try (types.Signature{ .bytes = signature[0..len :0] }).validateSingle();
    try parent.check(signature[0..len]);
    const success = c.dbus_message_iter_close_container(&parent.raw, &self.raw) != 0;
    self.active = false;
    parent.child = null;
    if (!success) return parent.nativeFailure();
    parent.record(signature[0..len]);
}

/// Recursively frees open container state. Idempotent. The message must be discarded.
pub fn abandon(self: *Self) void {
    if (!self.active) return;
    self.root().failed = true;
    if (self.child) |child| child.abandon();
    if (self.parent) |parent| {
        c.dbus_message_iter_abandon_container(&parent.raw, &self.raw);
        parent.child = null;
    }
    self.active = false;
}

/// Cleanup guard: no-op after close/finish; otherwise abandon and discard the message.
pub fn deinit(self: *Self) void {
    self.abandon();
}

/// Seals the root Writer, not the raw message. No open containers may remain.
pub fn finish(self: *Self) Error!void {
    try self.ready();
    if (self.parent != null) return error.NotContainer;
    self.active = false;
}

pub fn writeBytes(self: *Self, bytes: []const u8) Error!void {
    try self.ready();
    if (bytes.len > c.DBUS_MAXIMUM_ARRAY_LENGTH) return error.ArrayTooLong;
    var array: Self = undefined;
    try self.open(.array, "y", &array);
    defer array.deinit();
    const pointer = bytes.ptr;
    if (bytes.len != 0 and c.dbus_message_iter_append_fixed_array(&array.raw, c.DBUS_TYPE_BYTE, @ptrCast(&pointer), @intCast(bytes.len)) == 0) return self.nativeFailure();
    try array.close();
}
