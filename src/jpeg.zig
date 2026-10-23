//! JPEG. Signature only; the marker walk and the codestream are the work.
//!
//! Three things are already settled and constrain the implementation:
//!
//! 1. EXIF orientation is ALWAYS applied, so `imageSize` reports ORIENTED
//!    dimensions and the decoder scatters. `APP1` payloads after `Exif\0\0` go
//!    straight to `exif.orientation`.
//!
//! 2. Baseline sequences can IDCT each MCU as it arrives, so baseline needs no
//!    coefficient scratch -- the output buffer is enough. Progressive cannot:
//!    coefficients are refined across scans and every one must be resident
//!    before any IDCT, so THIS is where the format's scratch cost comes from.
//!
//! 3. Scope is baseline (SOF0), extended sequential (SOF1) and progressive
//!    (SOF2), all common chroma subsamplings, restart markers, and both Huffman
//!    tables. Deferred: arithmetic coding, 12-bit precision, and 4-component
//!    CMYK/YCCK (which needs a second colour transform, not more decoding).

const std = @import("std");
const types = @import("types.zig");

const Error = types.Error;
const Image = types.Image;
const PixelFormat = types.PixelFormat;

/// SOI followed by another marker. `FF D8` alone is a truncated file, not a
/// JPEG, and `decode` is where that becomes an error.
pub fn sniff(bytes: []const u8) bool {
    return bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF;
}

pub fn imageSize(bytes: []const u8, want: PixelFormat) Error!Image {
    if (!sniff(bytes)) return error.NotAnImage;
    _ = want;
    // NEXT: walk markers to SOFn for dimensions and component count, read APP1
    // orientation, then report swapped dimensions when orientation >= 5.
    return error.Unsupported;
}

pub fn scratchSize(bytes: []const u8, want: PixelFormat) Error!usize {
    if (!sniff(bytes)) return error.NotAnImage;
    _ = want;
    // NEXT: 0 for SOF0/SOF1; the coefficient array for SOF2.
    return error.Unsupported;
}

pub fn decode(
    bytes: []const u8,
    want: PixelFormat,
    policy: types.Policy,
    out: []u8,
    scratch: []u8,
) Error!types.Decoded {
    if (!sniff(bytes)) return error.NotAnImage;
    _ = want;
    _ = policy;
    _ = out;
    _ = scratch;
    return error.Unsupported;
}
