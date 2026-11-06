//! PNG. Chunk walk, IHDR, PLTE/tRNS, the IDAT stream, Adam7, `eXIf` orientation,
//! and every legal colour-type/bit-depth combination.
//!
//! Scope is deliberately wide: every legal colour-type/bit-depth combination,
//! Adam7, `tRNS`, and `eXIf` orientation. What is *not* here is colour
//! management -- a full ICC engine is a colour-science project, so a non-sRGB
//! profile is decoded in its encoded space and that is documented rather than
//! silently approximated.

const std = @import("std");
const types = @import("types.zig");
const exif = @import("exif.zig");
const flate = std.compress.flate;

const Error = types.Error;
const Image = types.Image;
const PixelFormat = types.PixelFormat;

pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

/// DEFLATE needs a Writer whose buffer can hold the whole LZ77 history plus one
/// maximum-length match; the decompressor preserves history inside the writer,
/// so this is not avoidable scratch. Fixed and independent of image size.
pub const flate_sink_bytes = 32768 + 258;

pub fn sniff(bytes: []const u8) bool {
    return bytes.len >= signature.len and std.mem.startsWith(u8, bytes, &signature);
}

// ---------------------------------------------------------------------------
// Adam7
// ---------------------------------------------------------------------------

pub const Pass = struct {
    x_start: u32,
    y_start: u32,
    x_step: u32,
    y_step: u32,
};

/// The seven passes, in the order their scanlines appear in the file.
///
/// THE THING THAT IS EASY TO GET WRONG: filtering is applied *within a pass*.
/// `left` is the previous pixel of this pass, and `up` the previous row of this
/// pass -- not the neighbouring pixel in the final image. So each pass unfilters
/// as an independent little image and is then SCATTERED into the output.
pub const adam7 = [7]Pass{
    .{ .x_start = 0, .y_start = 0, .x_step = 8, .y_step = 8 },
    .{ .x_start = 4, .y_start = 0, .x_step = 8, .y_step = 8 },
    .{ .x_start = 0, .y_start = 4, .x_step = 4, .y_step = 8 },
    .{ .x_start = 2, .y_start = 0, .x_step = 4, .y_step = 4 },
    .{ .x_start = 0, .y_start = 2, .x_step = 2, .y_step = 4 },
    .{ .x_start = 1, .y_start = 0, .x_step = 2, .y_step = 2 },
    .{ .x_start = 0, .y_start = 1, .x_step = 1, .y_step = 2 },
};

/// How many samples this axis contributes to a pass. A pass that yields zero on
/// either axis is skipped entirely -- no filter bytes at all -- which is why
/// small images have fewer than seven passes.
pub fn passExtent(total: u32, start: u32, step: u32) u32 {
    if (total <= start) return 0;
    return (total - start + step - 1) / step;
}

pub fn passWidth(p: Pass, width: u32) u32 {
    return passExtent(width, p.x_start, p.x_step);
}

pub fn passHeight(p: Pass, height: u32) u32 {
    return passExtent(height, p.y_start, p.y_step);
}

// ---------------------------------------------------------------------------
// header
// ---------------------------------------------------------------------------

