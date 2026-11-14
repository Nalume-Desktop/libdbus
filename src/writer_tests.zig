const std = @import("std");
const t = std.testing;
const d = @import("root.zig");
const c = d.c;
fn message() !*c.DBusMessage {
    return c.dbus_message_new(c.DBUS_MESSAGE_TYPE_METHOD_RETURN) orelse error.OutOfMemory;
}

test "signature validation rejects malformed, embedded NUL and non-single signatures" {
    try (d.Signature{ .bytes = "" }).validate();
    try t.expectError(error.InvalidSignature, (d.Signature{ .bytes = "" }).validateSingle());
    try (d.Signature{ .bytes = "sa{sv}as" }).validate();
    try t.expectError(error.InvalidSignature, (d.Signature{ .bytes = "ss" }).validateSingle());
    inline for (.{ "a", "()", "{sv}", "a{vs}", "a{sss}", "(s", "z", "s\x00u" }) |invalid| {
        try t.expectError(error.InvalidSignature, (d.Signature{ .bytes = invalid }).validate());
    }
    const max: [255:0]u8 = @splat('s');
    try (d.Signature{ .bytes = &max }).validate();
    const over: [256:0]u8 = @splat('s');
    try t.expectError(error.InvalidSignature, (d.Signature{ .bytes = &over }).validate());
}

test "signature traversal uses declared nested types without message data" {
    var iter = try (d.Signature{ .bytes = "a{sv}(ub)" }).iter();
    try t.expectEqual(d.Type.dict_entry, try iter.elementType());
    const text = try iter.signatureAlloc(t.allocator);
    defer t.allocator.free(text);
    try t.expectEqualStrings("a{sv}", text);
    var array = try iter.enter(.array);
    var entry = try array.enter(.dict_entry);
    try t.expectEqual(d.Type.string, entry.peek().?);
    try entry.skip();
    try t.expectError(error.TypeMismatch, entry.enter(.variant));
    try t.expectEqual(d.Type.variant, entry.peek().?);
    try entry.skip();
    try entry.expectEnd();
    try array.expectEnd();
    var fields = try iter.enter(.structure);
    try t.expectEqual(d.Type.uint32, fields.peek().?);
    try fields.skip();
    try t.expectEqual(d.Type.boolean, fields.peek().?);
    try fields.skip();
    try fields.expectEnd();
    try iter.expectEnd();
    try t.expectError(error.EndOfSignature, iter.skip());
    var empty = try (d.Signature{ .bytes = "" }).iter();
    try empty.expectEnd();
    try t.expectError(error.EndOfSignature, empty.enter(.array));
}

test "Writer round trips all ordinary scalar types and byte arrays" {
    const msg = try message();
    defer c.dbus_message_unref(msg);
    var writer = d.Writer.init(msg);
    defer writer.deinit();
    const values = .{ @as(u8, 255), true, @as(i16, -3), @as(u16, 4), @as(i32, -5), @as(u32, 6), @as(i64, -7), @as(u64, 8), @as(f64, 9.5) };
    inline for (values) |value| try writer.write(value);
    try writer.write(d.String{ .bytes = "设备" });
    try writer.write(d.ObjectPath{ .bytes = "/org/example" });
    try writer.write(d.Signature{ .bytes = "a{sv}" });
    try writer.writeBytes(&.{ 0, 1, 255 });
    try writer.writeBytes(&.{});
    try writer.finish();
    var iter = d.Iter.init(msg);
    inline for (values) |value| try t.expectEqual(value, try iter.read(@TypeOf(value)));
    try t.expectEqualStrings("设备", (try iter.read(d.String)).bytes);
    try t.expectEqualStrings("/org/example", (try iter.read(d.ObjectPath)).bytes);
    try t.expectEqualStrings("a{sv}", (try iter.read(d.Signature)).bytes);
    try t.expectEqualSlices(u8, &.{ 0, 1, 255 }, try iter.readBytes());
    try t.expectEqual(@as(usize, 0), (try iter.readBytes()).len);
    try iter.expectEnd();
    try t.expectError(error.ClosedWriter, writer.write(@as(u32, 0)));
}

