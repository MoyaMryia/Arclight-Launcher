const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Regional gate. See README "Regional compliance".
    //
    //   none - no region detection at all (default)
    //   tz   - timezone-only check; development convenience ONLY, not a
    //          compliance measure
    //
    // The author does not distribute binaries and does not provide game
    // downloads to third parties, so the default performs no detection.
    _ = b.option(
        enum { none, tz },
        "region-gate",
        "Region gate for game downloads: none (default) | tz (NOT a compliance measure)",
    ) orelse .none;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "mccli", .root_module = mod });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run mccli");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
