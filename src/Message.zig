//! Owns one DBusMessage reference. Values/cursors returned by accessors borrow it.
//! Zig assignment is NOT ref(): release each owned reference exactly once.
const std = @import("std");
const c = @import("dbus_c");
const Iter = @import("Iter.zig");
const Writer = @import("Writer.zig");
const NativeError = @import("Error.zig");
const Signature = @import("Signature.zig");
const Self = @This();
pointer: ?*c.DBusMessage,

pub const Kind = enum(c_int) {
    method_call = c.DBUS_MESSAGE_TYPE_METHOD_CALL,
    method_return = c.DBUS_MESSAGE_TYPE_METHOD_RETURN,
    signal = c.DBUS_MESSAGE_TYPE_SIGNAL,
    error_reply = c.DBUS_MESSAGE_TYPE_ERROR,
};
pub const Error = error{ OutOfMemory, InvalidPath, InvalidInterface, InvalidMember, InvalidDestination, InvalidErrorName, InvalidText, InvalidRequest, MissingSerial };
pub const CallOptions = struct {
    destination: ?[:0]const u8 = null,
    path: [:0]const u8,
    interface: ?[:0]const u8 = null,
    member: [:0]const u8,
    no_reply: bool = false,
    auto_start: bool = true,
    interactive_authorization: bool = false,
};

fn noNul(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) == null;
}
fn borrowed(p: [*c]const u8) ?[:0]const u8 {
    return if (p == null) null else std.mem.span(p);
}

/// Adopt exactly one already-owned native reference, without incrementing it.
pub fn adopt(p: *c.DBusMessage) Self {
    return .{ .pointer = p };
}
/// Retain a borrowed native pointer as an owned reference.
pub fn fromBorrowed(p: *c.DBusMessage) Self {
    return adopt(c.dbus_message_ref(p).?);
}
pub fn ref(self: *const Self) Self {
    return fromBorrowed(self.raw());
}
/// Deep copy; libdbus resets the serial and produces an unlocked, editable message.
pub fn copy(self: *const Self) Error!Self {
    return adopt(c.dbus_message_copy(self.raw()) orelse return error.OutOfMemory);
}
pub fn deinit(self: *Self) void {
    if (self.pointer) |p| c.dbus_message_unref(p);
    self.pointer = null;
}
/// Transfer this reference to the caller; no unref. self is safe to deinit afterward.
pub fn release(self: *Self) *c.DBusMessage {
    const p = self.raw();
    self.pointer = null;
    return p;
}
/// Borrowed escape hatch. Do not unref it unless ownership was transferred with release.
pub fn raw(self: *const Self) *c.DBusMessage {
    return self.pointer.?;
}

pub fn methodCall(options: CallOptions) Error!Self {
    if (!noNul(options.path) or c.dbus_validate_path(options.path.ptr, null) == 0) return error.InvalidPath;
    if (!noNul(options.member) or c.dbus_validate_member(options.member.ptr, null) == 0) return error.InvalidMember;
    if (options.interface) |s| if (!noNul(s) or c.dbus_validate_interface(s.ptr, null) == 0) return error.InvalidInterface;
    if (options.destination) |s| if (!noNul(s) or c.dbus_validate_bus_name(s.ptr, null) == 0) return error.InvalidDestination;
    const p = c.dbus_message_new_method_call(if (options.destination) |s| s.ptr else null, options.path.ptr, if (options.interface) |s| s.ptr else null, options.member.ptr) orelse return error.OutOfMemory;
    c.dbus_message_set_no_reply(p, @intFromBool(options.no_reply));
    c.dbus_message_set_auto_start(p, @intFromBool(options.auto_start));
    c.dbus_message_set_allow_interactive_authorization(p, @intFromBool(options.interactive_authorization));
    return adopt(p);
}
pub fn signal(object_path: [:0]const u8, interface_name: [:0]const u8, member_name: [:0]const u8) Error!Self {
    if (!noNul(object_path) or c.dbus_validate_path(object_path.ptr, null) == 0) return error.InvalidPath;
    if (!noNul(interface_name) or c.dbus_validate_interface(interface_name.ptr, null) == 0) return error.InvalidInterface;
    if (!noNul(member_name) or c.dbus_validate_member(member_name.ptr, null) == 0) return error.InvalidMember;
    return adopt(c.dbus_message_new_signal(object_path.ptr, interface_name.ptr, member_name.ptr) orelse return error.OutOfMemory);
}
fn checkRequest(request: *const Self) Error!void {
    if (request.kind() != .method_call) return error.InvalidRequest;
    if (request.serial() == 0) return error.MissingSerial;
}
pub fn methodReturn(request: *const Self) Error!Self {
    try checkRequest(request);
    return adopt(c.dbus_message_new_method_return(request.raw()) orelse return error.OutOfMemory);
}
pub fn errorReply(request: *const Self, error_name: [:0]const u8, text: ?[:0]const u8) Error!Self {
    try checkRequest(request);
    if (!noNul(error_name) or c.dbus_validate_error_name(error_name.ptr, null) == 0) return error.InvalidErrorName;
    if (text) |s| if (!noNul(s) or c.dbus_validate_utf8(s.ptr, null) == 0) return error.InvalidText;
    return adopt(c.dbus_message_new_error(request.raw(), error_name.ptr, if (text) |s| s.ptr else null) orelse return error.OutOfMemory);
}

