const std = @import("std");
const d = @import("libdbus");
test "separate package links native bridge and retains encoded data" {
    var detail = try d.Error.init();
    defer detail.deinit();
    try std.testing.expect(!detail.isSet());
    var message = try d.Message.signal("/consumer", "org.example.Consumer", "Data");
    defer message.deinit();
    var writer = message.writer();
    defer writer.deinit();
    try writer.write(d.String{ .bytes = "external consumer" });
    try writer.finish();
    var held = (try message.iter().value()).retain();
    defer held.deinit();
    message.deinit();
    try std.testing.expectEqualStrings("external consumer", (try held.view().as(d.String)).bytes);
}
