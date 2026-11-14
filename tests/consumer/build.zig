const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("libdbus", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "libdbus", .module = dependency.module("libdbus") }},
    }) });
    b.step("test", "Test dependency from a separate package").dependOn(&b.addRunArtifact(tests).step);
}
