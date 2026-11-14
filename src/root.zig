//! Typed libdbus messages and Io-aware calls with an independent external driver.
pub const c = @import("dbus_c");
pub const Connection = @import("Connection.zig");
pub const PendingCall = @import("PendingCall.zig");
pub const Driver = @import("Driver.zig");
pub const Message = @import("Message.zig");
pub const Error = @import("Error.zig");
pub const Iter = @import("Iter.zig");
pub const Writer = @import("Writer.zig");
pub const SignatureIter = @import("SignatureIter.zig");
pub const ValueRef = @import("ValueRef.zig");
pub const RetainedValue = ValueRef.RetainedValue;
pub const PropertyMap = @import("PropertyMap.zig");
pub const Properties = @import("Properties.zig");
pub const Property = @import("Property.zig");
pub const Remote = @import("Remote.zig");
pub const RemoteError = @import("RemoteError.zig");
pub const SignalMatch = @import("SignalMatch.zig");
pub const Subscription = @import("Subscription.zig");
pub const signalHandler = Subscription.handler;
pub const NameWatch = @import("NameWatch.zig");
pub const PropertiesChanged = @import("PropertiesChanged.zig");
pub const ObjectManager = @import("ObjectManager.zig");
pub const ObjectRegistration = @import("ObjectRegistration.zig");
pub const methodHandler = ObjectRegistration.handler;
const types = @import("types.zig");
pub const Type = types.Type;
pub const ContainerType = types.ContainerType;
pub const String = types.String;
pub const ObjectPath = types.ObjectPath;
pub const Signature = types.Signature;
pub const UnixFd = types.UnixFd;

test {
    _ = @import("tests.zig");
    _ = @import("writer_tests.zig");
    _ = @import("message_tests.zig");
    _ = @import("client_tests.zig");
}