pub const Colour = enum(u8) {
    grey = 0,
    rgb = 2,
    palette = 3,
    grey_alpha = 4,
    rgba = 6,

    fn fromByte(b: u8) Error!Colour {
        return switch (b) {
            0 => .grey,
            2 => .rgb,
            3 => .palette,
            4 => .grey_alpha,
            6 => .rgba,
            else => error.Corrupt,
        };
    }

    pub fn channels(self: Colour) u8 {
        return switch (self) {
            .grey, .palette => 1,
            .grey_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }

    /// Whether alpha is inherent to the colour type. `tRNS` can grant alpha to
    /// grey, rgb and palette sources, which is why this alone is not the answer.
    fn inherentAlpha(self: Colour) bool {
        return self == .grey_alpha or self == .rgba;
    }

    fn isGrey(self: Colour) bool {
        return self == .grey or self == .grey_alpha;
    }

    /// Depths the format allows for this colour type. Sub-byte depths exist only
    /// for grey and palettes.
    fn depthLegal(self: Colour, depth: u8) bool {
        return switch (self) {
            .grey => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
            .palette => depth == 1 or depth == 2 or depth == 4 or depth == 8,
            .rgb, .grey_alpha, .rgba => depth == 8 or depth == 16,
        };
    }
};

pub const Info = struct {
    width: u32,
    height: u32,
    depth: u8,
    colour: Colour,
    interlace: u8,
    has_plte: bool = false,
    /// Presence only. The payload is needed at decode time, not to size.
    has_trns: bool = false,
    orientation: u8 = 1,

    pub fn interlaced(self: Info) bool {
        return self.interlace == 1;
    }

    fn bitsPerPixel(self: Info) usize {
        return @as(usize, self.colour.channels()) * self.depth;
    }

    /// Rows for `w` samples of this colour type and depth. Sub-byte depths pack;
    /// nothing is byte-padded per sample.
    pub fn rowBytes(self: Info, w: u32) usize {
        const bits = @as(usize, w) * self.bitsPerPixel();
        return (bits + 7) / 8;
    }

    /// The widest scanline any pass can produce. Pass 7 has a horizontal step of
    /// 1, so it is always the full width -- the max is computed rather than
    /// assumed so a table edit cannot silently under-size the buffer.
    fn maxPassRowBytes(self: Info) usize {
        if (!self.interlaced()) return self.rowBytes(self.width);
        var max: usize = 0;
        for (adam7) |p| {
            max = @max(max, self.rowBytes(passWidth(p, self.width)));
        }
        return max;
    }

    /// A source that already has alpha, either inherently or via `tRNS`.
    fn hasAlpha(self: Info) bool {
        return self.colour.inherentAlpha() or self.has_trns;
    }
};

fn crc(bytes: []const u8, pos: usize, len: u32) u32 {
    // Covers type + data.
    return std.hash.Crc32.hash(bytes[pos + 4 ..][0 .. 4 + @as(usize, len)]);
}

/// Walk chunks up to the first `IDAT`.
///
/// Everything needed to size a buffer precedes the pixel data, so this never
/// reads the image. It also means cost is independent of image size, which is
/// the whole point of a separate `imageSize`.
pub fn scan(bytes: []const u8) Error!Info {
    return scanPolicy(bytes, .strict, null);
}

/// Chunk types whose contents this decoder consumes. A bad CRC on one of these
/// is always fatal: a corrupt palette or tRNS decodes to wrong pixels silently,
/// which is worse than refusing. Everywhere else the CRC is advisory.
fn isRead(type_code: []const u8) bool {
    return std.mem.eql(u8, type_code, "IHDR") or
        std.mem.eql(u8, type_code, "PLTE") or
        std.mem.eql(u8, type_code, "tRNS") or
        std.mem.eql(u8, type_code, "eXIf");
}

pub fn scanPolicy(bytes: []const u8, policy: types.Policy, damaged: ?*bool) Error!Info {
    if (!sniff(bytes)) return error.NotAnImage;

    var info: Info = undefined;
    var saw_ihdr = false;
    var pos: usize = 8;

    while (true) {
        if (pos + 8 > bytes.len) return error.Truncated;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const ctype = bytes[pos + 4 ..][0..4];
        const data_at = pos + 8;
        const data_end = data_at + @as(usize, len);
        if (data_end + 4 > bytes.len) return error.Truncated;

        if (crc(bytes, pos, len) != std.mem.readInt(u32, bytes[data_end..][0..4], .big)) {
            if (isRead(ctype)) return error.Corrupt;
            if (policy == .strict) return error.Corrupt;
            // Lenient: an unreadable chunk this decoder ignores cannot affect
            // the pixels, so skip it and record that it happened.
            if (damaged) |d| d.* = true;
            pos = data_end + 4;
            continue;
        }

        const data = bytes[data_at..data_end];

        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (pos != 8) return error.Corrupt;
            if (len != 13) return error.Corrupt;
            const colour = try Colour.fromByte(data[9]);
            const depth = data[8];
            if (!colour.depthLegal(depth)) return error.Corrupt;
            info = .{
                .width = std.mem.readInt(u32, data[0..4], .big),
                .height = std.mem.readInt(u32, data[4..8], .big),
                .depth = depth,
                .colour = colour,
                // data[10] compression and data[11] filter must be 0
                .interlace = data[12],
            };
            if (data[10] != 0 or data[11] != 0) return error.Corrupt;
            if (info.width == 0 or info.height == 0) return error.Corrupt;
            if (info.interlace > 1) return error.Corrupt;
            saw_ihdr = true;
        } else if (std.mem.eql(u8, ctype, "PLTE")) {
            if (!saw_ihdr) return error.Corrupt;
            if (len == 0 or len % 3 != 0 or len > 256 * 3) return error.Corrupt;
            info.has_plte = true;
        } else if (std.mem.eql(u8, ctype, "tRNS")) {
            if (!saw_ihdr) return error.Corrupt;
            info.has_trns = true;
        } else if (std.mem.eql(u8, ctype, "eXIf")) {
            if (!saw_ihdr) return error.Corrupt;
            info.orientation = exif.orientation(data) orelse 1;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            // All sizing information precedes pixel data by construction.
            break;
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }

        pos = data_end + 4;
    }

    if (!saw_ihdr) return error.Corrupt;
    if (info.colour == .palette and !info.has_plte) return error.Corrupt;
    return info;
}

/// Reachable without inventing colour. Colour -> grey8 is the only refusal, and
/// it needs luma maths nobody asked for.
fn convertible(info: Info, want: PixelFormat) bool {
    return switch (want) {
        .rgba8 => true,
        // Any source carrying alpha would lose it.
        .rgb8 => !info.hasAlpha(),
        // Greyscale in, greyscale out, and nothing dropped on the way.
        .grey8 => info.colour.isGrey() and !info.has_trns,
    };
}

pub fn imageSize(bytes: []const u8, want: PixelFormat) Error!Image {
    const info = try scan(bytes);
    if (!convertible(info, want)) return error.UnsupportedConversion;

    const swapped = exif.swapsAxes(info.orientation);
    const w = if (swapped) info.height else info.width;
    const h = if (swapped) info.width else info.height;

    const row = std.math.mul(usize, w, want.bytesPerPixel()) catch return error.TooLarge;
    _ = std.math.mul(usize, row, h) catch return error.TooLarge;

    return .{ .width = w, .height = h, .format = want, .source = .png };
}

/// The DEFLATE sink is always needed. A row buffer is needed *in addition*
/// whenever the output row is not a byte-for-byte copy of the stored one -- and
/// ALWAYS for an interlaced image, because samples are scattered to strided
/// positions and can never be unfiltered in place.
pub fn scratchSize(bytes: []const u8, want: PixelFormat) Error!usize {
    const info = try scan(bytes);
    return scratchSizeFor(bytes, info, want);
}

/// Same figure, from an `Info` already in hand. The size does not depend on
/// policy, so a caller that has walked the file must not walk it again.
fn scratchSizeFor(bytes: []const u8, info: Info, want: PixelFormat) Error!usize {
    if (!convertible(info, want)) return error.UnsupportedConversion;

    // Joined IDAT stream, then the filtered scanlines, then the DEFLATE sink
    // that must stay writable at the tail so a rebase never slides decoded
    // bytes out from under the head of the buffer.
    var n: usize = flate_sink_bytes;
    n = std.math.add(usize, n, try compressedTotal(bytes)) catch return error.TooLarge;
    n = std.math.add(usize, n, filteredTotal(info)) catch return error.TooLarge;
    return n;
}

