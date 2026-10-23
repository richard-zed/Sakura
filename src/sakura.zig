//! Sakura -- image decoding with no allocator.
//!
//! The contract, in one paragraph: the caller owns every byte. `imageSize` reads
//! headers only and says how big `out` must be; `scratchSize` says how big the
//! decoder's working buffer must be; `decode` fills both. Nothing here
//! allocates, keeps global state, or remembers anything between calls, so
//! decoding is reentrant and thread-safe by construction and `out` may be a
//! sub-slice of a larger buffer.
//!
//! Conventions, shared with Cedar:
//!   * no allocator anywhere; every output buffer is caller-owned
//!   * every buffer size is derivable from the header, BEFORE decoding
//!   * Debug is the gate; ReleaseFast is for profiling only
//!   * pixels are STRAIGHT (non-premultiplied) alpha, matching Elm's
//!     source-over blend
//!
//! The caller never switches on format: bytes go in, `sniff` decides, and the
//! per-format module is an implementation detail. That is the whole reason PNG
//! and JPEG live in one package rather than two.

const std = @import("std");

const types = @import("types.zig");
const exif = @import("exif.zig");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");

pub const Format = types.Format;
pub const PixelFormat = types.PixelFormat;
pub const Image = types.Image;
pub const Policy = types.Policy;
pub const Damage = types.Damage;
pub const Decoded = types.Decoded;
pub const Error = types.Error;

/// PNG's Adam7 table and pass arithmetic, exposed because a caller building a
/// partial-progress UI or a test needs the same geometry the decoder uses.
pub const png_pass = png.Pass;
pub const adam7 = png.adam7;

test {
    // The per-format modules and `exif` carry their own tests; without this the
    // test runner never reaches them and a green suite means nothing.
    std.testing.refAllDecls(@This());
    _ = exif;
    _ = png;
    _ = jpeg;
}

/// Which decoder will handle these bytes, from magic bytes alone -- never from a
/// file extension and never from a caller-supplied enum, because the caller has
/// bytes.
pub fn sniff(bytes: []const u8) ?Format {
    if (png.sniff(bytes)) return .png;
    if (jpeg.sniff(bytes)) return .jpeg;
    // JPEG-XL container: 00 00 00 0C "JXL " 0D 0A 87 0A
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[4..8], "JXL ") and
        std.mem.eql(u8, bytes[8..12], "\x0d\x0a\x87\x0a")) return .jxl;
    return null;
}

fn formatOf(bytes: []const u8) Error!Format {
    return sniff(bytes) orelse error.NotAnImage;
}

/// Header only; no pixel data is touched. Reports the dimensions the output will
/// actually have, so EXIF orientation is already applied.
pub fn imageSize(bytes: []const u8, want: PixelFormat) Error!Image {
    return switch (try formatOf(bytes)) {
        .png => png.imageSize(bytes, want),
        .jpeg => jpeg.imageSize(bytes, want),
        .jxl => error.Unsupported,
    };
}

/// Bytes the decoder needs beside `out`. Depends on `want`, because it is the
/// expansion that decides whether there is anywhere to unfilter into.
pub fn scratchSize(bytes: []const u8, want: PixelFormat) Error!usize {
    return switch (try formatOf(bytes)) {
        .png => png.scratchSize(bytes, want),
        .jpeg => jpeg.scratchSize(bytes, want),
        .jxl => error.Unsupported,
    };
}

/// Fill `out` with pixels, `scratch` with whatever the decoder needs.
///
/// Both are validated before any pixel is written, so a short buffer is an error
/// rather than a partial image. `OutTooSmall` and `ScratchTooSmall` stay
/// separate because "which buffer did I under-size" is the first question asked.
pub fn decode(
    bytes: []const u8,
    want: PixelFormat,
    policy: Policy,
    out: []u8,
    scratch: []u8,
) Error!Decoded {
    return switch (try formatOf(bytes)) {
        .png => png.decode(bytes, want, policy, out, scratch),
        .jpeg => jpeg.decode(bytes, want, policy, out, scratch),
        .jxl => error.Unsupported,
    };
}

// ---------------------------------------------------------------------------

test "sniff answers from magic bytes, and refuses what is not an image" {
    try std.testing.expectEqual(Format.png, sniff(&png.signature).?);
    try std.testing.expectEqual(Format.jpeg, sniff(&.{ 0xFF, 0xD8, 0xFF, 0xE0 }).?);
    try std.testing.expectEqual(
        Format.jxl,
        sniff(&.{ 0x00, 0x00, 0x00, 0x0C, 'J', 'X', 'L', ' ', 0x0D, 0x0A, 0x87, 0x0A }).?,
    );

    try std.testing.expectEqual(@as(?Format, null), sniff("GIF89a"));
    try std.testing.expectEqual(@as(?Format, null), sniff(""));
    // A PNG missing one signature byte, and a JPEG with no second marker.
    try std.testing.expectEqual(@as(?Format, null), sniff(png.signature[0..7]));
    try std.testing.expectEqual(@as(?Format, null), sniff(&.{ 0xFF, 0xD8 }));
}

test "unrecognised bytes are NotAnImage from every entry point" {
    try std.testing.expectError(error.NotAnImage, imageSize("nope", .rgba8));
    try std.testing.expectError(error.NotAnImage, scratchSize("nope", .rgba8));
    try std.testing.expectError(error.NotAnImage, decode("nope", .rgba8, .strict, &.{}, &.{}));
}

test "a recognised format says Unsupported rather than pretending" {
    try std.testing.expectError(error.Unsupported, imageSize(&.{ 0xFF, 0xD8, 0xFF, 0xE0 }, .rgba8));
    try std.testing.expectError(
        error.Unsupported,
        imageSize(&.{ 0x00, 0x00, 0x00, 0x0C, 'J', 'X', 'L', ' ', 0x0D, 0x0A, 0x87, 0x0A }, .rgba8),
    );
}

test "an image's buffers are sized from its own header" {
    const img = Image{ .width = 640, .height = 480, .format = .rgba8, .source = .png };
    try std.testing.expectEqual(@as(usize, 2560), img.stride());
    try std.testing.expectEqual(@as(usize, 1_228_800), img.byteLen());
}