test "nested dictionary variant struct and empty array round trip" {
    const msg = try message();
    defer c.dbus_message_unref(msg);
    var writer = d.Writer.init(msg);
    defer writer.deinit();
    var array: d.Writer = undefined;
    try writer.open(.array, "{sv}", &array);
    var entry: d.Writer = undefined;
    try array.open(.dict_entry, null, &entry);
    try entry.write(d.String{ .bytes = "Device" });
    var variant: d.Writer = undefined;
    try entry.open(.variant, "(sub)", &variant);
    var fields: d.Writer = undefined;
    try variant.open(.structure, null, &fields);
    try fields.write(d.String{ .bytes = "Adapter" });
    try fields.write(@as(u32, 42));
    try fields.write(true);
    try fields.close();
    try variant.close();
    try entry.close();
    try array.close();
    try writer.open(.array, "{oa{sv}}", &array);
    try array.close();
    try writer.finish();
    try t.expectEqualStrings("a{sv}a{oa{sv}}", std.mem.span(c.dbus_message_get_signature(msg)));
    var iter = d.Iter.init(msg);
    var items = try iter.enter(.array);
    var pair = try items.enter(.dict_entry);
    try t.expectEqualStrings("Device", (try pair.read(d.String)).bytes);
    var inner = try pair.enter(.variant);
    var result = try inner.enter(.structure);
    try t.expectEqualStrings("Adapter", (try result.read(d.String)).bytes);
    try t.expectEqual(@as(u32, 42), try result.read(u32));
    try t.expect(try result.read(bool));
    try result.expectEnd();
    try inner.expectEnd();
    try pair.expectEnd();
    try items.expectEnd();
    var empty = try iter.enter(.array);
    try empty.expectEnd();
    try iter.expectEnd();
}

test "Writer rejects invalid input before mutation and allows correction" {
    const msg = try message();
    defer c.dbus_message_unref(msg);
    var writer = d.Writer.init(msg);
    defer writer.deinit();
    try t.expectError(error.InvalidString, writer.write(d.String{ .bytes = "x\x00y" }));
    try t.expectError(error.InvalidString, writer.write(d.String{ .bytes = "\xff" }));
    try t.expectError(error.InvalidObjectPath, writer.write(d.ObjectPath{ .bytes = "relative" }));
    try t.expectError(error.InvalidSignature, writer.write(d.Signature{ .bytes = "()" }));
    try t.expectError(error.InvalidFileDescriptor, writer.write(d.UnixFd{ .fd = -1 }));
    var child: d.Writer = undefined;
    try t.expectError(error.InvalidSignature, writer.open(.array, "ss", &child));
    try t.expectError(error.InvalidSignature, writer.open(.variant, "", &child));
    try t.expectError(error.InvalidContainer, writer.open(.dict_entry, null, &child));
    try writer.open(.variant, "(ub)", &child);
    try t.expectError(error.ActiveChild, writer.write(@as(u32, 1)));
    try t.expectError(error.ActiveChild, writer.finish());
    try t.expectError(error.IncompleteContainer, child.close());
    var fields: d.Writer = undefined;
    try t.expectError(error.TypeMismatch, child.write(true));
    try child.open(.structure, null, &fields);
    try t.expectError(error.TypeMismatch, fields.write(true));
    try fields.write(@as(u32, 1));
    try t.expectError(error.IncompleteContainer, fields.close());
    try fields.write(true);
    try t.expectError(error.TypeMismatch, fields.write(true));
    try fields.close();
    try child.close();
    child.abandon(); // cleanup after close is harmless
    try writer.finish();
    try t.expectEqualStrings("v", std.mem.span(c.dbus_message_get_signature(msg)));
}

