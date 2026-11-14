//! Explicit ObjectManager views. No recursive allocation, cache or automatic updates.
const std = @import("std");
const Message = @import("Message.zig");
const Iter = @import("Iter.zig");
const ValueRef = @import("ValueRef.zig");
const PropertyMap = @import("PropertyMap.zig");
const types = @import("types.zig");
const signals = @import("PropertiesChanged.zig");
pub const interface = "org.freedesktop.DBus.ObjectManager";
pub const InterfaceMap = struct {
    value_ref: ValueRef,
    pub fn init(value_ref: ValueRef) !InterfaceMap {
        if (!try value_ref.hasSignature("a{sa{sv}}")) return error.InvalidReply;
        return .{ .value_ref = value_ref };
    }
    pub const Entry = struct { name: [:0]const u8, properties: PropertyMap };
    pub const Iterator = struct {
        cursor: Iter,
        pub fn next(self: *Iterator) !?Entry {
            if (self.cursor.peek() == null) return null;
            var entry = try self.cursor.enter(.dict_entry);
            const name = (try entry.read(types.String)).bytes;
            const properties = try PropertyMap.init((try entry.nextValue()).?);
            try entry.expectEnd();
            return .{ .name = name, .properties = properties };
        }
    };
    pub fn iterator(self: InterfaceMap) Iterator {
        return .{ .cursor = self.value_ref.enter(.array) catch unreachable };
    }
    pub fn getOptional(self: InterfaceMap, name: []const u8) !?PropertyMap {
        var entries = self.iterator();
        var found: ?PropertyMap = null;
        while (try entries.next()) |entry| {
            if (!std.mem.eql(u8, name, entry.name)) continue;
            if (found != null) return error.DuplicateInterface;
            found = entry.properties;
        }
        return found;
    }
};
pub const Objects = struct {
    value_ref: ValueRef,
    pub fn init(value_ref: ValueRef) !Objects {
        if (!try value_ref.hasSignature("a{oa{sa{sv}}}")) return error.InvalidReply;
        return .{ .value_ref = value_ref };
    }
    pub const Entry = struct { path: [:0]const u8, interfaces: InterfaceMap };
    pub const Iterator = struct {
        cursor: Iter,
        pub fn next(self: *Iterator) !?Entry {
            if (self.cursor.peek() == null) return null;
            var entry = try self.cursor.enter(.dict_entry);
            const path = (try entry.read(types.ObjectPath)).bytes;
            const interfaces = try InterfaceMap.init((try entry.nextValue()).?);
            try entry.expectEnd();
            return .{ .path = path, .interfaces = interfaces };
        }
    };
    pub fn iterator(self: Objects) Iterator {
        return .{ .cursor = self.value_ref.enter(.array) catch unreachable };
    }
    pub fn getOptional(self: Objects, path: []const u8) !?InterfaceMap {
        var entries = self.iterator();
        var found: ?InterfaceMap = null;
        while (try entries.next()) |entry| {
            if (!std.mem.eql(u8, path, entry.path)) continue;
            if (found != null) return error.DuplicateObject;
            found = entry.interfaces;
        }
        return found;
    }
};
pub const ManagedObjects = struct {
    message: Message,
    objects: Objects,
    pub fn init(message: *const Message) !ManagedObjects {
        if (!std.mem.eql(u8, message.signature().bytes, "a{oa{sa{sv}}}")) return error.InvalidReply;
        const objects = try Objects.init(try message.iter().value());
        return .{ .message = message.ref(), .objects = objects };
    }
    pub fn view(self: *const ManagedObjects) Objects {
        return self.objects;
    }
    pub fn iterator(self: *const ManagedObjects) Objects.Iterator {
        return self.objects.iterator();
    }
    pub fn deinit(self: *ManagedObjects) void {
        self.message.deinit();
    }
};
pub const InterfacesAdded = struct {
    path: [:0]const u8,
    interfaces: InterfaceMap,
    pub fn init(message: *const Message) !InterfacesAdded {
        try signals.checkSignal(message, interface, "InterfacesAdded", "oa{sa{sv}}");
        var body = message.iter();
        const path = (try body.read(types.ObjectPath)).bytes;
        const interfaces = try InterfaceMap.init((try body.nextValue()).?);
        try body.expectEnd();
        return .{ .path = path, .interfaces = interfaces };
    }
};
pub const InterfacesRemoved = struct {
    path: [:0]const u8,
    interfaces: signals.StringList,
    pub fn init(message: *const Message) !InterfacesRemoved {
        try signals.checkSignal(message, interface, "InterfacesRemoved", "oas");
        var body = message.iter();
        const path = (try body.read(types.ObjectPath)).bytes;
        const names = try body.enter(.array);
        try body.expectEnd();
        return .{ .path = path, .interfaces = .{ .cursor = names } };
    }
};
