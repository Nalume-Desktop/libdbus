const std = @import("std");
const t = std.testing;
const d = @import("libdbus");
const c = d.c;
const Driver = @import("poll_driver");
const example = @import("networkmanager.zig");
const nm = example.protocol;
const device_path = nm.root ++ "/Devices/1";
const ap_path = nm.root ++ "/AccessPoint/1";

fn connect(io: std.Io) !d.Connection {
    var detail = try d.Error.init();
    defer detail.deinit();
    return d.Connection.connect(io, .session, &detail);
}
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
fn encodeProperties(message: *d.Message, interface: []const u8, strength: u8) !void {
    var writer = message.writer();
    defer writer.deinit();
    var array: d.Writer = undefined;
    try writer.open(.array, "{sv}", &array);
    defer array.deinit();
    // An unknown property must not prevent decoding recognized properties.
    try put(&array, "FutureProperty", "s", d.String{ .bytes = "ignore me" });
    if (std.mem.eql(u8, interface, nm.service)) {
        try put(&array, "State", "u", @as(u32, 70));
    } else if (std.mem.eql(u8, interface, nm.device_interface)) {
        try put(&array, "Interface", "s", d.String{ .bytes = "wlan-test" });
        try put(&array, "DeviceType", "u", @as(u32, 2));
        try put(&array, "State", "u", @as(u32, 100));
        try put(&array, "ActiveConnection", "o", d.ObjectPath{ .bytes = "/" });
    } else if (std.mem.eql(u8, interface, nm.ap_interface)) {
        try put(&array, "Strength", "y", strength);
        try put(&array, "Flags", "u", @as(u32, 1));
        try put(&array, "WpaFlags", "u", @as(u32, 0));
        try put(&array, "RsnFlags", "u", @as(u32, 256));
        var entry: d.Writer = undefined;
        try array.open(.dict_entry, null, &entry);
        defer entry.deinit();
        try entry.write(d.String{ .bytes = "Ssid" });
        var variant: d.Writer = undefined;
        try entry.open(.variant, "ay", &variant);
        defer variant.deinit();
        try variant.writeBytes(&.{ 'A', 0, 255, 27, '"', 92 });
        try variant.close();
        try entry.close();
    }
    try array.close();
    try writer.finish();
}
fn encodePaths(message: *d.Message, paths: []const [:0]const u8) !void {
    var writer = message.writer();
    defer writer.deinit();
    var array: d.Writer = undefined;
    try writer.open(.array, "o", &array);
    defer array.deinit();
    for (paths) |path| try array.write(d.ObjectPath{ .bytes = path });
    try array.close();
    try writer.finish();
}

test "NetworkManager codecs preserve bytes, skip unknown properties and reject mismatched types" {
    var message = try d.Message.signal(nm.root, nm.service, "Fixture");
    defer message.deinit();
    try encodeProperties(&message, nm.ap_interface, 70);
    var props = try d.Properties.init(&message);
    defer props.deinit();
    const ap = try nm.AccessPoint.decode(&props);
    try t.expectEqual(@as(u8, 70), ap.strength);
    try t.expectEqualSlices(u8, &.{ 'A', 0, 255, 27, '"', 92 }, ap.ssid);
    try t.expectError(error.TypeMismatch, props.get(u32, "Strength"));
    try t.expectError(error.MissingProperty, props.value("Missing"));
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try nm.quoted(&out.writer, ap.ssid);
    try t.expectEqualStrings("\"A\\x00\\xff\\x1b\\x22\\x5c\"", out.written());
    var empty = try d.Message.signal(nm.root, nm.service, "Fixture");
    defer empty.deinit();
    try encodePaths(&empty, &.{});
    const paths = try nm.paths(&empty);
    try t.expectEqual(null, paths.peek());
    try t.expectError(error.InvalidReply, nm.paths(&message));
}

