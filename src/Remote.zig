//! Validated, non-owning target. Connection and target strings must outlive this view.
const std = @import("std");
const c = @import("dbus_c");
const Connection = @import("Connection.zig");
const Message = @import("Message.zig");
const types = @import("types.zig");
const Properties = @import("Properties.zig");
const Property = @import("Property.zig");
const Self = @This();
connection: *Connection,
target: Target,
pub const Target = struct { destination: [:0]const u8, path: [:0]const u8, interface: [:0]const u8, auto_start: bool = false };
pub const Options = struct { timeout: Connection.Timeout = .default, remote_error: ?*@import("RemoteError.zig") = null };
fn noNul(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, 0) == null;
}
pub fn init(connection: *Connection, target: Target) !Self {
    if (!noNul(target.destination) or c.dbus_validate_bus_name(target.destination.ptr, null) == 0) return error.InvalidDestination;
    if (!noNul(target.path) or c.dbus_validate_path(target.path.ptr, null) == 0) return error.InvalidPath;
    if (!noNul(target.interface) or c.dbus_validate_interface(target.interface.ptr, null) == 0) return error.InvalidInterface;
    return .{ .connection = connection, .target = target };
}
pub fn methodCall(self: Self, member: [:0]const u8) !Message {
    return Message.methodCall(.{ .destination = self.target.destination, .path = self.target.path, .interface = self.target.interface, .member = member, .auto_start = self.target.auto_start });
}
/// Call an explicitly encoded request; preserve remote errors in options.remote_error.
pub fn call(self: Self, request: *const Message, options: Options) !Message {
    if (options.remote_error) |detail| detail.deinit();
    var reply = try self.connection.call(request, .{ .timeout = options.timeout });
    errdefer reply.deinit();
    if (reply.kind() == .error_reply) {
        if (options.remote_error) |detail| detail.capture(&reply);
        return error.RemoteError;
    }
    if (reply.kind() != .method_return) return error.InvalidReply;
    return reply;
}
fn propertyRequest(self: Self, member: [:0]const u8, name: ?[:0]const u8) !Message {
    var target = self;
    target.target.interface = "org.freedesktop.DBus.Properties";
    var message = try target.methodCall(member);
    errdefer message.deinit();
    var writer = message.writer();
    defer writer.deinit();
    try writer.write(types.String{ .bytes = self.target.interface });
    if (name) |n| try writer.write(types.String{ .bytes = n });
    try writer.finish();
    return message;
}
/// Encode exactly one value into the variant using encode(context, writer).
/// Encoding failure sends nothing; successful Set must return an empty body.
pub fn setProperty(self: Self, name: [:0]const u8, signature: [:0]const u8, context: anytype, comptime encode: anytype, options: Options) !void {
    if (options.remote_error) |detail| detail.deinit();
    var target = self;
    target.target.interface = "org.freedesktop.DBus.Properties";
    var request = try target.methodCall("Set");
    defer request.deinit();
    var writer = request.writer();
    defer writer.deinit();
    try writer.write(types.String{ .bytes = self.target.interface });
    try writer.write(types.String{ .bytes = name });
    var variant: @import("Writer.zig") = undefined;
    try writer.open(.variant, signature, &variant);
    defer variant.deinit();
    try encode(context, &variant);
    try variant.close();
    try writer.finish();
    var reply = try self.call(&request, options);
    defer reply.deinit();
    if (reply.signature().bytes.len != 0) return error.InvalidReply;
}
pub fn getManagedObjects(self: Self, options: Options) !@import("ObjectManager.zig").ManagedObjects {
    var target = self;
    target.target.interface = @import("ObjectManager.zig").interface;
    var request = try target.methodCall("GetManagedObjects");
    defer request.deinit();
    var reply = try self.call(&request, options);
    defer reply.deinit();
    return @import("ObjectManager.zig").ManagedObjects.init(&reply);
}
pub fn getAllProperties(self: Self, options: Options) !Properties {
    var request = try self.propertyRequest("GetAll", null);
    defer request.deinit();
    var reply = try self.call(&request, options);
    defer reply.deinit();
    return Properties.init(&reply);
}
pub fn getProperty(self: Self, name: [:0]const u8, options: Options) !Property {
    var request = try self.propertyRequest("Get", name);
    defer request.deinit();
    var reply = try self.call(&request, options);
    defer reply.deinit();
    return Property.init(&reply);
}
pub fn getScalar(self: Self, comptime T: type, name: [:0]const u8, options: Options) !T {
    comptime {
        switch (types.basicType(T)) {
            .string, .object_path, .signature, .unix_fd => @compileError("getScalar accepts numeric and boolean values only"),
            else => {},
        }
    }
    var property = try self.getProperty(name, options);
    defer property.deinit();
    return property.value().as(T);
}
pub fn getStringAlloc(self: Self, allocator: std.mem.Allocator, name: [:0]const u8, options: Options) ![:0]u8 {
    var property = try self.getProperty(name, options);
    defer property.deinit();
    return allocator.dupeSentinel(u8, (try property.value().as(types.String)).bytes, 0);
}
pub fn getBytesAlloc(self: Self, allocator: std.mem.Allocator, name: [:0]const u8, options: Options) ![]u8 {
    var property = try self.getProperty(name, options);
    defer property.deinit();
    return allocator.dupe(u8, try property.value().bytes());
}