pub fn decode(
    bytes: []const u8,
    want: PixelFormat,
    policy: types.Policy,
    out: []u8,
    scratch: []u8,
) Error!types.Decoded {
    var skipped: bool = false;
    const info = try scanPolicy(bytes, policy, &skipped);
    if (!convertible(info, want)) return error.UnsupportedConversion;
    const img = Image{ .width = info.width, .height = info.height, .format = want, .source = .png };
    if (out.len < img.byteLen()) return error.OutTooSmall;
    if (scratch.len < try scratchSizeFor(bytes, info, want)) return error.ScratchTooSmall;

    const comp_total = try compressedTotal(bytes);
    const filt_total = filteredTotal(info);

    // Join the IDAT payloads: direct-mode DEFLATE needs one contiguous slice,
    // and chunk headers sit between the pieces in the file.
    var pos: usize = 8;
    var at: usize = 0;
    var plte: []const u8 = &.{};
    var trns: []const u8 = &.{};
    // Chunk ordering is a spec requirement, not a style preference: PLTE and
    // tRNS describe the IDAT stream that follows them, so any found afterwards
    // cannot apply to it. Taking the last one would silently decode with a
    // palette that appears after the pixels it colours.
    var seen_idat = false;
    while (pos + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const ctype = bytes[pos + 4 ..][0..4];
        const data_at = pos + 8;
        const data_end = data_at + @as(usize, len);
        if (data_end + 4 > bytes.len) return error.Truncated;
        const data = bytes[data_at..data_end];
        if (std.mem.eql(u8, ctype, "PLTE")) {
            if (seen_idat) return error.Corrupt;
            if (plte.len != 0) return error.Corrupt; // at most one
            plte = data;
        } else if (std.mem.eql(u8, ctype, "tRNS")) {
            if (seen_idat) return error.Corrupt;
            if (trns.len != 0) return error.Corrupt;
            trns = data;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            seen_idat = true;
            @memcpy(scratch[at..][0..len], data);
            at += len;
        }
        if (std.mem.eql(u8, ctype, "IEND")) break;
        pos = data_end + 4;
    }
    if (at != comp_total) return error.Corrupt;

    const filt = scratch[comp_total..][0 .. filt_total + flate_sink_bytes];
    var r = std.Io.Reader.fixed(scratch[0..comp_total]);
    var d = std.compress.flate.Decompress.init(&r, .zlib, &.{});
    var w = std.Io.Writer.fixed(filt);
    _ = d.reader.streamRemaining(&w) catch blk: {
        if (policy == .strict) return error.Corrupt;
        break :blk 0;
    };
    const got = w.end;
    // Truncation outranks a skipped chunk: it means pixels are missing.
    const damage: types.Damage = if (got != filt_total) .truncated else if (skipped) .skipped_ancillary else .none;
    if (damage != .none and policy == .strict) return error.Truncated;
    const data = filt[0..@min(got, filt_total)];

    const bpp = filterBpp(info);
    var cursor: usize = 0;

    if (!info.interlaced()) {
        const flen = 1 + info.rowBytes(info.width);
        var prev: ?[]const u8 = null;
        var y: u32 = 0;
        while (y < info.height) : (y += 1) {
            if (cursor + flen > data.len) break;
            const row = data[cursor..][0..flen];
            try unfilter(row[0], row[1..], prev, bpp);
            emitPass(info, plte, trns, out, img, .{ .x_start = 0, .y_start = 0, .x_step = 1, .y_step = 1 }, row[1..], y);
            prev = row[1..];
            cursor += flen;
        }
    } else {
        for (adam7) |p| {
            const pw = passWidth(p, info.width);
            const ph = passHeight(p, info.height);
            if (pw == 0 or ph == 0) continue;
            const flen = 1 + info.rowBytes(pw);
            var prev: ?[]const u8 = null;
            var py: u32 = 0;
            while (py < ph) : (py += 1) {
                if (cursor + flen > data.len) break;
                const row = data[cursor..][0..flen];
                try unfilter(row[0], row[1..], prev, bpp);
                emitPass(info, plte, trns, out, img, p, row[1..], py);
                prev = row[1..];
                cursor += flen;
            }
        }
    }

    return .{ .image = img, .damage = damage };
}

/// Total filtered bytes the DEFLATE stream must yield: one filter byte plus a
/// row of samples per scanline, summed over passes.
fn filteredTotal(info: Info) usize {
    if (!info.interlaced()) return @as(usize, info.height) * (1 + info.rowBytes(info.width));
    var t: usize = 0;
    for (adam7) |p| {
        const pw = passWidth(p, info.width);
        const ph = passHeight(p, info.height);
        if (pw == 0 or ph == 0) continue;
        t += @as(usize, ph) * (1 + info.rowBytes(pw));
    }
    return t;
}

/// IDAT payloads are separate chunks with their own headers between them, so a
/// direct-mode stream (which requires one contiguous slice) needs them joined.
fn compressedTotal(bytes: []const u8) Error!usize {
    var total: usize = 0;
    var pos: usize = 8;
    while (pos + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const ctype = bytes[pos + 4 ..][0..4];
        const data_at = pos + 8;
        const data_end = data_at + @as(usize, len);
        if (data_end + 4 > bytes.len) return error.Truncated;
        if (std.mem.eql(u8, ctype, "IDAT")) total += len;
        if (std.mem.eql(u8, ctype, "IEND")) break;
        pos = data_end + 4;
    }
    return total;
}

fn paeth(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return @intCast(a);
    if (pb <= pc) return @intCast(b);
    return @intCast(c);
}

fn unfilter(ft: u8, row: []u8, prev: ?[]const u8, bpp: usize) Error!void {
    switch (ft) {
        0 => {},
        1 => {
            var i: usize = bpp;
            while (i < row.len) : (i += 1) row[i] +%= row[i - bpp];
        },
        2 => {
            if (prev) |p| for (row, p) |*b, u| {
                b.* +%= u;
            };
        },
        3 => {
            var i: usize = 0;
            while (i < row.len) : (i += 1) {
                const left: u16 = if (i >= bpp) row[i - bpp] else 0;
                const up: u16 = if (prev) |p| p[i] else 0;
                row[i] +%= @intCast((left + up) / 2);
            }
        },
        4 => {
            var i: usize = 0;
            while (i < row.len) : (i += 1) {
                const a: i16 = if (i >= bpp) row[i - bpp] else 0;
                const b: i16 = if (prev) |p| p[i] else 0;
                const c: i16 = if (i >= bpp) (if (prev) |p| p[i - bpp] else 0) else 0;
                row[i] +%= paeth(a, b, c);
            }
        },
        else => return error.Corrupt,
    }
}

