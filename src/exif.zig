//! EXIF orientation, shared by PNG's `eXIf` chunk and JPEG's `APP1`.
//!
//! Orientation is ALWAYS applied (settled), so `imageSize` reports the ORIENTED
//! dimensions: a 4000x3000 file tagged 6 is 3000x4000 of output, and `out` is
//! sized from that. Decoders scatter rather than rotating afterwards, so the
//! rotation costs no memory -- but it does mean rows are not written in natural
//! order.

const std = @import("std");

/// Read tag 0x0112 from IFD0. `tiff` is the TIFF-structured block only: PNG's
/// `eXIf` payload, or the `Exif\0\0`-stripped `APP1` payload.
///
/// Returns null for absent, malformed, or out-of-range -- the caller treats that
/// as 1 (upright) rather than failing the decode, because orientation is
/// metadata about a perfectly good image.
pub fn orientation(tiff: []const u8) ?u8 {
    if (tiff.len < 8) return null;

    const endian: std.builtin.Endian = if (std.mem.eql(u8, tiff[0..4], "MM\x00\x2a"))
        .big
    else if (std.mem.eql(u8, tiff[0..4], "II\x2a\x00"))
        .little
    else
        return null;

    const ifd = std.mem.readInt(u32, tiff[4..8], endian);
    if (ifd < 8) return null;
    const base: usize = @intCast(ifd);
    if (@as(usize, base) + 2 > tiff.len) return null;

    const count = std.mem.readInt(u16, tiff[base..][0..2], endian);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = base + 2 + i * 12;
        if (entry + 12 > tiff.len) return null;
        const tag = std.mem.readInt(u16, tiff[entry..][0..2], endian);
        if (tag != 0x0112) continue;
        // Type 3 (SHORT), one value, left-justified in the 4-byte value field
        // regardless of endianness.
        const v = std.mem.readInt(u16, tiff[entry + 8 ..][0..2], endian);
        if (v < 1 or v > 8) return null;
        return @intCast(v);
    }
    return null;
}

/// 5..8 are the transposing orientations: the stored landscape becomes a
/// portrait.
pub fn swapsAxes(orient: u8) bool {
    return orient >= 5 and orient <= 8;
}

test "orientation is read from either byte order, and junk is not trusted" {
    // Little-endian, one entry, tag 0x0112, value 6.
    const le = [_]u8{
        'I', 'I', 0x2a, 0x00,
        8, 0, 0, 0, // IFD0 at offset 8
        1, 0, // one entry
        0x12, 0x01, // tag 0x0112
        3, 0, // type SHORT
        1, 0, 0, 0, // count 1
        6, 0, 0, 0, // value 6
        0, 0, 0, 0, // next IFD
    };
    try std.testing.expectEqual(@as(?u8, 6), orientation(&le));
    try std.testing.expect(swapsAxes(6));
    try std.testing.expect(!swapsAxes(1));

    const be = [_]u8{
        'M', 'M', 0x00, 0x2a,
        0,   0,   0,    8,
        0,   1,   0x01, 0x12,
        0,   3,   0,    0,
        0,   1,   0,    6,
        0,   0,   0,    0,
        0,   0,
    };
    try std.testing.expectEqual(@as(?u8, 6), orientation(&be));

    try std.testing.expectEqual(@as(?u8, null), orientation("not a tiff"));
    const header_only = [_]u8{ 'M', 'M', 0, 0x2a, 0, 0, 0, 8 };
    try std.testing.expectEqual(@as(?u8, null), orientation(&header_only));
    // IFD pointer past the end must not be followed.
    const oob = [_]u8{ 'I', 'I', 0x2a, 0x00, 0xff, 0xff, 0xff, 0x7f, 1, 0 };
    try std.testing.expectEqual(@as(?u8, null), orientation(&oob));
}
