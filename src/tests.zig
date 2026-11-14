const std = @import("std");
const testing = std.testing;
const dbus = @import("root.zig");
const c = dbus.c;

fn newMessage() !*c.DBusMessage {
    return c.dbus_message_new(c.DBUS_MESSAGE_TYPE_METHOD_RETURN) orelse error.OutOfMemory;
}

fn append(iter: *c.DBusMessageIter, kind: c_int, value: anytype) !void {
    const stored = value;
    if (c.dbus_message_iter_append_basic(iter, kind, @ptrCast(&stored)) == 0) return error.OutOfMemory;
}

fn open(parent: *c.DBusMessageIter, kind: c_int, signature: ?[*:0]const u8, child: *c.DBusMessageIter) !void {
    if (c.dbus_message_iter_open_container(parent, kind, signature, child) == 0) return error.OutOfMemory;
}

fn close(parent: *c.DBusMessageIter, child: *c.DBusMessageIter) !void {
    if (c.dbus_message_iter_close_container(parent, child) == 0) return error.OutOfMemory;
}

test "empty message and repeated end operations are safe" {
    const message = try newMessage();
    defer c.dbus_message_unref(message);
    var iter = dbus.Iter.init(message);
    try testing.expectEqual(null, iter.peek());
    try iter.expectEnd();
    try testing.expectError(error.EndOfMessage, iter.read(u32));
    try testing.expectError(error.EndOfMessage, iter.enter(.array));
    try testing.expectError(error.EndOfMessage, iter.skip());
    try testing.expectError(error.EndOfMessage, iter.readBytes());
    try testing.expectError(error.EndOfMessage, iter.signatureAlloc(testing.allocator));
    try iter.expectEnd();
}

test "all numeric basic types use exact types and advance once" {
    const message = try newMessage();
    defer c.dbus_message_unref(message);
    var writer: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &writer);
    const values = .{ @as(u8, 255), @as(c.dbus_bool_t, 1), @as(i16, -32768), @as(u16, 65535), @as(i32, -2147483648), @as(u32, 4294967295), @as(i64, -9223372036854775807), @as(u64, 18446744073709551615), @as(f64, 1.25) };
    const codes = .{ c.DBUS_TYPE_BYTE, c.DBUS_TYPE_BOOLEAN, c.DBUS_TYPE_INT16, c.DBUS_TYPE_UINT16, c.DBUS_TYPE_INT32, c.DBUS_TYPE_UINT32, c.DBUS_TYPE_INT64, c.DBUS_TYPE_UINT64, c.DBUS_TYPE_DOUBLE };
    inline for (values, codes) |value, code| try append(&writer, code, value);
    try append(&writer, c.DBUS_TYPE_BOOLEAN, @as(c.dbus_bool_t, 0));
    var iter = dbus.Iter.init(message);
    inline for (values, 0..) |value, index| {
        if (index == 1) {
            try testing.expect(try iter.read(bool));
        } else {
            try testing.expectEqual(value, try iter.read(@TypeOf(value)));
        }
    }
    try testing.expect(!try iter.read(bool));
    try iter.expectEnd();
}

test "string-like types stay distinct and borrowed" {
    const message = try newMessage();
    defer c.dbus_message_unref(message);
    var writer: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &writer);
    try append(&writer, c.DBUS_TYPE_STRING, @as([*:0]const u8, "设备"));
    try append(&writer, c.DBUS_TYPE_OBJECT_PATH, @as([*:0]const u8, "/org/example"));
    try append(&writer, c.DBUS_TYPE_SIGNATURE, @as([*:0]const u8, "a{sv}"));
    var iter = dbus.Iter.init(message);
    try testing.expectError(error.TrailingValues, iter.expectEnd());
    try testing.expectError(error.TypeMismatch, iter.read(dbus.ObjectPath));
    try testing.expectError(error.TypeMismatch, iter.enter(.variant));
    try testing.expectError(error.TypeMismatch, iter.readBytes());
    try testing.expectEqual(dbus.Type.string, iter.peek().?);
    var copy = iter;
    const text = try iter.read(dbus.String);
    const same_text = try copy.read(dbus.String);
    try testing.expectEqualStrings("设备", text.bytes);
    try testing.expectEqual(text.bytes.ptr, same_text.bytes.ptr);
    try testing.expectError(error.TypeMismatch, iter.read(dbus.String));
    try testing.expectEqualStrings("/org/example", (try iter.read(dbus.ObjectPath)).bytes);
    try testing.expectEqualStrings("a{sv}", (try iter.read(dbus.Signature)).bytes);
    try iter.expectEnd();
}