pub fn kind(self: *const Self) Kind {
    return @fromBackingInt(@intCast(c.dbus_message_get_type(self.raw())));
}
pub fn path(self: *const Self) ?[:0]const u8 {
    return borrowed(c.dbus_message_get_path(self.raw()));
}
pub fn interface(self: *const Self) ?[:0]const u8 {
    return borrowed(c.dbus_message_get_interface(self.raw()));
}
pub fn member(self: *const Self) ?[:0]const u8 {
    return borrowed(c.dbus_message_get_member(self.raw()));
}
pub fn sender(self: *const Self) ?[:0]const u8 {
    return borrowed(c.dbus_message_get_sender(self.raw()));
}
pub fn destination(self: *const Self) ?[:0]const u8 {
    return borrowed(c.dbus_message_get_destination(self.raw()));
}
pub fn errorName(self: *const Self) ?[:0]const u8 {
    return borrowed(c.dbus_message_get_error_name(self.raw()));
}
pub fn signature(self: *const Self) Signature {
    return .{ .bytes = std.mem.span(c.dbus_message_get_signature(self.raw())) };
}
pub fn serial(self: *const Self) u32 {
    return c.dbus_message_get_serial(self.raw());
}
pub fn replySerial(self: *const Self) u32 {
    return c.dbus_message_get_reply_serial(self.raw());
}
pub fn noReply(self: *const Self) bool {
    return c.dbus_message_get_no_reply(self.raw()) != 0;
}
pub fn autoStart(self: *const Self) bool {
    return c.dbus_message_get_auto_start(self.raw()) != 0;
}
pub fn interactiveAuthorization(self: *const Self) bool {
    return c.dbus_message_get_allow_interactive_authorization(self.raw()) != 0;
}
pub fn iter(self: *const Self) Iter {
    return Iter.init(self.raw());
}
/// Requires exclusive access to an unlocked message, including through other references.
/// Finish/deinit the writer before using any read cursor or sending the message.
pub fn writer(self: *Self) Writer {
    return Writer.init(self.raw());
}

/// Borrow the first string in an error reply, if present. The full body remains in iter().
pub fn errorText(self: *const Self) ?[:0]const u8 {
    if (self.kind() != .error_reply) return null;
    var values = self.iter();
    const text = values.read(@import("types.zig").String) catch return null;
    return text.bytes;
}
/// Copy native error details into independent DBusError storage; null for other messages.
/// For exact remote data (including nonstandard bodies), keep this Message and use iter().
pub fn toError(self: *const Self) error{OutOfMemory}!?NativeError {
    if (self.kind() != .error_reply) return null;
    var result = try NativeError.init();
    _ = c.dbus_set_error_from_message(result.out(), self.raw());
    return result;
}
