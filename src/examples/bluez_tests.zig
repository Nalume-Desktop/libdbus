const std = @import("std");
const t = std.testing;
const d = @import("libdbus");
const Driver = @import("poll_driver");
const example = @import("bluez.zig");
const adapter_path = "/org/bluez/hci0";
const device_path = adapter_path ++ "/dev_00_11_22_33_44_55";
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
fn writeInterface(array: *d.Writer, is_device: bool, connected: bool, powered: bool) !void {
    var entry: d.Writer = undefined;
    try array.open(.dict_entry, null, &entry);
    defer entry.deinit();
    try entry.write(d.String{ .bytes = if (is_device) example.device else example.adapter });
    var props: d.Writer = undefined;
    try entry.open(.array, "{sv}", &props);
    defer props.deinit();
    try put(&props, "Address", "s", d.String{ .bytes = "00:11:22:33:44:55" });
    try put(&props, "Alias", "s", d.String{ .bytes = if (is_device) "Test keyboard" else "Test adapter" });
    if (is_device) {
        try put(&props, "Paired", "b", true);
        try put(&props, "Connected", "b", connected);
        try put(&props, "Trusted", "b", false);
        // RSSI deliberately absent: BlueZ properties may be optional or invalidated.
    } else {
        try put(&props, "Powered", "b", powered);
        try put(&props, "Discovering", "b", false);
    }
    try put(&props, "UnknownFutureProperty", "u", @as(u32, 123));
    try props.close();
    try entry.close();
}
fn writeInterfaces(writer: *d.Writer, is_device: bool, connected: bool, powered: bool, duplicate: bool) !void {
    var interfaces: d.Writer = undefined;
    try writer.open(.array, "{sa{sv}}", &interfaces);
    defer interfaces.deinit();
    try writeInterface(&interfaces, is_device, connected, powered);
    if (duplicate) try writeInterface(&interfaces, is_device, connected, powered);
    try interfaces.close();
}
fn writeObject(array: *d.Writer, is_device: bool, connected: bool, powered: bool, duplicate: bool) !void {
    var object: d.Writer = undefined;
    try array.open(.dict_entry, null, &object);
    defer object.deinit();
    try object.write(d.ObjectPath{ .bytes = if (is_device) device_path else adapter_path });
    try writeInterfaces(&object, is_device, connected, powered, duplicate);
    try object.close();
}
fn objects(message: *d.Message, with_device: bool, connected: bool, powered: bool, duplicate: bool) !void {
    var writer = message.writer();
    defer writer.deinit();
    var array: d.Writer = undefined;
    try writer.open(.array, "{oa{sa{sv}}}", &array);
    defer array.deinit();
    try writeObject(&array, false, connected, powered, duplicate);
    if (with_device) try writeObject(&array, true, connected, powered, false);
    if (duplicate) try writeObject(&array, false, connected, powered, false);
    try array.close();
    try writer.finish();
}
fn propertySignal() !d.Message {
    var message = try d.Message.signal(device_path, "org.freedesktop.DBus.Properties", "PropertiesChanged");
    errdefer message.deinit();
    var writer = message.writer();
    defer writer.deinit();
    try writer.write(d.String{ .bytes = example.device });
    var props: d.Writer = undefined;
    try writer.open(.array, "{sv}", &props);
    defer props.deinit();
    try put(&props, "Connected", "b", false);
    try props.close();
    var names: d.Writer = undefined;
    try writer.open(.array, "s", &names);
    defer names.deinit();
    try names.write(d.String{ .bytes = "RSSI" });
    try names.close();
    try writer.finish();
    return message;
}
test "ObjectManager owns replies, borrows nested values and rejects ambiguous lookup" {
    var message = try d.Message.signal("/", "org.example.Test", "Snapshot");
    defer message.deinit();
    try objects(&message, true, true, true, false);
    var owned = try d.ObjectManager.ManagedObjects.init(&message);
    defer owned.deinit();
    message.deinit();
    const interfaces = (try owned.view().getOptional(device_path)).?;
    const props = (try interfaces.getOptional(example.device)).?;
    try t.expect(try props.get(bool, "Connected"));
    try t.expectEqual(null, try props.getOptional(i16, "RSSI"));
    try t.expectEqual(null, try interfaces.getOptional("org.example.Missing"));
    try t.expectEqual(null, try owned.view().getOptional("/missing"));
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try example.render(owned.view(), &out.writer);
    try t.expect(std.mem.indexOf(u8, out.written(), "Adapters: 1; devices: 1") != null);
    var duplicate = try d.Message.signal("/", "org.example.Test", "Snapshot");
    defer duplicate.deinit();
    try objects(&duplicate, false, false, false, true);
    var ambiguous = try d.ObjectManager.ManagedObjects.init(&duplicate);
    defer ambiguous.deinit();
    try t.expectError(error.DuplicateObject, ambiguous.view().getOptional(adapter_path));
    var cursor = ambiguous.iterator();
    const first = (try cursor.next()).?;
    try t.expectError(error.DuplicateInterface, first.interfaces.getOptional(example.adapter));
}
test "standard signal views preserve invalidations and enforce headers and empty container types" {
    var message = try propertySignal();
    defer message.deinit();
    var changed = try d.PropertiesChanged.init(&message);
    try t.expectEqualStrings(example.device, changed.interface);
    try t.expect(!try changed.changed.get(bool, "Connected"));
    try t.expectEqualStrings("RSSI", (try changed.invalidated.next()).?);
    try t.expectEqual(null, try changed.invalidated.next());
    try t.expectError(error.InvalidSignal, d.ObjectManager.InterfacesAdded.init(&message));
    inline for (.{ "{oa{sa{sv}}}", "{ss}" }) |signature| {
        var empty = try d.Message.signal("/", "org.example.Test", "Snapshot");
        defer empty.deinit();
        var writer = empty.writer();
        defer writer.deinit();
        var array: d.Writer = undefined;
        try writer.open(.array, signature, &array);
        defer array.deinit();
        try array.close();
        try writer.finish();
        if (comptime std.mem.eql(u8, signature, "{ss}")) {
            try t.expectError(error.InvalidReply, d.ObjectManager.ManagedObjects.init(&empty));
        } else {
            var owned = try d.ObjectManager.ManagedObjects.init(&empty);
            defer owned.deinit();
            var cursor = owned.iterator();
            try t.expectEqual(null, try cursor.next());
        }
    }
}
fn connect(io: std.Io) !d.Connection {
    var detail = try d.Error.init();
    defer detail.deinit();
    return d.Connection.connect(io, .session, &detail);
}
const Fixture = struct {
    connection: *d.Connection,
    driver: *Driver,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    command: std.atomic.Value(u8) = .init(0),
    inject_race: std.atomic.Value(bool) = .init(false),
    set_calls: std.atomic.Value(u32) = .init(0),
    with_device: bool = true,
    connected: bool = true,
    powered: bool = true,
    fn name(self: *Fixture, acquire: bool) !void {
        var detail = try d.Error.init();
        defer detail.deinit();
        const result = if (acquire) d.c.dbus_bus_request_name(self.connection.raw(), example.service, d.c.DBUS_NAME_FLAG_DO_NOT_QUEUE, detail.out()) else d.c.dbus_bus_release_name(self.connection.raw(), example.service, detail.out());
        if (detail.isSet() or result != 1) return error.NameOwnershipFailed;
    }
    fn signal(self: *Fixture, action: u8) !void {
        if (action == 1) {
            self.connected = false;
            var message = try propertySignal();
            defer message.deinit();
            _ = try self.connection.send(&message);
            return;
        }
        self.with_device = action == 3;
        var message = try d.Message.signal("/", d.ObjectManager.interface, if (self.with_device) "InterfacesAdded" else "InterfacesRemoved");
        defer message.deinit();
        var writer = message.writer();
        defer writer.deinit();
        try writer.write(d.ObjectPath{ .bytes = device_path });
        if (self.with_device) {
            try writeInterfaces(&writer, true, self.connected, self.powered, false);
        } else {
            var names: d.Writer = undefined;
            try writer.open(.array, "s", &names);
            defer names.deinit();
            try names.write(d.String{ .bytes = example.device });
            try names.close();
        }
        try writer.finish();
        _ = try self.connection.send(&message);
    }
    fn run(self: *Fixture) void {
        self.loop() catch {
            self.failed.store(true, .release);
        };
    }
    fn loop(self: *Fixture) !void {
        while (!self.stop.load(.acquire)) {
            switch (self.command.swap(0, .acq_rel)) {
                1, 2, 3 => |action| try self.signal(action),
                4 => try self.name(false),
                5 => try self.name(true),
                else => {},
            }
            try self.driver.step(10);
        }
    }
    fn filter(_: ?*d.c.DBusConnection, raw: ?*d.c.DBusMessage, data: ?*anyopaque) callconv(.c) d.c.DBusHandlerResult {
        const self: *Fixture = @ptrCast(@alignCast(data.?));
        var request = d.Message.fromBorrowed(raw.?);
        defer request.deinit();
        if (request.kind() != .method_call) return d.c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        self.respond(&request) catch {
            self.failed.store(true, .release);
        };
        return d.c.DBUS_HANDLER_RESULT_HANDLED;
    }
    fn respond(self: *Fixture, request: *d.Message) !void {
        var reply = try d.Message.methodReturn(request);
        defer reply.deinit();
        if (std.mem.eql(u8, request.member() orelse "", "GetManagedObjects")) {
            try t.expectEqualStrings(d.ObjectManager.interface, request.interface().?);
            try t.expectEqualStrings("/", request.path().?);
            try t.expectEqualStrings("", request.signature().bytes);
            try objects(&reply, self.with_device, self.connected, self.powered, false);
            if (self.inject_race.swap(false, .acq_rel)) try self.signal(1);
        } else if (std.mem.eql(u8, request.member() orelse "", "Set")) {
            _ = self.set_calls.fetchAdd(1, .acq_rel);
            try t.expectEqualStrings("org.freedesktop.DBus.Properties", request.interface().?);
            try t.expectEqualStrings("ssv", request.signature().bytes);
            var body = request.iter();
            try t.expectEqualStrings(example.adapter, (try body.read(d.String)).bytes);
            const property_name = (try body.read(d.String)).bytes;
            const value = try (try body.value()).unwrapVariant();
            if (std.mem.eql(u8, property_name, "Denied")) {
                reply.deinit();
                reply = try d.Message.errorReply(request, "org.bluez.Error.NotAuthorized", "denied by fixture");
            } else if (std.mem.eql(u8, property_name, "Labels")) {
                try t.expect(try value.hasSignature("as"));
                var labels = try value.enter(.array);
                try t.expectEqualStrings("explicit", (try labels.read(d.String)).bytes);
                try labels.expectEnd();
            } else {
                self.powered = try value.as(bool);
                if (std.mem.eql(u8, property_name, "Malformed")) {
                    var writer = reply.writer();
                    defer writer.deinit();
                    try writer.write(@as(u32, 1));
                    try writer.finish();
                }
            }
        } else return error.UnexpectedMethod;
        _ = try self.connection.send(&reply);
    }
};
fn encodeBool(value: bool, writer: *d.Writer) !void {
    try writer.write(value);
}
fn encodeLabels(_: void, writer: *d.Writer) !void {
    var array: d.Writer = undefined;
    try writer.open(.array, "s", &array);
    defer array.deinit();
    try array.write(d.String{ .bytes = "explicit" });
    try array.close();
}
fn encodeFailure(_: void, writer: *d.Writer) !void {
    try writer.write(false);
    return error.EncodeFailed;
}
fn expectSnapshot(monitor: *example.Monitor, text: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try t.expect(try monitor.snapshot(&out.writer));
    try t.expect(std.mem.indexOf(u8, out.written(), text) != null);
}
fn waitChange(driver: *Driver, monitor: *example.Monitor, before: u64) !void {
    const deadline = driver.now() + 3000;
    while (before == monitor.revision) {
        if (driver.now() >= deadline) return error.SignalTimedOut;
        try driver.step(10);
    }
}
test "isolated BlueZ lifecycle, explicit Set codecs, remote errors and snapshot races" {
    var backend = std.Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var server = try connect(backend.io());
    defer server.deinit();
    var server_driver: Driver = .{ .connection = &server, .clock_io = backend.io() };
    var fixture: Fixture = .{ .connection = &server, .driver = &server_driver };
    try fixture.name(true);
    try server_driver.attach();
    defer server_driver.detach();
    try t.expect(d.c.dbus_connection_add_filter(server.raw(), Fixture.filter, &fixture, null) != 0);
    defer d.c.dbus_connection_remove_filter(server.raw(), Fixture.filter, &fixture);
    const thread = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    defer {
        fixture.stop.store(true, .release);
        thread.join();
    }
    var driver: Driver = undefined;
    var waits: Driver.WaitIo = .{ .driver = &driver };
    var connection = try connect(waits.io());
    defer connection.deinit();
    driver = .{ .connection = &connection, .clock_io = backend.io() };
    try driver.attach();
    defer driver.detach();
    var monitor: example.Monitor = .{ .connection = &connection };
    try monitor.subscribe(t.allocator);
    defer monitor.unsubscribe();
    try expectSnapshot(&monitor, "Adapters: 1; devices: 1");
    const remote = try d.Remote.init(&connection, .{ .destination = example.service, .path = adapter_path, .interface = example.adapter });
    try remote.setProperty("Powered", "b", false, encodeBool, .{});
    try expectSnapshot(&monitor, "powered=no");
    try remote.setProperty("Labels", "as", {}, encodeLabels, .{});
    var detail: d.RemoteError = .{};
    defer detail.deinit();
    try t.expectError(error.RemoteError, remote.setProperty("Denied", "b", true, encodeBool, .{ .remote_error = &detail }));
    try t.expectEqualStrings("org.bluez.Error.NotAuthorized", detail.name().?);
    try t.expectError(error.InvalidReply, remote.setProperty("Malformed", "b", true, encodeBool, .{}));
    const count = fixture.set_calls.load(.acquire);
    try t.expectError(error.EncodeFailed, remote.setProperty("Powered", "b", {}, encodeFailure, .{ .remote_error = &detail }));
    try t.expectEqual(null, detail.reply);
    try expectSnapshot(&monitor, "powered=yes");
    try t.expectEqual(count, fixture.set_calls.load(.acquire));
    const expected = [_][]const u8{ "connected=no", "devices: 0", "devices: 1", "not running", "devices: 1" };
    for (expected, 1..) |text, action| {
        const before = monitor.revision;
        fixture.command.store(@intCast(action), .release);
        try waitChange(&driver, &monitor, before);
        try expectSnapshot(&monitor, text);
    }
    fixture.inject_race.store(true, .release);
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try t.expect(!try monitor.snapshot(&out.writer));
    try expectSnapshot(&monitor, "connected=no");
    try t.expect(!fixture.failed.load(.acquire));
    monitor.unsubscribe();
    try t.expectEqual(null, monitor.subscription.state);
    try t.expectEqual(null, monitor.watch.state);
}