const Device = struct {
    name: []const u8,
    class: u32,
    powered: bool,

    fn decode(iter: *dbus.Iter) !Device {
        // Transactional cursor: commit only after all fields have been checked.
        var cursor = iter.*;
        var fields = try cursor.enter(.structure);
        const result: Device = .{
            .name = (try fields.read(dbus.String)).bytes,
            .class = try fields.read(u32),
            .powered = try fields.read(bool),
        };
        try fields.expectEnd();
        iter.* = cursor;
        return result;
    }
};

fn appendDevice(writer: *c.DBusMessageIter, extra: bool) !void {
    var fields: c.DBusMessageIter = undefined;
    try open(writer, c.DBUS_TYPE_STRUCT, null, &fields);
    errdefer c.dbus_message_iter_abandon_container(writer, &fields);
    try append(&fields, c.DBUS_TYPE_STRING, @as([*:0]const u8, "Adapter"));
    try append(&fields, c.DBUS_TYPE_UINT32, @as(u32, 42));
    try append(&fields, c.DBUS_TYPE_BOOLEAN, @as(c.dbus_bool_t, 1));
    if (extra) try append(&fields, c.DBUS_TYPE_UINT32, @as(u32, 99));
    try close(writer, &fields);
}

test "business struct decoding and transactional failure" {
    const message = try newMessage();
    defer c.dbus_message_unref(message);
    var writer: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &writer);
    try appendDevice(&writer, false);
    try appendDevice(&writer, true);
    try append(&writer, c.DBUS_TYPE_UINT32, @as(u32, 7));
    var iter = dbus.Iter.init(message);
    const signature = try iter.signatureAlloc(testing.allocator);
    defer testing.allocator.free(signature);
    try testing.expectEqualStrings("(sub)", signature);
    const device = try Device.decode(&iter);
    try testing.expectEqualStrings("Adapter", device.name);
    try testing.expectEqual(@as(u32, 42), device.class);
    try testing.expect(device.powered);
    try testing.expectError(error.TrailingValues, Device.decode(&iter));
    try testing.expectEqual(dbus.Type.structure, iter.peek().?);
    try iter.skip();
    try testing.expectEqual(@as(u32, 7), try iter.read(u32));
    try iter.expectEnd();
}

test "empty arrays retain element type and parent advances independently" {
    const message = try newMessage();
    defer c.dbus_message_unref(message);
    var writer: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &writer);
    var array: c.DBusMessageIter = undefined;
    try open(&writer, c.DBUS_TYPE_ARRAY, "s", &array);
    try close(&writer, &array);
    try open(&writer, c.DBUS_TYPE_ARRAY, "u", &array);
    try append(&array, c.DBUS_TYPE_UINT32, @as(u32, 10));
    try append(&array, c.DBUS_TYPE_UINT32, @as(u32, 20));
    try close(&writer, &array);
    try append(&writer, c.DBUS_TYPE_STRING, @as([*:0]const u8, "tail"));
    var iter = dbus.Iter.init(message);
    try testing.expectEqual(dbus.Type.string, try iter.elementType());
    const signature = try iter.signatureAlloc(testing.allocator);
    defer testing.allocator.free(signature);
    try testing.expectEqualStrings("as", signature);
    try testing.expectError(error.TypeMismatch, iter.readBytes());
    var empty = try iter.enter(.array);
    try empty.expectEnd();
    try testing.expectError(error.EndOfMessage, empty.skip());
    try testing.expectEqual(dbus.Type.uint32, try iter.elementType());
    var numbers = try iter.enter(.array);
    try testing.expectEqualStrings("tail", (try iter.read(dbus.String)).bytes);
    try iter.expectEnd();
    try testing.expectEqual(@as(u32, 10), try numbers.read(u32));
    try testing.expectEqual(@as(u32, 20), try numbers.read(u32));
    try numbers.expectEnd();
}

test "byte arrays including empty return borrowed slices" {
    const message = try newMessage();
    defer c.dbus_message_unref(message);
    var writer: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &writer);
    var array: c.DBusMessageIter = undefined;
    try open(&writer, c.DBUS_TYPE_ARRAY, "y", &array);
    for ([_]u8{ 0, 127, 255 }) |value| try append(&array, c.DBUS_TYPE_BYTE, value);
    try close(&writer, &array);
    try open(&writer, c.DBUS_TYPE_ARRAY, "y", &array);
    try close(&writer, &array);
    var iter = dbus.Iter.init(message);
    var copy = iter;
    const bytes = try iter.readBytes();
    try testing.expectEqualSlices(u8, &.{ 0, 127, 255 }, bytes);
    try testing.expectEqual(bytes.ptr, (try copy.readBytes()).ptr);
    try testing.expectEqual(@as(usize, 0), (try iter.readBytes()).len);
    try iter.expectEnd();
}