const Fixture = struct {
    connection: *d.Connection,
    driver: *Driver,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    command: std.atomic.Value(u8) = .init(0),
    inject_change: std.atomic.Value(bool) = .init(false),
    strength: u8 = 70,
    fn name(self: *Fixture, acquire: bool) !void {
        var detail = try d.Error.init();
        defer detail.deinit();
        const result = if (acquire) c.dbus_bus_request_name(self.connection.raw(), nm.service, c.DBUS_NAME_FLAG_DO_NOT_QUEUE, detail.out()) else c.dbus_bus_release_name(self.connection.raw(), nm.service, detail.out());
        if (detail.isSet() or result != 1) return error.NameOwnershipFailed;
    }
    fn changed(self: *Fixture) !void {
        self.strength = 44;
        var signal = try d.Message.signal(ap_path, nm.properties_interface, "PropertiesChanged");
        defer signal.deinit();
        var writer = signal.writer();
        defer writer.deinit();
        try writer.write(d.String{ .bytes = nm.ap_interface });
        var properties: d.Writer = undefined;
        try writer.open(.array, "{sv}", &properties);
        defer properties.deinit();
        try put(&properties, "Strength", "y", self.strength);
        try properties.close();
        var invalidated: d.Writer = undefined;
        try writer.open(.array, "s", &invalidated);
        defer invalidated.deinit();
        try invalidated.write(d.String{ .bytes = "Ssid" });
        try invalidated.close();
        try writer.finish();
        _ = try self.connection.send(&signal);
    }
    fn run(self: *Fixture) void {
        self.loop() catch {
            self.failed.store(true, .release);
        };
    }
    fn loop(self: *Fixture) !void {
        while (!self.stop.load(.acquire)) {
            switch (self.command.swap(0, .acq_rel)) {
                1 => try self.changed(),
                2 => try self.name(false),
                3 => try self.name(true),
                else => {},
            }
            try self.driver.step(10);
        }
    }
    fn filter(_: ?*c.DBusConnection, raw: ?*c.DBusMessage, data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
        const self: *Fixture = @ptrCast(@alignCast(data.?));
        var request = d.Message.fromBorrowed(raw.?);
        defer request.deinit();
        if (request.kind() != .method_call) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        self.respond(&request) catch {
            self.failed.store(true, .release);
        };
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
    fn respond(self: *Fixture, request: *d.Message) !void {
        var reply = try d.Message.methodReturn(request);
        defer reply.deinit();
        const member = request.member() orelse "";
        if (std.mem.eql(u8, member, "GetDevices")) {
            try encodePaths(&reply, &.{ device_path, nm.root ++ "/Devices/vanished" });
        } else if (std.mem.eql(u8, member, "GetAllAccessPoints")) {
            try encodePaths(&reply, &.{ap_path});
        } else if (std.mem.eql(u8, member, "GetAll")) {
            if (std.mem.endsWith(u8, request.path().?, "/vanished")) {
                reply.deinit();
                reply = try d.Message.errorReply(request, "org.freedesktop.DBus.Error.UnknownObject", "removed");
            } else {
                var body = request.iter();
                const interface = try body.read(d.String);
                try encodeProperties(&reply, interface.bytes, self.strength);
                if (self.inject_change.swap(false, .acq_rel)) try self.changed();
            }
        } else if (std.mem.eql(u8, member, "Get")) {
            var body = request.iter();
            _ = try body.read(d.String);
            const property_name = (try body.read(d.String)).bytes;
            try body.expectEnd();
            if (std.mem.eql(u8, property_name, "Missing")) {
                reply.deinit();
                reply = try d.Message.errorReply(request, "org.freedesktop.DBus.Error.UnknownProperty", "missing property");
            } else {
                var writer = reply.writer();
                defer writer.deinit();
                if (std.mem.eql(u8, property_name, "Malformed")) {
                    try writer.write(@as(u32, 7));
                } else {
                    const signature: [:0]const u8 = if (std.mem.eql(u8, property_name, "Interface")) "s" else if (std.mem.eql(u8, property_name, "Ssid")) "ay" else "u";
                    var variant: d.Writer = undefined;
                    try writer.open(.variant, signature, &variant);
                    defer variant.deinit();
                    if (std.mem.eql(u8, signature, "s")) try variant.write(d.String{ .bytes = "wlan-test" }) else if (std.mem.eql(u8, signature, "ay")) try variant.writeBytes(&.{ 0, 255, 65 }) else try variant.write(@as(u32, 100));
                    try variant.close();
                }
                try writer.finish();
            }
        } else return error.UnexpectedMethod;
        _ = try self.connection.send(&reply);
    }
};
fn waitChange(driver: *Driver, monitor: *example.Monitor, before: u64) !void {
    const deadline = driver.now() + 3000;
    while (monitor.revision == before) {
        const remaining = deadline - driver.now();
        if (remaining <= 0) return error.SignalNotReceived;
        try driver.step(@intCast(remaining));
    }
}

test "private NetworkManager fixture: signals, snapshot race, vanished objects and name loss/reappearance" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    const io = backend.io();
    var server = try connect(io);
    defer server.deinit();
    var server_driver: Driver = .{ .connection = &server, .clock_io = io };
    var fixture: Fixture = .{ .connection = &server, .driver = &server_driver };
    try fixture.name(true);
    try server_driver.attach();
    defer server_driver.detach();
    try t.expect(c.dbus_connection_add_filter(server.raw(), Fixture.filter, &fixture, null) != 0);
    defer c.dbus_connection_remove_filter(server.raw(), Fixture.filter, &fixture);
    const thread = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    defer {
        fixture.stop.store(true, .release);
        thread.join();
    }
    var driver: Driver = undefined;
    var waits: Driver.WaitIo = .{ .driver = &driver };
    var connection = try connect(waits.io());
    defer connection.deinit();
    driver = .{ .connection = &connection, .clock_io = io };
    try driver.attach();
    defer driver.detach();
    var monitor: example.Monitor = .{ .connection = &connection };
    try monitor.subscribe(t.allocator);
    defer monitor.unsubscribe();
    const remote = try d.Remote.init(&connection, .{ .destination = nm.service, .path = device_path, .interface = nm.device_interface });
    var detail: d.RemoteError = .{};
    defer detail.deinit();
    try t.expectError(error.RemoteError, remote.getProperty("Missing", .{ .remote_error = &detail }));
    try t.expectEqualStrings("org.freedesktop.DBus.Error.UnknownProperty", detail.name().?);
    try t.expectEqualStrings("missing property", detail.text().?);
    try t.expectEqual(@as(u32, 100), try remote.getScalar(u32, "State", .{ .remote_error = &detail }));
    try t.expectEqual(null, detail.reply);
    const iface = try remote.getStringAlloc(t.allocator, "Interface", .{});
    defer t.allocator.free(iface);
    try t.expectEqualStrings("wlan-test", iface);
    const bytes = try remote.getBytesAlloc(t.allocator, "Ssid", .{});
    defer t.allocator.free(bytes);
    try t.expectEqualSlices(u8, &.{ 0, 255, 65 }, bytes);
    try t.expectError(error.TypeMismatch, remote.getScalar(u32, "Interface", .{}));
    try t.expectError(error.InvalidReply, remote.getProperty("Malformed", .{}));
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    try t.expect(try monitor.snapshot(&output.writer));
    try t.expect(std.mem.indexOf(u8, output.written(), "strength=70%") != null);
    try t.expect(std.mem.indexOf(u8, output.written(), "disappeared during query") != null);
    const before = monitor.revision;
    fixture.command.store(1, .release);
    try waitChange(&driver, &monitor, before); // Must work after snapshot's reply was freed.
    var changed: std.Io.Writer.Allocating = .init(t.allocator);
    defer changed.deinit();
    try t.expect(try monitor.snapshot(&changed.writer));
    try t.expect(std.mem.indexOf(u8, changed.written(), "strength=44%") != null);
    fixture.inject_change.store(true, .release);
    try t.expect(!try monitor.snapshot(&changed.writer));
    try t.expect(try monitor.snapshot(&changed.writer));
    const before_loss = monitor.revision;
    fixture.command.store(2, .release);
    try waitChange(&driver, &monitor, before_loss);
    var absent: std.Io.Writer.Allocating = .init(t.allocator);
    defer absent.deinit();
    try t.expect(try monitor.snapshot(&absent.writer));
    try t.expect(std.mem.indexOf(u8, absent.written(), "not running") != null);
    const before_return = monitor.revision;
    fixture.command.store(3, .release);
    try waitChange(&driver, &monitor, before_return);
    try t.expect(try monitor.snapshot(&changed.writer));
    try t.expect(!fixture.failed.load(.acquire));
    monitor.unsubscribe();
    try t.expectEqual(null, monitor.subscription.state);
    try t.expectEqual(null, monitor.name_watch.state);
}
