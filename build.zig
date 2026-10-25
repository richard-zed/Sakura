const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("sakura", .{
        .root_source_file = b.path("src/sakura.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The corpus harness reads real files from disk, so it needs the corpus
    // root as an ABSOLUTE path. @src().file is cwd-relative for a bare
    // filename, which silently walked zero files -- a false green.
    //
    // Written with addWriteFiles rather than addOptions: addOptions links a
    // temp file into place, and this filesystem rejects link().
    const opts = b.addWriteFiles();
    const opts_src = opts.add("build_options.zig", b.fmt(
        "pub const corpus_root: []const u8 = \"{s}\";\n",
        .{b.pathFromRoot("test/pngsuite")},
    ));
    const opts_mod = b.createModule(.{ .root_source_file = opts_src });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sakura.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("build_options", opts_mod);

    const corpus_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/corpus_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    corpus_tests.root_module.addImport("build_options", opts_mod);

    // `zig build` COMPILES the tests rather than doing nothing. A module-only
    // package whose default step is empty reports success for a tree that does
    // not compile -- a false green this family of projects has hit before.
    b.default_step.dependOn(&tests.step);

    b.default_step.dependOn(&corpus_tests.step);

    const run_tests = b.addRunArtifact(tests);
    const run_corpus = b.addRunArtifact(corpus_tests);
    const test_step = b.step("test", "Run unit and corpus tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_corpus.step);
}
