const std = @import("std");
pub fn build(b: *std.Build) void {
    const t = b.standardTargetOptions(.{});
    const o = b.standardOptimizeOption(.{});
    const sak = b.createModule(.{
        .root_source_file = b.path("../src/sakura.zig"),
        .target = t,
        .optimize = o,
    });
    const exe = b.addExecutable(.{
        .name = "rw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("rw.zig"),
            .target = t,
            .optimize = o,
        }),
    });
    exe.root_module.addImport("sakura", sak);
    b.installArtifact(exe);
}
