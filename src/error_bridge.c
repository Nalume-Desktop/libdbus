#include "dbus.h"

DBusError *zig_dbus_error_new(void) {
    DBusError *error = dbus_malloc(sizeof(*error));
    if (error) dbus_error_init(error);
    return error;
}
void zig_dbus_error_delete(DBusError *error) {
    if (!error) return;
    dbus_error_free(error);
    dbus_free(error);
}
const char *zig_dbus_error_name(const DBusError *error) { return error->name; }
const char *zig_dbus_error_text(const DBusError *error) { return error->message; }