test "array element validation and recursive abandon poison the writer" {
    const msg = try message();
    defer c.dbus_message_unref(msg);
    var writer = d.Writer.init(msg);
    defer writer.deinit();
    var array: d.Writer = undefined;
    try writer.open(.array, "(u)", &array);
    try t.expectError(error.TypeMismatch, array.write(@as(u32, 1)));
    var fields: d.Writer = undefined;
    try array.open(.structure, null, &fields);
    try fields.write(@as(u32, 1));
    array.abandon(); // recursively abandons fields first
    array.abandon();
    fields.abandon();
    try t.expectError(error.FailedWriter, writer.write(true));
    try t.expectError(error.FailedWriter, writer.finish());
    try t.expectError(error.ClosedWriter, fields.close());
}

test "empty struct can be corrected and append preserves existing message signature" {
    const msg = try message();
    defer c.dbus_message_unref(msg);
    var writer = d.Writer.init(msg);
    defer writer.deinit();
    var fields: d.Writer = undefined;
    try writer.open(.structure, null, &fields);
    try t.expectError(error.IncompleteContainer, fields.close());
    try fields.write(@as(u32, 1));
    try fields.close();
    try writer.finish();
    var append = d.Writer.init(msg);
    defer append.deinit();
    try append.write(false);
    try append.finish();
    try t.expectEqualStrings("(u)b", std.mem.span(c.dbus_message_get_signature(msg)));
}

const posix = struct {
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn write(fd: c_int, bytes: [*]const u8, len: usize) isize;
    extern "c" fn read(fd: c_int, bytes: [*]u8, len: usize) isize;
};

test "Writer copies fd and preserves caller ownership" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var fds: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), posix.pipe(&fds));
    defer _ = posix.close(fds[1]);
    var original_open = true;
    defer if (original_open) {
        _ = posix.close(fds[0]);
    };
    const msg = try message();
    defer c.dbus_message_unref(msg);
    var writer = d.Writer.init(msg);
    defer writer.deinit();
    try writer.write(d.UnixFd{ .fd = fds[0] });
    try writer.finish();
    try t.expectEqual(@as(isize, 1), posix.write(fds[1], "a", 1));
    var byte: [1]u8 = undefined;
    try t.expectEqual(@as(isize, 1), posix.read(fds[0], &byte, 1));
    try t.expectEqual(@as(c_int, 0), posix.close(fds[0]));
    original_open = false;
    var iter = d.Iter.init(msg);
    const copied = try iter.read(d.UnixFd);
    defer _ = posix.close(copied.fd);
    try t.expectEqual(@as(isize, 1), posix.write(fds[1], "b", 1));
    try t.expectEqual(@as(isize, 1), posix.read(copied.fd, &byte, 1));
    try t.expectEqual(@as(u8, 'b'), byte[0]);
}

test "signature and Writer enforce length and nesting boundaries" {
    var valid: [33:0]u8 = @splat('a');
    valid[32] = 'u';
    try (d.Signature{ .bytes = &valid }).validateSingle();
    var invalid: [34:0]u8 = @splat('a');
    invalid[33] = 'u';
    try t.expectError(error.InvalidSignature, (d.Signature{ .bytes = &invalid }).validate());
    const msg = try message();
    defer c.dbus_message_unref(msg);
    var writer = d.Writer.init(msg);
    defer writer.deinit();
    for (0..255) |_| try writer.write(true);
    try t.expectError(error.SignatureTooLong, writer.write(true));
    try writer.finish();
    const nested_msg = try message();
    defer c.dbus_message_unref(nested_msg);
    var root = d.Writer.init(nested_msg);
    defer root.deinit();
    var children: [33]d.Writer = undefined;
    var parent = &root;
    for (0..32) |i| {
        try parent.open(.structure, null, &children[i]);
        parent = &children[i];
    }
    try t.expectError(error.NestingTooDeep, parent.open(.structure, null, &children[32]));
    try parent.write(@as(u32, 1));
    var i: usize = 32;
    while (i != 0) {
        i -= 1;
        try children[i].close();
    }
    try root.finish();
    try (d.Signature{ .bytes = std.mem.span(c.dbus_message_get_signature(nested_msg)) }).validateSingle();
}
