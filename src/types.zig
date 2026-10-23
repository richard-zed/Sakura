//! Shared vocabulary. Lives in its own file so the per-format modules and
//! `root.zig` can all see these without a mutual import.

/// PNG, JPEG and JPEG-XL. JPEG-XL is a tier up in effort and is not scheduled;
/// it is listed so `sniff` has one place to answer from.
pub const Format = enum { png, jpeg, jxl };

/// What the caller wants back. `rgba8` is the default because that is what a
/// compositor consumes. The narrow forms exist for a caller that is storing
/// rather than drawing.
///
/// Every source can produce `rgba8` exactly: pad alpha, replicate grey, look up
/// a palette. A narrow request is honoured only when it is a projection of the
/// source, and refused with `UnsupportedConversion` when it is not.
pub const PixelFormat = enum {
    rgba8,
    rgb8,
    grey8,

    pub fn bytesPerPixel(self: PixelFormat) u8 {
        return switch (self) {
            .rgba8 => 4,
            .rgb8 => 3,
            .grey8 => 1,
        };
    }

    pub fn hasAlpha(self: PixelFormat) bool {
        return self == .rgba8;
    }
};

pub const Image = struct {
    width: u32,
    height: u32,
    /// The format the pixels are actually in. Always equal to the requested
    /// `want` on a successful decode.
    format: PixelFormat,
    /// What the bytes arrived as. Not needed to read `out`; carried so a caller
    /// can report what it was given.
    source: Format,

    /// Rows are packed -- `stride == width * bytesPerPixel`, always. A caller
    /// that wants padding copies. One rule, so no write path branches on it.
    pub fn stride(self: Image) usize {
        return @as(usize, self.width) * self.format.bytesPerPixel();
    }

    /// Exactly the bytes `decode` will write, and therefore exactly what `out`
    /// must be.
    pub fn byteLen(self: Image) usize {
        return self.stride() * @as(usize, self.height);
    }
};

pub const Policy = enum {
    /// Any deviation from the format is an error.
    strict,
    /// Decode what survives and say so in `Damage`.
    lenient,
};

/// What a lenient decode had to tolerate. `strict` never produces anything but
/// `.none` -- it returns an error instead.
pub const Damage = enum {
    none,
    /// Input ended early. Undecoded regions hold zero.
    truncated,
    /// A non-essential chunk was unreadable and skipped.
    skipped_ancillary,
    /// Some blocks could not be decoded. They hold zero.
    corrupt_blocks,
};

pub const Decoded = struct {
    image: Image,
    damage: Damage,
};

/// Closed on purpose, and deliberately free of prose: naming *which* byte was
/// bad is the caller's job (Elm has a diagnostic band for exactly that).
pub const Error = error{
    NotAnImage,
    /// Recognised, but this format or variant is not implemented.
    Unsupported,
    /// The requested pixel format cannot be produced from this source without
    /// losing information the caller did not ask to lose.
    UnsupportedConversion,
    Truncated,
    Corrupt,
    OutTooSmall,
    ScratchTooSmall,
    /// Dimensions, or the resulting byte count, overflow what can be addressed.
    TooLarge,
};
