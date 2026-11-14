const std = @import("std");
const t = std.testing;
const d = @import("root.zig");
const c = d.c;

fn request() !d.Message {
    var msg = try d.Message.methodCall(.{ .path = "/org/example", .interface = "org.example.Test", .member = "Get" });
    c.dbus_message_set_serial(msg.raw(), 42);
    if (c.dbus_message_set_sender(msg.raw(), ":1.7") == 0) {
        msg.deinit();
        return error.OutOfMemory;
    }
    return msg;
}

test "message constructors expose headers flags and typed body" {
    var msg = try d.Message.methodCall(.{ .destination = "org.example.Service", .path = "/org/example", .interface = "org.example.Test", .member = "Get", .auto_start = false, .no_reply = true, .interactive_authorization = true });
    defer msg.deinit();
    try t.expectEqual(d.Message.Kind.method_call, msg.kind());
    try t.expectEqualStrings("org.example.Service", msg.destination().?);
    try t.expectEqualStrings("/org/example", msg.path().?);
    try t.expectEqualStrings("org.example.Test", msg.interface().?);
    try t.expectEqualStrings("Get", msg.member().?);
    try t.expect(msg.noReply());
    try t.expect(!msg.autoStart());
    try t.expect(msg.interactiveAuthorization());
    try t.expectEqual(null, msg.sender());
    try t.expectEqual(null, msg.errorName());
    try t.expectEqual(null, try msg.toError());
    var writer = msg.writer();
    defer writer.deinit();
    try writer.write(d.String{ .bytes = "argument" });
    try writer.write(@as(u32, 7));
    try writer.finish();
    try t.expectEqualStrings("su", msg.signature().bytes);
    var iter = msg.iter();
    try t.expectEqualStrings("argument", (try iter.read(d.String)).bytes);
    try t.expectEqual(@as(u32, 7), try iter.read(u32));
    try iter.expectEnd();
    var signal = try d.Message.signal("/org/example", "org.example.Test", "Changed");
    defer signal.deinit();
    try t.expectEqual(d.Message.Kind.signal, signal.kind());
    try t.expectEqualStrings("Changed", signal.member().?);
}

test "message references transfer and copy have distinct ownership semantics" {
    var original = try request();
    defer original.deinit();
    var retained = original.ref();
    defer retained.deinit();
    var copy = try original.copy();
    defer copy.deinit();
    try t.expectEqual(original.raw(), retained.raw());
    try t.expect(original.raw() != copy.raw());
    try t.expectEqual(@as(u32, 0), copy.serial());
    original.deinit();
    original.deinit();
    try t.expectEqual(@as(u32, 42), retained.serial());
    var writer = copy.writer();
    defer writer.deinit();
    try writer.write(true);
    try writer.finish();
    try t.expectEqualStrings("", retained.signature().bytes);
    try t.expectEqualStrings("b", copy.signature().bytes);
    const transferred = retained.release();
    var adopted = d.Message.adopt(transferred);
    defer adopted.deinit();
    var from_borrowed = d.Message.fromBorrowed(adopted.raw());
    defer from_borrowed.deinit();
    adopted.deinit();
    try t.expectEqualStrings("Get", from_borrowed.member().?);
}

test "replies preserve serial destination and remote error details" {
    var call = try request();
    defer call.deinit();
    var reply = try d.Message.methodReturn(&call);
    defer reply.deinit();
    try t.expectEqual(d.Message.Kind.method_return, reply.kind());
    try t.expectEqual(@as(u32, 42), reply.replySerial());
    try t.expectEqualStrings(":1.7", reply.destination().?);
    var failure = try d.Message.errorReply(&call, "org.example.Denied", "Permission denied: 100%");
    defer failure.deinit();
    try t.expectEqual(d.Message.Kind.error_reply, failure.kind());
    try t.expectEqual(@as(u32, 42), failure.replySerial());
    try t.expectEqualStrings("org.example.Denied", failure.errorName().?);
    try t.expectEqualStrings("Permission denied: 100%", failure.errorText().?);
    // Nonstandard extra arguments stay available in the actual message body.
    var writer = failure.writer();
    defer writer.deinit();
    try writer.write(@as(u32, 99));
    try writer.finish();
    var body = failure.iter();
    try body.skip();
    try t.expectEqual(@as(u32, 99), try body.read(u32));
    var detail = (try failure.toError()).?;
    defer detail.deinit();
    failure.deinit();
    try t.expect(detail.hasName("org.example.Denied"));
    try t.expectEqualStrings("Permission denied: 100%", detail.text().?);
    var moved = detail.take();
    defer moved.deinit();
    detail.deinit();
    try t.expect(moved.isSet());
    moved.clear();
    try t.expect(!moved.isSet());
    try t.expectEqual(null, moved.name());
    try t.expectEqual(null, moved.text());
    try t.expectEqual(@as(c.dbus_bool_t, 0), c.dbus_validate_path("invalid", moved.out()));
    try t.expect(moved.isSet());
    try t.expect(moved.name() != null);
}

test "constructors reject invalid inputs before invoking asserting C APIs" {
    try t.expectError(error.InvalidPath, d.Message.methodCall(.{ .path = "relative", .member = "Get" }));
    try t.expectError(error.InvalidMember, d.Message.methodCall(.{ .path = "/", .member = "a.b" }));
    try t.expectError(error.InvalidInterface, d.Message.methodCall(.{ .path = "/", .member = "Get", .interface = "invalid" }));
    try t.expectError(error.InvalidDestination, d.Message.methodCall(.{ .path = "/", .member = "Get", .destination = "a\x00.b" }));
    try t.expectError(error.InvalidInterface, d.Message.signal("/", "invalid", "Changed"));
    var call = try d.Message.methodCall(.{ .path = "/", .member = "Get" });
    defer call.deinit();
    try t.expectError(error.MissingSerial, d.Message.methodReturn(&call));
    c.dbus_message_set_serial(call.raw(), 1);
    try t.expectError(error.InvalidErrorName, d.Message.errorReply(&call, "invalid", null));
    try t.expectError(error.InvalidText, d.Message.errorReply(&call, "org.example.Error", "a\x00b"));
    var signal = try d.Message.signal("/", "org.example.Test", "Changed");
    defer signal.deinit();
    try t.expectError(error.InvalidRequest, d.Message.methodReturn(&signal));
    var empty_error = try d.Message.errorReply(&call, "org.example.Error", null);
    defer empty_error.deinit();
    try t.expectEqual(null, empty_error.errorText());
}
