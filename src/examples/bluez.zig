//! Read-only BlueZ monitor; all bus progression remains in the external driver.
const std = @import("std");
const d = @import("libdbus");
const Driver = @import("poll_driver");
pub const service = "org.bluez";
pub const adapter = "org.bluez.Adapter1";
pub const device = "org.bluez.Device1";
fn relevant(name: []const u8) bool {
    return std.mem.eql(u8, name, adapter) or std.mem.eql(u8, name, device);
}
pub const Monitor = struct {
    connection: *d.Connection,
    revision: u64 = 0,
    watch: d.NameWatch = .{},
    subscription: d.Subscription = .{},
    pub fn subscribe(self: *Monitor, allocator: std.mem.Allocator) !void {
        self.watch = try d.NameWatch.init(allocator, self.connection, service, d.NameWatch.handler(self, ownerChanged), .{ .timeout = .{ .milliseconds = 2000 } });
        errdefer self.watch.deinit();
        // ObjectManager signals originate at /, whereas property signals use object paths.
        self.subscription = try self.connection.subscribe(allocator, .{ .sender = .{ .name = service }, .path_namespace = "/" }, d.signalHandler(self, changed), .{ .timeout = .{ .milliseconds = 2000 } });
    }
    pub fn unsubscribe(self: *Monitor) void {
        self.subscription.deinit();
        self.watch.deinit();
    }
    fn ownerChanged(self: *Monitor, _: d.NameWatch.Change) void {
        self.revision +%= 1;
    }
    fn changed(self: *Monitor, message: *const d.Message) void {
        const member = message.member() orelse return;
        if (std.mem.eql(u8, member, "PropertiesChanged")) {
            const event = d.PropertiesChanged.init(message) catch return;
            if (relevant(event.interface)) self.revision +%= 1;
        } else if (std.mem.eql(u8, member, "InterfacesAdded")) {
            const event = d.ObjectManager.InterfacesAdded.init(message) catch return;
            var interfaces = event.interfaces.iterator();
            while (interfaces.next() catch return) |entry| {
                if (relevant(entry.name)) {
                    self.revision +%= 1;
                    return;
                }
            }
        } else if (std.mem.eql(u8, member, "InterfacesRemoved")) {
            var event = d.ObjectManager.InterfacesRemoved.init(message) catch return;
            while (event.interfaces.next() catch return) |name| {
                if (relevant(name)) {
                    self.revision +%= 1;
                    return;
                }
            }
        }
    }
    pub fn snapshot(self: *Monitor, out: *std.Io.Writer) !bool {
        const before = self.revision;
        const current = self.watch.owner() orelse {
            try out.writeAll("BlueZ is not running; waiting for its bus name.\n");
            return before == self.revision;
        };
        var storage: [256]u8 = undefined;
        @memcpy(storage[0..current.len], current);
        storage[current.len] = 0;
        const owner = storage[0..current.len :0];
        const remote = try d.Remote.init(self.connection, .{ .destination = owner, .path = "/", .interface = d.ObjectManager.interface });
        var objects = try remote.getManagedObjects(.{ .timeout = .{ .milliseconds = 2000 } });
        defer objects.deinit();
        if (before != self.revision) return false;
        try out.print("BlueZ owner={s}\n", .{owner});
        try render(objects.view(), out);
        return before == self.revision;
    }
};
fn flag(properties: d.PropertyMap, name: []const u8) ![]const u8 {
    const value = try properties.getOptional(bool, name) orelse return "unknown";
    return if (value) "yes" else "no";
}
pub fn quoted(out: *std.Io.Writer, text: []const u8) !void {
    try out.writeByte(34);
    for (text) |byte| {
        if (byte >= 32 and byte <= 126 and byte != 34 and byte != 92) try out.writeByte(byte) else {
            try out.writeByte(92);
            try out.print("x{x:0>2}", .{byte});
        }
    }
    try out.writeByte(34);
}
pub fn render(objects: d.ObjectManager.Objects, out: *std.Io.Writer) !void {
    var entries = objects.iterator();
    var adapters: usize = 0;
    var devices: usize = 0;
    while (try entries.next()) |entry| {
        var interfaces = entry.interfaces.iterator();
        while (try interfaces.next()) |iface| {
            if (!relevant(iface.name)) continue;
            const is_adapter = std.mem.eql(u8, iface.name, adapter);
            if (is_adapter) adapters += 1 else devices += 1;
            try out.print("  {s} path={s} address=", .{ if (is_adapter) "adapter" else "device", entry.path });
            const address = try iface.properties.getOptional(d.String, "Address");
            try quoted(out, if (address) |s| s.bytes else "unknown");
            try out.writeAll(" alias=");
            const alias = try iface.properties.getOptional(d.String, "Alias");
            try quoted(out, if (alias) |s| s.bytes else "unknown");
            if (is_adapter) {
                try out.print(" powered={s} discovering={s}\n", .{ try flag(iface.properties, "Powered"), try flag(iface.properties, "Discovering") });
            } else {
                try out.print(" paired={s} connected={s} trusted={s}", .{ try flag(iface.properties, "Paired"), try flag(iface.properties, "Connected"), try flag(iface.properties, "Trusted") });
                if (try iface.properties.getOptional(i16, "RSSI")) |rssi| try out.print(" rssi={d}", .{rssi});
                try out.writeByte(10);
            }
        }
    }
    try out.print("Adapters: {d}; devices: {d}\n", .{ adapters, devices });
}
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var once = false;
    var session = false;
    var seconds: ?u31 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--once")) once = true else if (std.mem.eql(u8, arg, "--session")) session = true else if (std.mem.eql(u8, arg, "--seconds")) {
            seconds = try std.fmt.parseInt(u31, args.next() orelse return error.MissingDuration, 10);
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "bluez-monitor [--once] [--seconds N] [--session]\nRead-only; no discovery, pairing or connection changes.\n");
            return;
        } else return error.UnknownArgument;
    }
    var detail = try d.Error.init();
    defer detail.deinit();
    var driver: Driver = undefined;
    var waits: Driver.WaitIo = .{ .driver = &driver };
    var connection = try d.Connection.connect(waits.io(), if (session) .session else .system, &detail);
    defer connection.deinit();
    driver = .{ .connection = &connection, .clock_io = init.io };
    try driver.attach();
    defer driver.detach();
    var monitor: Monitor = .{ .connection = &connection };
    try monitor.subscribe(init.gpa);
    defer monitor.unsubscribe();
    const end = if (seconds) |s| driver.now() + @as(i64, s) * 1000 else std.math.maxInt(i64);
    var seen: ?u64 = null;
    var refresh_at: i64 = 0;
    var failures: usize = 0;
    while (true) {
        if (!connection.isConnected()) return error.Disconnected;
        if ((seen == null or seen.? != monitor.revision) and driver.now() >= refresh_at) {
            var output: std.Io.Writer.Allocating = .init(init.gpa);
            defer output.deinit();
            const stable = monitor.snapshot(&output.writer) catch |err| blk: {
                if (err == error.Disconnected or err == error.OutOfMemory) return err;
                std.debug.print("Snapshot failed: {t}; retrying\n", .{err});
                break :blk false;
            };
            if (stable) {
                try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
                seen = monitor.revision;
                failures = 0;
                if (once) return;
            } else {
                failures += 1;
                if (once and failures >= 3) return error.SnapshotUnavailable;
            }
            refresh_at = driver.now() + 250;
        }
        if (driver.now() >= end) return;
        const wait: u31 = @intCast(@min(1000, @max(0, @min(end, if (seen == null or seen.? != monitor.revision) refresh_at else end) - driver.now())));
        try driver.step(wait);
    }
}
