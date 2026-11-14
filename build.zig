const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const translated = b.addTranslateC(.{
        .root_source_file = b.path("src/dbus.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translated.linkSystemLibrary("dbus-1", .{ .use_pkg_config = .force, .preferred_link_mode = .dynamic });
    const bindings = translated.createModule();
    const module = b.addModule("libdbus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("dbus_c", bindings);
    module.addCSourceFile(.{ .file = b.path("src/error_bridge.c"), .flags = &.{} });
    module.linkSystemLibrary("dbus-1", .{ .use_pkg_config = .force, .preferred_link_mode = .dynamic });
    const tests = b.addTest(.{ .root_module = module });
    b.default_step.dependOn(&tests.step);
    b.step("test", "Test local messages without a bus").dependOn(&b.addRunArtifact(tests).step);
    const integration = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "libdbus", .module = module }},
    }) });
    const run_integration = b.addSystemCommand(&.{ "dbus-run-session", "--" });
    run_integration.addArtifactArg(integration);
    b.step("test-integration", "Test calls and drivers on a private temporary bus").dependOn(&run_integration.step);
    const poll_driver = b.createModule(.{
        .root_source_file = b.path("src/test_support/PollDriver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "libdbus", .module = module }},
    });
    const example_module = b.createModule(.{
        .root_source_file = b.path("src/examples/networkmanager.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "libdbus", .module = module }, .{ .name = "poll_driver", .module = poll_driver } },
    });
    const monitor = b.addExecutable(.{ .name = "nm-monitor", .root_module = example_module });
    b.step("example-networkmanager", "Build the read-only NetworkManager monitor").dependOn(&b.addInstallArtifact(monitor, .{}).step);
    const run_monitor = b.addRunArtifact(monitor);
    run_monitor.addPassthruArgs();
    b.step("run-networkmanager", "Run the read-only NetworkManager monitor").dependOn(&run_monitor.step);
    const nm_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/examples/networkmanager_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "libdbus", .module = module }, .{ .name = "poll_driver", .module = poll_driver } },
    }) });
    const run_nm_tests = b.addSystemCommand(&.{ "dbus-run-session", "--" });
    run_nm_tests.addArtifactArg(nm_tests);
    b.step("test-networkmanager", "Test NetworkManager codecs and isolated service lifecycle").dependOn(&run_nm_tests.step);
    const bluez_module = b.createModule(.{
        .root_source_file = b.path("src/examples/bluez.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "libdbus", .module = module }, .{ .name = "poll_driver", .module = poll_driver } },
    });
    const bluez = b.addExecutable(.{ .name = "bluez-monitor", .root_module = bluez_module });
    b.step("example-bluez", "Build read-only BlueZ monitor").dependOn(&b.addInstallArtifact(bluez, .{}).step);
    const run_bluez = b.addRunArtifact(bluez);
    run_bluez.addPassthruArgs();
    b.step("run-bluez", "Run read-only BlueZ monitor").dependOn(&run_bluez.step);
    const bluez_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/examples/bluez_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "libdbus", .module = module }, .{ .name = "poll_driver", .module = poll_driver } },
    }) });
    const run_bluez_tests = b.addSystemCommand(&.{ "dbus-run-session", "--" });
    run_bluez_tests.addArtifactArg(bluez_tests);
    b.step("test-bluez", "Test BlueZ and standard protocols on an isolated bus").dependOn(&run_bluez_tests.step);
}
