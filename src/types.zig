const c = @import("dbus_c");

pub const Type = enum(c_int) {
    byte = c.DBUS_TYPE_BYTE,
    boolean = c.DBUS_TYPE_BOOLEAN,
    int16 = c.DBUS_TYPE_INT16,
    uint16 = c.DBUS_TYPE_UINT16,
    int32 = c.DBUS_TYPE_INT32,
    uint32 = c.DBUS_TYPE_UINT32,
    int64 = c.DBUS_TYPE_INT64,
    uint64 = c.DBUS_TYPE_UINT64,
    double = c.DBUS_TYPE_DOUBLE,
    string = c.DBUS_TYPE_STRING,
    object_path = c.DBUS_TYPE_OBJECT_PATH,
    signature = c.DBUS_TYPE_SIGNATURE,
    unix_fd = c.DBUS_TYPE_UNIX_FD,
    array = c.DBUS_TYPE_ARRAY,
    structure = c.DBUS_TYPE_STRUCT,
    dict_entry = c.DBUS_TYPE_DICT_ENTRY,
    variant = c.DBUS_TYPE_VARIANT,
};

pub const ContainerType = enum(c_int) {
    array = c.DBUS_TYPE_ARRAY,
    structure = c.DBUS_TYPE_STRUCT,
    dict_entry = c.DBUS_TYPE_DICT_ENTRY,
    variant = c.DBUS_TYPE_VARIANT,
};

/// Borrowed, NUL-terminated UTF-8 bytes. Valid while the message is alive and unchanged.
pub const String = struct { bytes: [:0]const u8 };
/// Borrowed object path. Distinct from a D-Bus string even though both contain bytes.
pub const ObjectPath = struct { bytes: [:0]const u8 };
/// Borrowed signature VALUE (type g), not the signature of an iterator's current value.
pub const Signature = @import("Signature.zig");
/// An owned duplicate returned by libdbus. The caller must close fd exactly once.
/// Copying this struct does NOT duplicate the descriptor.
pub const UnixFd = struct { fd: c_int };

pub fn basicType(comptime T: type) Type {
    if (T == u8) return .byte;
    if (T == bool) return .boolean;
    if (T == i16) return .int16;
    if (T == u16) return .uint16;
    if (T == i32) return .int32;
    if (T == u32) return .uint32;
    if (T == i64) return .int64;
    if (T == u64) return .uint64;
    if (T == f64) return .double;
    if (T == String) return .string;
    if (T == ObjectPath) return .object_path;
    if (T == Signature) return .signature;
    if (T == UnixFd) return .unix_fd;
    @compileError("Only D-Bus basic types are supported here; process containers explicitly");
}
