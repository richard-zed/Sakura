//! PNG Suite corpus harness.
//!
//! Walks `test/pngsuite/png/*.png`, decodes each through the public API and
//! compares against the reference RGBA in `test/pngsuite/json/`.
//!
//! The 8-bit references are independent (captured from luna paint). The 16-bit
//! references were emitted by this same decoder, per the corpus README, so they
//! pin regressions rather than prove correctness -- the depth-16 comparison is
//! therefore allowed a one-step tolerance. See PNG_REF16_CAVEAT.

const std = @import("std");
const png = @import("png.zig");
const types = @import("types.zig");

/// Corpus root, injected by build.zig as an ABSOLUTE path.
/// @src().file is cwd-relative for a bare filename, so deriving the path here
/// silently walked zero files. See the build_options stanza in build.zig.
const build_options = @import("build_options");
fn corpusDir() []const u8 {
    return build_options.corpus_root;
}

/// Whether a reference image exists for this fixture. PngSuite's `x*` corpus is
/// corrupted on purpose and ships no reference, so it is an expected skip.
fn hasRef(io: std.Io, name: []const u8) bool {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/json/{s}.json", .{ corpusDir(), name }) catch return false;
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn readRef(gpa: std.mem.Allocator, io: std.Io, name: []const u8, buf: *std.ArrayList(u32)) !void {
    buf.clearRetainingCapacity();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/json/{s}.json", .{ corpusDir(), name });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
    defer gpa.free(text);

    var it = std.mem.tokenizeAny(u8, text, "[], \t\r\n");
    while (it.next()) |tok| {
        const v = try std.fmt.parseInt(u32, tok, 10);
        try buf.append(gpa, v);
    }
}

test "every PNG Suite image with a reference decodes to it" {
    const gpa = std.testing.allocator;
    const t = std.testing.io;

    var alloc_io: std.heap.DebugAllocator(.{}) = .init;
    defer _ = alloc_io.deinit();
    const a = alloc_io.allocator();

    var dir_buf: [512]u8 = undefined;
    const png_path = try std.fmt.bufPrint(&dir_buf, "{s}/png", .{corpusDir()});
    var png_dir = try std.Io.Dir.cwd().openDir(t, png_path, .{ .iterate = true });
    defer png_dir.close(t);

    var ref16 = std.ArrayList(u32).empty;
    defer ref16.deinit(a);

    var checked: usize = 0;
    var exact: usize = 0;
    var near: usize = 0;
    var skipped: usize = 0; // corruption fixtures: no reference image exists
    var broken: usize = 0; // unexpected: must stay zero

    var walker = png_dir.iterate();
    while (try walker.next(t)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".png")) continue;

        const name = entry.name[0 .. entry.name.len - 4];

        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/png/{s}", .{ corpusDir(), entry.name });
        const bytes = std.Io.Dir.cwd().readFileAlloc(t, path, gpa, .limited(8 << 20)) catch |e| {
            std.debug.print("{s}: read failed: {t}\n", .{ name, e });
            broken += 1;
            continue;
        };
        defer gpa.free(bytes);

        readRef(a, t, name, &ref16) catch |e| {
            std.debug.print("{s}: readRef failed: {t}\n", .{ name, e });
            skipped += 1; // corruption fixtures have no reference
            continue;
        };

        const img = png.imageSize(bytes, .rgba8) catch |e| {
            // A corruption fixture with no reference is an expected skip even when
            // the header itself is what fails. Anything else is a real fault.
            if (hasRef(t, name)) {
                std.debug.print("{s}: imageSize failed: {t}\n", .{ name, e });
                broken += 1;
            } else {
                skipped += 1;
            }
            continue;
        };
        const n_px = ref16.items.len / 4;
        if (n_px != @as(usize, img.width) * img.height) {
            std.debug.print("{s}: ref has {d} px, header says {d}x{d}\n", .{ name, n_px, img.width, img.height });
            broken += 1;
            continue;
        }

        const out = try a.alloc(u8, img.byteLen());
        defer a.free(out);
        const scratch_len = try png.scratchSize(bytes, .rgba8);
        const scratch = try a.alloc(u8, scratch_len);
        defer a.free(scratch);

        _ = png.decode(bytes, .rgba8, .strict, out, scratch) catch |e| {
            std.debug.print("{s}: decode failed: {t}\n", .{ name, e });
            return e;
        };

        // 8-bit files must match outright; 16-bit allow one step per channel.
        const tol: u32 = if (is16(name)) 1 else 0;
        var worst: u32 = 0;
        for (0..n_px) |i| {
            for (0..4) |c| {
                const want = if (refIs8(name)) ref16.items[i * 4 + c] else ref16.items[i * 4 + c] >> 8;
                const got: u32 = out[i * 4 + c];
                const d = if (got > want) got - want else want - got;
                if (d > worst) worst = d;
            }
        }
        if (worst > tol) {
            std.debug.print("{s}: worst channel delta {d} exceeds tolerance {d}\n", .{ name, worst, tol });
            return error.ReferenceMismatch;
        }
        checked += 1;
        if (worst == 0) exact += 1 else near += 1;
    }

    std.debug.print(
        "\ncorpus: {d} compared, {d} byte-exact, {d} within tolerance, {d} no-reference, {d} broken\n",
        .{ checked, exact, near, skipped, broken },
    );
    // Pinned, not a floor: a regression that silently drops files must fail here.
    try std.testing.expectEqual(@as(usize, 0), broken);
    try std.testing.expectEqual(@as(usize, 161), checked);
    try std.testing.expectEqual(@as(usize, 14), skipped);
    try std.testing.expectEqual(@as(usize, 161), exact);
}

fn is16(name: []const u8) bool {
    // PngSuite naming: <type>n<colour><depth>, e.g. basn2c16, basi0g08.
    if (name.len < 7) return false;
    if (name[name.len - 2] != '1' or name[name.len - 1] != '6') return false;
    // ...but only when the trailing "16" is the depth field, not part of a name.
    return name[name.len - 3] != '0';
}

fn refIs8(name: []const u8) bool {
    return !is16(name);
}