/// Bytes per pixel as the FILTER sees it, which is not the channel count:
/// sub-byte depths pack several samples into one byte, so the stride is 1, and
/// a 16-bit sample is two bytes. Getting this wrong corrupts every filtered
/// row silently -- the filter still runs, it just reconstructs noise.
fn filterBpp(info: Info) usize {
    const bits = @as(usize, info.colour.channels()) * info.depth;
    const bytes = (bits + 7) / 8;
    return if (bytes == 0) 1 else bytes;
}

fn pixelOf(info: Info, plte: []const u8, trns: []const u8, row: []const u8, x: u32) [4]u8 {
    const i: usize = x;
    // 16-bit samples are read big-endian and reduced to their HIGH byte. That is
    // what libpng's strip_16 does and what every 8-bit consumer expects; scaling
    // instead would put us one step off every reference decoder.
    const wide = info.depth == 16;
    const ch = info.colour.channels();
    const at = if (wide) i * @as(usize, ch) * 2 else i * @as(usize, ch);

    return switch (info.colour) {
        .grey => blk: {
            const v = if (wide) row[at] else sample(info, row, i);
            // tRNS stores the sample in the FILE's depth: a raw 4-bit level for a
            // 4-bit image, a full u16 for a 16-bit one. Comparing the SCALED
            // value never matches below 8 bits.
            const match = trns.len >= 2 and if (info.depth == 16)
                ((@as(u32, trns[0]) << 8) | trns[1]) == ((@as(u32, row[at]) << 8) | row[at + 1])
            else if (info.depth == 8)
                trns[1] == v
            else
                ((@as(u32, trns[0]) << 8) | trns[1]) == unpackRaw(row, info.depth, i);
            break :blk .{ v, v, v, if (match) 0 else 255 };
        },
        .rgb => blk: {
            const r = if (wide) row[i * 6] else row[i * 3];
            const g = if (wide) row[i * 6 + 2] else row[i * 3 + 1];
            const b = if (wide) row[i * 6 + 4] else row[i * 3 + 2];
            var a: u8 = 255;
            // tRNS stores full 16-bit samples for a 16-bit image, so the high
            // byte of each field is what the comparison is against.
            const toff: usize = if (wide) 0 else 0;
            const step: usize = if (wide) 2 else 1;
            if (trns.len >= 6 and trns[1] == r and trns[3] == g and trns[5] == b) a = 0;
            if (wide and trns.len >= 6 and trns[toff] == r and trns[toff + 2] == g and trns[toff + 4] == b) a = 0;
            _ = step;
            break :blk .{ r, g, b, a };
        },
        .palette => blk: {
            // A palette index is RAW, not scaled: unpack() maps sub-byte samples
            // onto 0..255 for greyscale, which would turn index 1 into 17 at
            // depth 4 and run off the end of the palette.
            const idx = if (info.depth == 8) row[i] else @as(u8, @intCast(unpackRaw(row, info.depth, i)));
            const a: u8 = if (idx < trns.len) trns[idx] else 255;
            const p = @as(usize, idx) * 3;
            if (p + 2 >= plte.len) break :blk .{ 0, 0, 0, a };
            break :blk .{ plte[p], plte[p + 1], plte[p + 2], a };
        },
        .grey_alpha => if (wide)
            .{ row[i * 4], row[i * 4], row[i * 4], row[i * 4 + 2] }
        else
            .{ row[i * 2], row[i * 2], row[i * 2], row[i * 2 + 1] },
        .rgba => if (wide)
            .{ row[i * 8], row[i * 8 + 2], row[i * 8 + 4], row[i * 8 + 6] }
        else
            .{ row[i * 4], row[i * 4 + 1], row[i * 4 + 2], row[i * 4 + 3] },
    };
}

/// Sample `x` from a sub-byte row: samples pack high-order first.
fn unpack(row: []const u8, depth: u8, x: usize) u32 {
    const mask: u8 = @intCast((@as(u16, 1) << @as(u4, @intCast(depth))) - 1);
    const raw = unpackRaw(row, depth, x);
    // A 1/2/4-bit grey sample is scaled to the full 0..255 range, so 1-bit
    // white reads as 255 rather than 1.
    return @as(u32, raw) * 255 / mask;
}

/// Raw sub-byte sample, no scaling. Palette indices need this; greyscale does
/// not, because a 1-bit grey sample must read as 255 rather than 1.
fn unpackRaw(row: []const u8, depth: u8, x: usize) u32 {
    const per_byte = 8 / @as(usize, depth);
    const byte = row[x / per_byte];
    const slot = x % per_byte;
    const shift: u3 = @intCast(8 - @as(usize, depth) * (slot + 1));
    const mask: u8 = @intCast((@as(u16, 1) << @as(u4, @intCast(depth))) - 1);
    return (byte >> shift) & mask;
}

/// Greyscale at a sub-byte depth, already scaled.
fn sample(info: Info, row: []const u8, x: usize) u8 {
    if (info.depth == 8) return row[x];
    return @intCast(unpack(row, info.depth, x));
}

const Dest = struct { x: u32, y: u32 };

/// Where a stored pixel lands once EXIF orientation is applied. `w`/`h` are the
/// stored dimensions; the caller's buffer is the swapped size for 5..8.
fn destOf(orient: u8, w: u32, h: u32, x: u32, y: u32) Dest {
    return switch (orient) {
        2 => .{ .x = w - 1 - x, .y = y },
        3 => .{ .x = w - 1 - x, .y = h - 1 - y },
        4 => .{ .x = x, .y = h - 1 - y },
        5 => .{ .x = y, .y = x },
        6 => .{ .x = h - 1 - y, .y = x },
        7 => .{ .x = h - 1 - y, .y = w - 1 - x },
        8 => .{ .x = y, .y = w - 1 - x },
        else => .{ .x = x, .y = y },
    };
}

