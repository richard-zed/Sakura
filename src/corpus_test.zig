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

/// PngSuite corpus root, injected by build.zig as an ABSOLUTE path.
/// @src().file is cwd-relative for a bare filename, so deriving the path here
/// silently walked zero files. See the build_options stanza in build.zig.
const build_options = @import("build_options");
fn corpusDir() []const u8 {
    return build_options.pngsuite_root;
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
        "\npngsuite: {d} compared, {d} byte-exact, {d} within tolerance, {d} no-reference, {d} fault{s}\n",
        .{ checked, exact, near, skipped, broken, if (broken == 1) "" else "s" },
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

// --- Real-world corpus -------------------------------------------------------
//
// The PngSuite pass above is graded partly by its own output (the 16-bit
// references) and is otherwise synthetic. These seven files are ordinary
// encoders' output, and `expected.txt` carries sha256 of the decoded RGBA8
// that was verified against ImageMagick -- an oracle this decoder did not
// produce. Files are fetched by tools/fetch_corpus.sh, not committed, so a
// missing file is a skip rather than a failure.

const Expect = struct {
    sha: [64]u8,
    bytes: usize,
    w: u32,
    h: u32,
};

fn realworldDir() []const u8 {
    return build_options.realworld_root;
}

/// Parse one `sha  bytes  WxH  ColourType  file` line.
fn parseExpect(line: []const u8) ?struct { name: []const u8, e: Expect } {
    if (line.len == 0 or line[0] == '#') return null;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const sha_tok = it.next() orelse return null;
    const bytes_tok = it.next() orelse return null;
    const geom_tok = it.next() orelse return null;
    _ = it.next() orelse return null; // colour type, informational
    const name = it.next() orelse return null;
    if (sha_tok.len != 64) return null;

    const x = std.mem.indexOfScalar(u8, geom_tok, 'x') orelse return null;
    var e: Expect = .{
        .sha = undefined,
        .bytes = std.fmt.parseInt(usize, bytes_tok, 10) catch return null,
        .w = std.fmt.parseInt(u32, geom_tok[0..x], 10) catch return null,
        .h = std.fmt.parseInt(u32, geom_tok[x + 1 ..], 10) catch return null,
    };
    @memcpy(&e.sha, sha_tok);
    return .{ .name = name, .e = e };
}

test "every real-world corpus file decodes to its ImageMagick-verified hash" {
    const t = std.testing.io;
    var alloc_io: std.heap.DebugAllocator(.{}) = .init;
    defer _ = alloc_io.deinit();
    const a = alloc_io.allocator();

    var path_buf: [512]u8 = undefined;
    const exp_path = try std.fmt.bufPrint(&path_buf, "{s}/expected.txt", .{realworldDir()});
    const text = std.Io.Dir.cwd().readFileAlloc(t, exp_path, a, .limited(1 << 20)) catch |e| {
        std.debug.print("\nrealworld: expected.txt missing ({t}), skipping all\n", .{e});
        return;
    };
    defer a.free(text);

    var checked: usize = 0;
    var absent: usize = 0;
    var faults: usize = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const entry = parseExpect(line) orelse continue;
        const e = entry.e;

        var fbuf: [512]u8 = undefined;
        const fpath = try std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ realworldDir(), entry.name });
        const bytes = std.Io.Dir.cwd().readFileAlloc(t, fpath, a, .limited(64 << 20)) catch {
            absent += 1; // not fetched yet -- a skip, not a fault
            continue;
        };
        defer a.free(bytes);

        const img = png.imageSize(bytes, .rgba8) catch |err| {
            std.debug.print("  {s}: imageSize failed: {t}\n", .{ entry.name, err });
            faults += 1;
            continue;
        };
        if (img.width != e.w or img.height != e.h) {
            std.debug.print("  {s}: geometry {d}x{d}, expected {d}x{d}\n", .{ entry.name, img.width, img.height, e.w, e.h });
            faults += 1;
            continue;
        }

        const out = try a.alloc(u8, img.byteLen());
        defer a.free(out);
        const scratch_len = try png.scratchSize(bytes, .rgba8);
        const scratch = try a.alloc(u8, scratch_len);
        defer a.free(scratch);

        _ = png.decode(bytes, .rgba8, .strict, out, scratch) catch |err| {
            std.debug.print("  {s}: decode failed: {t}\n", .{ entry.name, err });
            faults += 1;
            continue;
        };

        if (out.len != e.bytes) {
            std.debug.print("  {s}: {d} bytes out, expected {d}\n", .{ entry.name, out.len, e.bytes });
            faults += 1;
            continue;
        }

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(out, &digest, .{});
        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;

        if (!std.mem.eql(u8, &hex, &e.sha)) {
            std.debug.print("  {s}: hash mismatch\n    want {s}\n    got  {s}\n", .{ entry.name, e.sha, hex });
            faults += 1;
            continue;
        }
        checked += 1;
    }

    std.debug.print(
        "\nrealworld: {d} matched, {d} absent, {d} fault{s}\n",
        .{ checked, absent, faults, if (faults == 1) "" else "s" },
    );

    try std.testing.expectEqual(@as(usize, 0), faults);

    // Count the reference lines independently of the decode loop. If this
    // disagrees with what was actually compared, files vanished from disk or
    // the loop skipped something it should have graded -- and a corpus that
    // loads nothing must never report success.
    var reference_lines: usize = 0;
    {
        var it = std.mem.tokenizeScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (parseExpect(line) != null) reference_lines += 1;
        }
    }
    if (reference_lines == 0) {
        std.debug.print("\nrealworld: expected.txt lists no reference rows\n", .{});
        return error.NoReferenceRows;
    }
    // These binaries are gitignored (licensing + size) and fetched by
    // tools/fetch_corpus.sh, so a fresh clone legitimately has none of them.
    // Nothing fetched at all means "not downloaded", not "regressed": skip.
    // PARTIAL presence is the dangerous case -- a corpus that is half there
    // must not pass, so only the all-absent case is allowed through.
    if (checked == 0 and absent > 0) {
        std.debug.print("\nrealworld: no files fetched ({d} absent), run tools/fetch_corpus.sh\n", .{absent});
        return;
    }
    // big-4k.png is listed but not downloadable, so it is legitimately absent.
    const expected_present = reference_lines - 1;
    if (checked != expected_present) {
        std.debug.print("\nrealworld: compared {d} of {d} expected rows ({d} absent)\n", .{ checked, expected_present, absent });
        return error.CorpusIncomplete;
    }
}
