//! Hand-written NetworkManager codecs. All returned slices borrow the reply.
const std = @import("std");
const d = @import("libdbus");
pub const service = "org.freedesktop.NetworkManager";
pub const root = "/org/freedesktop/NetworkManager";
pub const device_interface = service ++ ".Device";
pub const wireless_interface = device_interface ++ ".Wireless";
pub const ap_interface = service ++ ".AccessPoint";
pub const properties_interface = "org.freedesktop.DBus.Properties";

pub fn paths(message: *const d.Message) !d.Iter {
    if (!std.mem.eql(u8, message.signature().bytes, "ao")) return error.InvalidReply;
    var body = message.iter();
    return body.enter(.array);
}
pub const Device = struct {
    interface: [:0]const u8,
    kind: u32,
    state: u32,
    active: [:0]const u8,
    pub fn decode(reply: *const d.Properties) !Device {
        return .{ .interface = (try reply.get(d.String, "Interface")).bytes, .kind = try reply.get(u32, "DeviceType"), .state = try reply.get(u32, "State"), .active = (try reply.get(d.ObjectPath, "ActiveConnection")).bytes };
    }
};
pub const AccessPoint = struct {
    ssid: []const u8,
    strength: u8,
    flags: u32,
    wpa: u32,
    rsn: u32,
    pub fn decode(reply: *const d.Properties) !AccessPoint {
        return .{ .ssid = try reply.getBytes("Ssid"), .strength = try reply.get(u8, "Strength"), .flags = try reply.get(u32, "Flags"), .wpa = try reply.get(u32, "WpaFlags"), .rsn = try reply.get(u32, "RsnFlags") };
    }
};
/// Byte-exact, terminal-safe output. SSIDs need not be UTF-8; hidden SSIDs are empty.
pub fn quoted(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeByte('"');
    for (bytes) |byte| {
        if (byte >= 32 and byte < 127 and byte != '"' and byte != 92) {
            try out.writeByte(byte);
        } else try out.print("\\x{x:0>2}", .{byte});
    }
    try out.writeByte('"');
}
pub fn deviceKind(kind: u32) []const u8 {
    return switch (kind) {
        1 => "ethernet",
        2 => "wifi",
        5 => "bluetooth",
        8 => "modem",
        13 => "bridge",
        32 => "loopback",
        else => "other",
    };
}
pub fn deviceState(state: u32) []const u8 {
    return switch (state) {
        10 => "unmanaged",
        20 => "unavailable",
        30 => "disconnected",
        40...90 => "connecting",
        100 => "activated",
        110 => "deactivating",
        120 => "failed",
        else => "unknown",
    };
}
