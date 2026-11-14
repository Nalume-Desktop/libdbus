const std = @import("std");
const t = std.testing;
const d = @import("root.zig");
fn put(array: *d.Writer, name: [:0]const u8, signature: [:0]const u8, value: anytype) !void {
    var entry: d.Writer = undefined;
    try array.open(.dict_entry, null, &entry);
    defer entry.deinit();
    try entry.write(d.String{ .bytes = name });
    var variant: d.Writer = undefined;
    try entry.open(.variant, signature, &variant);
    defer variant.deinit();
    try variant.write(value);
    try variant.close();
    try entry.close();
}
fn properties(duplicate: bool) !d.Message {
    var message = try d.Message.signal("/test", "org.example.Test", "Values");
    errdefer message.deinit();
    var writer = message.writer();
    defer writer.deinit();
    var array: d.Writer = undefined;
    try writer.open(.array, "{sv}", &array);
    defer array.deinit();
    try put(&array, "Text", "s", d.String{ .bytes = "retained text" });
    try put(&array, "Count", "u", @as(u32, 42));
    if (duplicate) try put(&array, "Count", "u", @as(u32, 43));
    try array.close();
    try writer.finish();
    return message;
}
test "properties retain replies and values independently; lookups are strict" {
    var message = try properties(false);
    defer message.deinit();
    var props = try d.Properties.init(&message);
    defer props.deinit();
    message.deinit();
    try t.expectEqual(@as(u32, 42), try props.get(u32, "Count"));
    try t.expectEqual(null, try props.getOptional(u32, "Missing"));
    try t.expectError(error.TypeMismatch, props.getOptional(u32, "Text"));
    try t.expectError(error.MissingProperty, props.get(u32, "Missing"));
    var entries = props.iterator();
    try t.expectEqualStrings("Text", (try entries.next()).?.name);
    try t.expectEqualStrings("Count", (try entries.next()).?.name);
    try t.expectEqual(null, try entries.next());
    var retained = (try props.value("Text")).retain();
    defer retained.deinit();
    props.deinit();
    try t.expectEqualStrings("retained text", (try retained.view().as(d.String)).bytes);
    try t.expectEqualStrings("retained text", (try retained.view().as(d.String)).bytes);
}
test "duplicate property lookup is ambiguous and empty dictionary signature stays strict" {
    var message = try properties(true);
    defer message.deinit();
    var props = try d.Properties.init(&message);
    defer props.deinit();
    try t.expectError(error.DuplicateProperty, props.get(u32, "Count"));
    inline for (.{ "{sv}", "{ss}" }) |signature| {
        var empty = try d.Message.signal("/test", "org.example.Test", "Values");
        defer empty.deinit();
        var writer = empty.writer();
        defer writer.deinit();
        var array: d.Writer = undefined;
        try writer.open(.array, signature, &array);
        defer array.deinit();
        try array.close();
        try writer.finish();
        if (comptime std.mem.eql(u8, signature, "{sv}")) {
            var valid = try d.Properties.init(&empty);
            defer valid.deinit();
            try t.expectEqual(null, try valid.getOptional(u32, "Missing"));
        } else {
            try t.expectError(error.InvalidReply, d.Properties.init(&empty));
            try t.expectError(error.InvalidReply, d.PropertyMap.init(try empty.iter().value()));
        }
    }
}
test "nested variants unwrap one level and value reads never advance original cursor" {
    var message = try d.Message.signal("/test", "org.example.Test", "Values");
    defer message.deinit();
    var writer = message.writer();
    defer writer.deinit();
    var outer: d.Writer = undefined;
    try writer.open(.variant, "v", &outer);
    defer outer.deinit();
    var inner: d.Writer = undefined;
    try outer.open(.variant, "u", &inner);
    defer inner.deinit();
    try inner.write(@as(u32, 99));
    try inner.close();
    try outer.close();
    try writer.finish();
    var property = try d.Property.init(&message);
    defer property.deinit();
    try t.expectEqual(d.Type.variant, property.value().kind());
    try t.expectError(error.TypeMismatch, property.value().as(u32));
    const number = try property.value().unwrapVariant();
    try t.expectEqual(@as(u32, 99), try number.as(u32));
    const signature = try number.signatureAlloc(t.allocator);
    defer t.allocator.free(signature);
    try t.expectEqualStrings("u", signature);
    var cursor = message.iter();
    const first = try cursor.value();
    try t.expectEqual(d.Type.variant, first.kind());
    try t.expectEqual(d.Type.variant, cursor.peek().?);
    _ = try cursor.nextValue();
    try t.expectEqual(null, try cursor.nextValue());
    try t.expectError(error.EndOfMessage, cursor.value());
}
test "byte array value preserves arbitrary bytes after original message is released" {
    var message = try d.Message.signal("/test", "org.example.Test", "Values");
    defer message.deinit();
    var writer = message.writer();
    defer writer.deinit();
    try writer.writeBytes(&.{ 0, 255, 27, 42 });
    try writer.finish();
    var held = (try message.iter().value()).retain();
    defer held.deinit();
    message.deinit();
    try t.expectEqualSlices(u8, &.{ 0, 255, 27, 42 }, try held.view().bytes());
}
test "structured match validates names and namespace boundaries and escapes literal arguments" {
    try t.expectError(error.ConflictingPaths, (d.SignalMatch{ .path = "/a", .path_namespace = "/a" }).validate());
    try t.expectError(error.InvalidUniqueName, (d.SignalMatch{ .sender = .{ .unique = "org.example.Test" } }).validate());
    try t.expectError(error.InvalidWellKnownName, (d.SignalMatch{ .sender = .{ .name = ":1.4" } }).validate());
    var message = try d.Message.signal("/ab", "org.example.Test", "Changed");
    defer message.deinit();
    try t.expect(!(d.SignalMatch{ .path_namespace = "/a" }).matches(&message, null));
    try t.expect((d.SignalMatch{ .path_namespace = "/" }).matches(&message, null));
    var child = try d.Message.signal("/a/b", "org.example.Test", "Changed");
    defer child.deinit();
    try t.expect((d.SignalMatch{ .path_namespace = "/a" }).matches(&child, null));
    const match: d.SignalMatch = .{ .arg0 = "it's\\literal,not=a-rule" };
    const rule = try match.ruleAlloc(t.allocator);
    defer t.allocator.free(rule);
    try t.expect(std.mem.indexOf(u8, rule, "arg0=") != null);
}