fn appendProperty(writer: *c.DBusMessageIter, name: [*:0]const u8, signature: [*:0]const u8, kind: c_int, value: anytype) !void {
    var entry: c.DBusMessageIter = undefined;
    try open(writer, c.DBUS_TYPE_DICT_ENTRY, null, &entry);
    errdefer c.dbus_message_iter_abandon_container(writer, &entry);
    try append(&entry, c.DBUS_TYPE_STRING, name);
    var variant: c.DBusMessageIter = undefined;
    try open(&entry, c.DBUS_TYPE_VARIANT, signature, &variant);
    errdefer c.dbus_message_iter_abandon_container(&entry, &variant);
    try append(&variant, kind, value);
    try close(&entry, &variant);
    try close(writer, &entry);
}

test "a{sv} custom decoding skips unknown variants" {
    const message = try newMessage();
    defer c.dbus_message_unref(message);
    var writer: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &writer);
    var array: c.DBusMessageIter = undefined;
    try open(&writer, c.DBUS_TYPE_ARRAY, "{sv}", &array);
    try appendProperty(&array, "Unknown", "u", c.DBUS_TYPE_UINT32, @as(u32, 77));
    try appendProperty(&array, "Powered", "b", c.DBUS_TYPE_BOOLEAN, @as(c.dbus_bool_t, 1));
    try appendProperty(&array, "Alias", "s", c.DBUS_TYPE_STRING, @as([*:0]const u8, "My Adapter"));
    try close(&writer, &array);
    var iter = dbus.Iter.init(message);
    const signature = try iter.signatureAlloc(testing.allocator);
    defer testing.allocator.free(signature);
    try testing.expectEqualStrings("a{sv}", signature);
    var entries = try iter.enter(.array);
    var powered = false;
    var alias: ?[]const u8 = null;
    while (entries.peek() != null) {
        var entry = try entries.enter(.dict_entry);
        const name = (try entry.read(dbus.String)).bytes;
        var value = try entry.enter(.variant);
        if (std.mem.eql(u8, name, "Powered")) {
            powered = try value.read(bool);
        } else if (std.mem.eql(u8, name, "Alias")) {
            alias = (try value.read(dbus.String)).bytes;
        } else {
            try value.skip();
        }
        try value.expectEnd();
        try entry.expectEnd();
    }
    try testing.expect(powered);
    try testing.expectEqualStrings("My Adapter", alias.?);
    try iter.expectEnd();
}

test "signature allocation failure does not consume the value" {
    const message = try newMessage();
    defer c.dbus_message_unref(message);
    var writer: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &writer);
    try append(&writer, c.DBUS_TYPE_UINT32, @as(u32, 1));
    var iter = dbus.Iter.init(message);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, iter.signatureAlloc(failing.allocator()));
    try testing.expectEqual(@as(u32, 1), try iter.read(u32));
}

const posix = struct {
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn write(fd: c_int, bytes: [*]const u8, len: usize) isize;
    extern "c" fn read(fd: c_int, bytes: [*]u8, len: usize) isize;
};

test "UnixFd is an owned duplicate that outlives its message" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), posix.pipe(&fds));
    defer _ = posix.close(fds[0]);
    defer _ = posix.close(fds[1]);
    const owned = blk: {
        const message = try newMessage();
        defer c.dbus_message_unref(message);
        var writer: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(message, &writer);
        try append(&writer, c.DBUS_TYPE_UNIX_FD, fds[0]);
        var iter = dbus.Iter.init(message);
        try testing.expectError(error.TypeMismatch, iter.read(i32));
        const fd = try iter.read(dbus.UnixFd);
        errdefer _ = posix.close(fd.fd);
        try testing.expect(fd.fd != fds[0]);
        try iter.expectEnd();
        break :blk fd;
    };
    defer _ = posix.close(owned.fd);
    try testing.expectEqual(@as(isize, 1), posix.write(fds[1], "x", 1));
    var byte: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 1), posix.read(owned.fd, &byte, 1));
    try testing.expectEqual(@as(u8, 'x'), byte[0]);
}
