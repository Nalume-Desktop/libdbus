//! Read-only NetworkManager example. Signal callbacks only invalidate snapshots.
const std = @import("std");
const d = @import("libdbus");
const PollDriver = @import("poll_driver");
pub const protocol = @import("nm_protocol.zig");
const nm = protocol;

pub const Monitor = struct {
    connection: *d.Connection,
    revision: u64 = 0,
    owner: ?[:0]const u8 = null, // Points into owner_storage; valid between snapshots.
    owner_storage: [256]u8 = undefined,
    name_watch: d.NameWatch = .{},
    subscription: d.Subscription = .{},

    pub fn subscribe(self: *Monitor, allocator: std.mem.Allocator) !void {
        self.name_watch = try d.NameWatch.init(allocator, self.connection, nm.service, d.NameWatch.handler(self, ownerChanged), .{ .timeout = .{ .milliseconds = 2000 } });
        errdefer self.name_watch.deinit();
        self.subscription = try self.connection.subscribe(allocator, .{
            .sender = .{ .name = nm.service },
            .path_namespace = nm.root,
        }, d.signalHandler(self, changed), .{ .timeout = .{ .milliseconds = 2000 } });
    }
    pub fn unsubscribe(self: *Monitor) void {
        self.subscription.deinit();
        self.name_watch.deinit();
    }
    fn ownerChanged(self: *Monitor, _: d.NameWatch.Change) void {
        self.revision +%= 1;
    }
    fn changed(self: *Monitor, _: *const d.Message) void {
        self.revision +%= 1;
    }
    pub fn invoke(self: *Monitor, destination: [:0]const u8, path: [:0]const u8, interface: [:0]const u8, member: [:0]const u8, argument: ?[:0]const u8) !d.Message {
        const remote = try d.Remote.init(self.connection, .{ .destination = destination, .path = path, .interface = interface });
        var request = try remote.methodCall(member);
        defer request.deinit();
        if (argument) |value| {
            var writer = request.writer();
            defer writer.deinit();
            try writer.write(d.String{ .bytes = value });
            try writer.finish();
        }
        return self.connection.call(&request, .{ .timeout = .{ .milliseconds = 2000 } });
    }
    fn checked(self: *Monitor, destination: [:0]const u8, path: [:0]const u8, interface: [:0]const u8, member: [:0]const u8, argument: ?[:0]const u8) !d.Message {
        var reply = try self.invoke(destination, path, interface, member, argument);
        if (reply.kind() == .error_reply) {
            defer reply.deinit();
            const name = reply.errorName() orelse "unknown";
            if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.UnknownObject") or
                std.mem.eql(u8, name, "org.freedesktop.DBus.Error.UnknownInterface")) return error.ObjectVanished;
            std.debug.print("{s}: {s} ({s})\n", .{ member, name, path });
            return error.RemoteError;
        }
        return reply;
    }
    fn properties(self: *Monitor, owner: [:0]const u8, path: [:0]const u8, interface: [:0]const u8) !d.Properties {
        const remote = try d.Remote.init(self.connection, .{ .destination = owner, .path = path, .interface = interface });
        var detail: d.RemoteError = .{};
        defer detail.deinit();
        return remote.getAllProperties(.{ .timeout = .{ .milliseconds = 2000 }, .remote_error = &detail }) catch |err| {
            const name = detail.name() orelse "";
            if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.UnknownObject") or std.mem.eql(u8, name, "org.freedesktop.DBus.Error.UnknownInterface")) return error.ObjectVanished;
            return err;
        };
    }
    /// Returns false when signals invalidated this best-effort snapshot. Caller discards it.
    /// All calls target one unique owner, so a service restart cannot mix two services.
    pub fn snapshot(self: *Monitor, out: *std.Io.Writer) !bool {
        const before = self.revision;
        const current_owner = self.name_watch.owner() orelse {
            self.owner = null;
            try out.writeAll("NetworkManager is not running; waiting for its bus name.\n");
            return before == self.revision;
        };
        // Freeze the unique destination across calls that can dispatch owner changes.
        @memcpy(self.owner_storage[0..current_owner.len], current_owner);
        self.owner_storage[current_owner.len] = 0;
        const owner = self.owner_storage[0..current_owner.len :0];
        self.owner = owner;
        var general = try self.properties(owner, nm.root, nm.service);
        defer general.deinit();
        try out.print("NetworkManager state={d} owner={s}\n", .{ try general.get(u32, "State"), owner });
        var devices_reply = try self.checked(owner, nm.root, nm.service, "GetDevices", null);
        defer devices_reply.deinit();
        var devices = try nm.paths(&devices_reply);
        while (devices.peek() != null) {
            const path = (try devices.read(d.ObjectPath)).bytes;
            self.printDevice(out, owner, path) catch |err| {
                if (err != error.ObjectVanished) return err;
                try out.print("  device {s}: disappeared during query\n", .{path});
            };
        }
        return before == self.revision;
    }
    fn printDevice(self: *Monitor, out: *std.Io.Writer, owner: [:0]const u8, path: [:0]const u8) !void {
        var reply = try self.properties(owner, path, nm.device_interface);
        defer reply.deinit();
        const device = try nm.Device.decode(&reply);
        try out.writeAll("  device ");
        try nm.quoted(out, device.interface);
        try out.print(" {s}({d}) {s}({d}) path={s} active={s}\n", .{ nm.deviceKind(device.kind), device.kind, nm.deviceState(device.state), device.state, path, device.active });
        if (device.kind != 2) return;
        var aps_reply = try self.checked(owner, path, nm.wireless_interface, "GetAllAccessPoints", null);
        defer aps_reply.deinit();
        var aps = try nm.paths(&aps_reply);
        while (aps.peek() != null) {
            const ap_path = (try aps.read(d.ObjectPath)).bytes;
            var ap_reply = self.properties(owner, ap_path, nm.ap_interface) catch |err| {
                if (err != error.ObjectVanished) return err;
                try out.print("    ap {s}: disappeared during query\n", .{ap_path});
                continue;
            };
            defer ap_reply.deinit();
            const ap = try nm.AccessPoint.decode(&ap_reply);
            try out.writeAll("    ap ssid=");
            try nm.quoted(out, ap.ssid);
            if (ap.ssid.len == 0) try out.writeAll(" (hidden/unknown)");
            try out.print(" strength={d}% flags=0x{x} wpa=0x{x} rsn=0x{x} path={s}\n", .{ ap.strength, ap.flags, ap.wpa, ap.rsn, ap_path });
        }
    }
};

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
            try std.Io.File.stdout().writeStreamingAll(init.io, "nm-monitor [--once] [--seconds N] [--session]\nRead-only system-bus monitor. --session is for isolated fixtures. Ctrl-C exits.\n");
            return;
        } else return error.UnknownArgument;
    }
    var detail = try d.Error.init();
    defer detail.deinit();
    var driver: PollDriver = undefined;
    var waits: PollDriver.WaitIo = .{ .driver = &driver };
    var connection = d.Connection.connect(waits.io(), if (session) .session else .system, &detail) catch |err| {
        std.debug.print("Cannot connect to bus: {s}\n", .{detail.name() orelse "unknown"});
        return err;
    };
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
            refresh_at = driver.now() + 250; // Coalesce bursts; keep dispatching in between.
        }
        if (driver.now() >= end) return;
        const wait: u31 = @intCast(@min(1000, @max(0, @min(end, if (seen == null or seen.? != monitor.revision) refresh_at else end) - driver.now())));
        try driver.step(wait);
    }
}