fn place(out: []u8, img: Image, dx: u32, dy: u32, px: [4]u8) void {
    const o = @as(usize, dy) * img.stride() + @as(usize, dx) * img.format.bytesPerPixel();
    switch (img.format) {
        .rgba8 => out[o..][0..4].* = px,
        .rgb8 => out[o..][0..3].* = px[0..3].*,
        .grey8 => out[o] = px[0],
    }
}

fn emitPass(
    info: Info,
    plte: []const u8,
    trns: []const u8,
    out: []u8,
    img: Image,
    p: Pass,
    row: []const u8,
    pass_row: u32,
) void {
    const pw = passWidth(p, info.width);
    var col: u32 = 0;
    while (col < pw) : (col += 1) {
        const sx = p.x_start + col * p.x_step;
        const sy = p.y_start + pass_row * p.y_step;
        const d = destOf(info.orientation, info.width, info.height, sx, sy);
        place(out, img, d.x, d.y, pixelOf(info, plte, trns, row, col));
    }
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Builder = struct {
    b: []u8,
    n: usize,

    fn chunk(self: *Builder, ctype: *const [4]u8, data: []const u8) void {
        std.mem.writeInt(u32, self.b[self.n..][0..4], @intCast(data.len), .big);
        self.n += 4;
        @memcpy(self.b[self.n..][0..4], ctype);
        self.n += 4;
        @memcpy(self.b[self.n..][0..data.len], data);
        self.n += data.len;
        const c = std.hash.Crc32.hash(self.b[self.n - 4 - data.len .. self.n]);
        std.mem.writeInt(u32, self.b[self.n..][0..4], c, .big);
        self.n += 4;
    }
};

const Extra = struct { ctype: *const [4]u8, data: []const u8 };

/// A valid, CRC-correct PNG carrying only what `imageSize` is allowed to read.
fn fixture(
    buf: []u8,
    w: u32,
    h: u32,
    depth: u8,
    colour: u8,
    interlace: u8,
    extra: []const Extra,
) []const u8 {
    @memcpy(buf[0..8], &signature);
    var f = Builder{ .b = buf, .n = 8 };

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = depth;
    ihdr[9] = colour;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = interlace;
    f.chunk("IHDR", &ihdr);

    for (extra) |e| f.chunk(e.ctype, e.data);
    f.chunk("IEND", &.{});
    return f.b[0..f.n];
}

test "Adam7 passes tile the image exactly once" {
    // 8x8 is the smallest size where all seven passes are non-empty, and the
    // pass areas must sum to the whole image or samples are lost or doubled.
    var total: u32 = 0;
    for (adam7) |p| {
        total += passWidth(p, 8) * passHeight(p, 8);
    }
    try testing.expectEqual(@as(u32, 64), total);

    // And for a size that is not a multiple of 8, where the trailing partial
    // passes are the ones that go wrong.
    var odd: u32 = 0;
    for (adam7) |p| {
        odd += passWidth(p, 13) * passHeight(p, 11);
    }
    try testing.expectEqual(@as(u32, 13 * 11), odd);
}

test "a pass that contributes nothing is skipped, not emitted empty" {
    // A 1x1 image is pass 1 only: every other pass has an empty extent and
    // therefore carries no filter bytes at all.
    var live: usize = 0;
    for (adam7) |p| {
        if (passWidth(p, 1) != 0 and passHeight(p, 1) != 0) live += 1;
    }
    try testing.expectEqual(@as(usize, 1), live);

    // 2x2: passes 1, 6 and 7 have content.
    var live2: usize = 0;
    for (adam7) |p| {
        if (passWidth(p, 2) != 0 and passHeight(p, 2) != 0) live2 += 1;
    }
    try testing.expectEqual(@as(usize, 3), live2);
}

test "poster-frame interlaced files decode as stills without special casing" {
    // APNG's default image lives in IDAT and the animation lives in ancillary
    // chunks, so an APNG sizes and decodes as an ordinary PNG. Only the frame
    // API would be missing, not the pixels.
    var buf: [64]u8 = undefined;
    const data = fixture(&buf, 4, 4, 8, 6, 0, &.{.{ .ctype = "acTL", .data = &.{ 0, 0, 0, 2 } }});
    const img = try imageSize(data, .rgba8);
    try testing.expectEqual(@as(u32, 4), img.width);
}

test "a palette index is raw, not scaled to 0..255" {
    // unpack() maps a sub-byte sample onto the full range, which is right for
    // greyscale and wrong for a palette index: index 1 at depth 4 would become
    // 17 and run off the end of the palette.
    const info = Info{ .width = 1, .height = 1, .depth = 4, .colour = .palette, .interlace = 0 };
    const plte = [_]u8{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60 }; // entry 1 = 40,50,60
    // One byte holds two depth-4 samples: index 1 in the high nibble.
    const row = [_]u8{0x10};
    const px = pixelOf(info, &plte, &.{}, &row, 0);
    try testing.expectEqual([4]u8{ 0x40, 0x50, 0x60, 255 }, px);

    // The same byte's low nibble is index 0.
    const px0 = pixelOf(info, &plte, &.{}, &row, 1);
    try testing.expectEqual([4]u8{ 0x10, 0x20, 0x30, 255 }, px0);
}

test "greyscale tRNS compares the raw sample, not the scaled one" {
    // tRNS stores the sample in the file's own depth. A depth-4 image with
    // tRNS 0x000f means "level 15 is transparent" -- the raw value, which the
    // scaled 255 must not be compared against.
    const info = Info{ .width = 2, .height = 1, .depth = 4, .colour = .grey, .interlace = 0 };
    const row = [_]u8{0xf0}; // sample 15 then 0
    const trns = [_]u8{ 0x00, 0x0f };

    const hit = pixelOf(info, &.{}, &trns, &row, 0);
    try testing.expectEqual(@as(u8, 255), hit[0]);
    try testing.expectEqual(@as(u8, 0), hit[3]);

    const miss = pixelOf(info, &.{}, &trns, &row, 1);
    try testing.expectEqual(@as(u8, 0), miss[0]);
    try testing.expectEqual(@as(u8, 255), miss[3]);
}

test "a 16-bit sample reduces to its high byte" {
    // libpng's strip_16 takes the high byte; scaling instead would put us one
    // step off every reference decoder. ImageMagick rounds, so this is the
    // value that must be pinned rather than inferred from a visual diff.
    const info = Info{ .width = 1, .height = 1, .depth = 16, .colour = .rgb, .interlace = 0 };
    const row = [_]u8{ 0xbd, 0xf7, 0xff, 0xff, 0x00, 0x00 };
    const px = pixelOf(info, &.{}, &.{}, &row, 0);
    try testing.expectEqual([4]u8{ 0xbd, 0xff, 0x00, 255 }, px);
}

test "an animated PNG decodes as its default frame" {
    // 100x100 RGBA8, acTL/20 frames: the still lives in IDAT and the animation
    // in fdAT, so an APNG must decode as frame 0 with no special casing. The
    // hash is of the reference frame-0 decode, so a wrong composite or a
    // read of fdAT data fails here.
    const data = @embedFile("testdata/apng_default_frame.png");
    try testing.expect(sniff(data));
    const img = try imageSize(data, .rgba8);
    try testing.expectEqual(@as(u32, 100), img.width);
    try testing.expectEqual(@as(u32, 100), img.height);

    const want = try testing.allocator.alloc(u8, img.byteLen());
    defer testing.allocator.free(want);
    const scratch = try testing.allocator.alloc(u8, try scratchSize(data, .rgba8));
    defer testing.allocator.free(scratch);
    const dec = try decode(data, .rgba8, .strict, want, scratch);
    try testing.expectEqual(types.Damage.none, dec.damage);

    var h: u32 = 2166136261;
    for (want) |b| {
        h ^= b;
        h *%= 16777619;
    }
    try testing.expectEqual(@as(u32, 0x1a3ee928), h);
}

test "every legal colour type and depth is accepted, and illegal ones are not" {
    var buf: [64]u8 = undefined;
    const legal = .{
        .{ @as(u8, 0), @as(u8, 1) }, .{ 0, 2 }, .{ 0, 4 },  .{ 0, 8 }, .{ 0, 16 },
        .{ 3, 1 },                   .{ 3, 2 }, .{ 3, 4 },  .{ 3, 8 }, .{ 2, 8 },
        .{ 2, 16 },                  .{ 4, 8 }, .{ 4, 16 }, .{ 6, 8 }, .{ 6, 16 },
    };
    inline for (legal) |c| {
        // Palette needs a PLTE, which is also the only reason it is special.
        const extra: []const Extra = if (c[0] == 3)
            &.{.{ .ctype = "PLTE", .data = &.{ 0, 0, 0 } }}
        else
            &.{};
        const data = fixture(&buf, 2, 2, c[1], c[0], 0, extra);
        _ = try imageSize(data, .rgba8);
    }

    // 16-bit RGB is legal; 4-bit RGB is not, and must not be quietly accepted.
    const bad = fixture(&buf, 2, 2, 4, 2, 0, &.{});
    try testing.expectError(error.Corrupt, imageSize(bad, .rgba8));

    // A palette with no PLTE is undecodable, not merely odd.
    const no_plte = fixture(&buf, 2, 2, 8, 3, 0, &.{});
    try testing.expectError(error.Corrupt, imageSize(no_plte, .rgba8));
}

test "interlaced always needs a row buffer, even when the formats match" {
    // Separate buffers: two fixtures in one would make `plain` alias `woven`,
    // since both are slices of the same array.
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const plain = fixture(&buf_a, 16, 16, 8, 6, 0, &.{});
    const woven = fixture(&buf_b, 16, 16, 8, 6, 1, &.{});

    // Same sample width, no peel: unfilter runs inside `out`, so only the
    // DEFLATE sink is needed.
    try testing.expect(try scratchSize(plain, .rgba8) > flate_sink_bytes);

    // Interlaced cannot do that -- a pass row is scattered, never contiguous.
    const w = try scratchSize(woven, .rgba8);
    try testing.expect(w > flate_sink_bytes);
    try testing.expect(w >= flate_sink_bytes + 1 + 16 * 4);
}

test "peeling is what forces a row buffer, and each cause is covered" {
    var buf: [64]u8 = undefined;

    // Grey expanded to four channels.
    const grey = fixture(&buf, 8, 8, 8, 0, 0, &.{});
    try testing.expect(try scratchSize(grey, .rgba8) > flate_sink_bytes);
    // ...but grey to grey needs nothing, because the rows coincide.
    try testing.expect(try scratchSize(grey, .grey8) > flate_sink_bytes);

    // tRNS grants alpha to an RGB source, so the alpha byte has to be built.
    const trns = fixture(&buf, 8, 8, 8, 2, 0, &.{.{ .ctype = "tRNS", .data = &.{ 0, 1, 0, 2, 0, 3 } }});
    try testing.expect(try scratchSize(trns, .rgba8) > flate_sink_bytes);
    // Asking for rgb8 here is refused earlier: tRNS IS alpha, so dropping it is
    // the loss `convertible` exists to prevent.
    try testing.expectError(error.UnsupportedConversion, scratchSize(trns, .rgb8));

    // A palette is always a lookup.
    const pal = fixture(&buf, 8, 8, 8, 3, 0, &.{.{ .ctype = "PLTE", .data = &.{ 0, 0, 0 } }});
    try testing.expect(try scratchSize(pal, .rgba8) > flate_sink_bytes);
}

test "a narrow request is refused exactly when it would lose something" {
    var buf: [64]u8 = undefined;

    // Colour source: no grey8.
    try testing.expectError(error.UnsupportedConversion, imageSize(fixture(&buf, 2, 2, 8, 2, 0, &.{}), .grey8));
    // Palette is colour even if every entry happens to be grey.
    try testing.expectError(
        error.UnsupportedConversion,
        imageSize(fixture(&buf, 2, 2, 8, 3, 0, &.{.{ .ctype = "PLTE", .data = &.{ 0, 0, 0 } }}), .grey8),
    );
    // Alpha in the source, so rgb8 would drop it.
    try testing.expectError(error.UnsupportedConversion, imageSize(fixture(&buf, 2, 2, 8, 6, 0, &.{}), .rgb8));
    // tRNS alpha counts: this is RGB plus transparency, not plain RGB.
    try testing.expectError(
        error.UnsupportedConversion,
        imageSize(fixture(&buf, 2, 2, 8, 2, 0, &.{.{ .ctype = "tRNS", .data = &.{ 0, 1, 0, 2, 0, 3 } }}), .rgb8),
    );
    // Grey in, grey out is the honest projection.
    try testing.expectEqual(PixelFormat.grey8, (try imageSize(fixture(&buf, 2, 2, 8, 0, 0, &.{}), .grey8)).format);
}

test "orientation swaps the reported dimensions, not just the pixels" {
    var buf: [128]u8 = undefined;
    // Tag 0x0112 = 6 means the stored landscape is displayed as a portrait.
    const tiff = [_]u8{
        'I', 'I', 0x2a, 0x00,
        8,   0,   0,    0,
        1,   0,   0x12, 0x01,
        3,   0,   1,    0,
        0,   0,   6,    0,
        0,   0,   0,    0,
        0,   0,
    };
    const data = fixture(&buf, 40, 30, 8, 6, 0, &.{.{ .ctype = "eXIf", .data = &tiff }});
    const img = try imageSize(data, .rgba8);
    try testing.expectEqual(@as(u32, 30), img.width);
    try testing.expectEqual(@as(u32, 40), img.height);

    // Upright files are untouched.
    const flat = fixture(&buf, 40, 30, 8, 6, 0, &.{});
    const img2 = try imageSize(flat, .rgba8);
    try testing.expectEqual(@as(u32, 40), img2.width);
    try testing.expectEqual(@as(u32, 30), img2.height);
}

test "a bad CRC is refused, because a corrupt header is not a size" {
    var buf: [64]u8 = undefined;
    const data = fixture(&buf, 4, 4, 8, 6, 0, &.{});
    var broken: [64]u8 = undefined;
    @memcpy(broken[0..data.len], data);
    broken[20] ^= 0xFF;
    try testing.expectError(error.Corrupt, imageSize(broken[0..data.len], .rgba8));
}

test "a header that stops early is Truncated, not Corrupt" {
    var buf: [64]u8 = undefined;
    const data = fixture(&buf, 4, 4, 8, 6, 0, &.{});
    try testing.expectError(error.Truncated, imageSize(data[0..20], .rgba8));
}

/// Build a decode-ready PNG from raw (unfiltered) scanlines: deflates the
/// filtered rows, emits IHDR, the given pre-IDAT chunks, IDAT, then any
/// post-IDAT chunks before IEND. Used by the lenient and ordering tests,
/// which need a stream that actually decompresses.
fn buildPng(
    buf: []u8,
    w: u32,
    h: u32,
    depth: u8,
    colour: u8,
    rows: []const u8,
    pre: []const Extra,
    post: []const Extra,
) []const u8 {
    @memcpy(buf[0..8], &signature);
    var f = Builder{ .b = buf, .n = 8 };

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = depth;
    ihdr[9] = colour;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    f.chunk("IHDR", &ihdr);

    for (pre) |e| f.chunk(e.ctype, e.data);

    // zlib wrapper: 0x78 0x01, deflate stored-free (fixed Huffman via
    // stored blocks is simplest: no compressor needed for tiny fixtures).
    var z: [512]u8 = undefined;
    var zn: usize = 0;
    z[0] = 0x78;
    z[1] = 0x01;
    zn = 2;
    var off: usize = 0;
    while (off < rows.len) {
        const n = @min(@as(usize, 0xffff), rows.len - off);
        const last: u8 = if (off + n >= rows.len) 1 else 0;
        z[zn] = last;
        zn += 1;
        std.mem.writeInt(u16, z[zn..][0..2], @intCast(n), .little);
        zn += 2;
        std.mem.writeInt(u16, z[zn..][0..2], ~@as(u16, @intCast(n)), .little);
        zn += 2;
        @memcpy(z[zn..][0..n], rows[off..][0..n]);
        zn += n;
        off += n;
    }
    var a: u32 = 1;
    var b: u32 = 0;
    for (z[0..zn]) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    const adler = (b << 16) | a;
    std.mem.writeInt(u32, z[zn..][0..4], adler, .big);
    zn += 4;

    f.chunk("IDAT", z[0..zn]);
    for (post) |e| f.chunk(e.ctype, e.data);
    f.chunk("IEND", &.{});
    return f.b[0..f.n];
}

test "a truncated IDAT stream decodes what survived under lenient, and errors under strict" {
    // 4x4 RGB8 = 4 rows of (1 filter byte + 12 sample bytes) = 52 filtered
    // bytes. Only two rows reach the stream, so the bottom half is undecoded.
    const full: [52]u8 = @splat(0);
    var buf: [1024]u8 = undefined;
    var built = buildPng(&buf, 4, 4, 8, 2, &full, &.{}, &.{});

    // Cut the IDAT payload down to two rows' worth, then re-seal CRCs by
    // rebuilding from the shortened data rather than patching a length.
    const half: [26]u8 = @splat(0);
    built = buildPng(&buf, 4, 4, 8, 2, &half, &.{}, &.{});

    const img = try imageSize(built, .rgba8);
    const out = try testing.allocator.alloc(u8, img.byteLen());
    defer testing.allocator.free(out);
    const scratch = try testing.allocator.alloc(u8, try scratchSize(built, .rgba8));
    defer testing.allocator.free(scratch);

    // Strict refuses: a short decode is data loss the caller did not ask for.
    try testing.expectError(error.Truncated, decode(built, .rgba8, .strict, out, scratch));

    // Lenient reports it and leaves the undecoded region zeroed.
    @memset(out, 0xAA);
    const dec = try decode(built, .rgba8, .lenient, out, scratch);
    try testing.expectEqual(types.Damage.truncated, dec.damage);
    // Bottom rows were never written, so they must still hold the sentinel.
    try testing.expectEqual(@as(u8, 0xAA), out[out.len - 1]);
}

test "PLTE after IDAT is refused rather than silently applied" {
    // The palette colours the IDAT stream that precedes it, so a later one
    // cannot apply. Taking the last value found would decode correctly-shaped
    // pixels with the wrong colours and no error.
    const rows: [52]u8 = @splat(0); // 4x4 RGB8 = 4 rows x (1 filter + 12 samples)
    const plte = [_]u8{ 0, 0, 0, 0xff, 0xff, 0xff };
    var buf: [1024]u8 = undefined;

    // Before IDAT is legal and must still decode.
    const ok = buildPng(&buf, 4, 4, 8, 2, &rows, &.{.{ .ctype = "PLTE", .data = &plte }}, &.{});
    const img = try imageSize(ok, .rgba8);
    const out = try testing.allocator.alloc(u8, img.byteLen());
    defer testing.allocator.free(out);
    const scratch = try testing.allocator.alloc(u8, try scratchSize(ok, .rgba8));
    defer testing.allocator.free(scratch);
    _ = try decode(ok, .rgba8, .strict, out, scratch);

    // After IDAT is a spec violation.
    var buf2: [1024]u8 = undefined;
    const bad = buildPng(&buf2, 4, 4, 8, 2, &rows, &.{}, &.{.{ .ctype = "PLTE", .data = &plte }});
    try testing.expectError(error.Corrupt, decode(bad, .rgba8, .strict, out, scratch));
}

test "a duplicate PLTE is refused" {
    const rows: [52]u8 = @splat(0);
    const plte = [_]u8{ 0, 0, 0, 0xff, 0xff, 0xff };
    var buf: [1024]u8 = undefined;
    const bad = buildPng(&buf, 4, 4, 8, 2, &rows, &.{
        .{ .ctype = "PLTE", .data = &plte },
        .{ .ctype = "PLTE", .data = &plte },
    }, &.{});
    const img = try imageSize(bad, .rgba8);
    const out = try testing.allocator.alloc(u8, img.byteLen());
    defer testing.allocator.free(out);
    const scratch = try testing.allocator.alloc(u8, try scratchSize(bad, .rgba8));
    defer testing.allocator.free(scratch);
    try testing.expectError(error.Corrupt, decode(bad, .rgba8, .strict, out, scratch));
}

test "a bad CRC on a chunk the decoder ignores is fatal under strict, a skip under lenient" {
    // tEXt is not read by anything here, so its contents cannot affect pixels.
    // Refusing the whole image over one bad metadata chunk is the strict rule;
    // lenient must decode and say what it tolerated.
    const rows: [52]u8 = @splat(0); // 4x4 RGB8
    const text = "Comment\x00hello";
    var buf: [1024]u8 = undefined;
    const good = buildPng(&buf, 4, 4, 8, 2, &rows, &.{.{ .ctype = "tEXt", .data = text }}, &.{});

    const img = try imageSize(good, .rgba8);
    const out = try testing.allocator.alloc(u8, img.byteLen());
    defer testing.allocator.free(out);
    const scratch = try testing.allocator.alloc(u8, try scratchSize(good, .rgba8));
    defer testing.allocator.free(scratch);

    // Clean file decodes with no damage recorded.
    const clean = try decode(good, .rgba8, .lenient, out, scratch);
    try testing.expectEqual(types.Damage.none, clean.damage);

    // Corrupt the tEXt CRC: flip the last of its four CRC bytes.
    var bad: [1024]u8 = undefined;
    @memcpy(bad[0..good.len], good);
    const t = bad[0..good.len];
    const at = std.mem.indexOf(u8, t, "tEXt").?;
    var crc_at: usize = 0;
    {
        const len = std.mem.readInt(u32, t[at - 4 ..][0..4], .big);
        crc_at = at + 4 + len;
    }
    bad[crc_at + 3] ^= 0xff;

    try testing.expectError(error.Corrupt, decode(bad[0..good.len], .rgba8, .strict, out, scratch));

    const dec = try decode(bad[0..good.len], .rgba8, .lenient, out, scratch);
    try testing.expectEqual(types.Damage.skipped_ancillary, dec.damage);
}

test "a bad CRC on a chunk the decoder reads is fatal even under lenient" {
    // A corrupt PLTE decodes to wrong colours with no other symptom, so it can
    // never be a "tolerate and continue" case.
    const rows: [52]u8 = @splat(0);
    const plte = [_]u8{ 0, 0, 0, 0xff, 0xff, 0xff };
    var buf: [1024]u8 = undefined;
    const good = buildPng(&buf, 4, 4, 8, 2, &rows, &.{.{ .ctype = "PLTE", .data = &plte }}, &.{});

    var bad: [1024]u8 = undefined;
    @memcpy(bad[0..good.len], good);
    const t = bad[0..good.len];
    const at = std.mem.indexOf(u8, t, "PLTE").?;
    const len = std.mem.readInt(u32, t[at - 4 ..][0..4], .big);
    bad[at + 4 + len + 3] ^= 0xff;

    const img = try imageSize(good, .rgba8);
    const out = try testing.allocator.alloc(u8, img.byteLen());
    defer testing.allocator.free(out);
    const scratch = try testing.allocator.alloc(u8, try scratchSize(good, .rgba8));
    defer testing.allocator.free(scratch);

    try testing.expectError(error.Corrupt, decode(bad[0..good.len], .rgba8, .lenient, out, scratch));
}
