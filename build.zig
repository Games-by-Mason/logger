const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match the specified filters.",
    ) orelse &.{};

    const logger = b.addModule("logger", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tracy = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
    });
    logger.addImport("tracy", tracy.module("tracy"));

    const unit_tests = b.addTest(.{
        .root_module = logger,
        .filters = test_filters,
    });
    unit_tests.root_module.addImport("tracy", tracy.module("tracy"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
