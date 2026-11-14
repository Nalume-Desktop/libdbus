#include <dbus/dbus.h>

/* DBusError contains bitfields and is opaque to Zig Translate-C. */
DBusError *zig_dbus_error_new(void);
void zig_dbus_error_delete(DBusError *error);
const char *zig_dbus_error_name(const DBusError *error);
const char *zig_dbus_error_text(const DBusError *error);
