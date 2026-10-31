# Sakura

Image decoding with no allocator.

The caller owns every byte. `imageSize` reads headers only and says how big the
output must be. `scratchSize` says how big the decoder's working buffer must be.
`decode` fills both. Nothing here allocates, keeps global state, or remembers
anything between calls — decoding is reentrant and thread-safe by construction,
and the output may be a sub-slice of a larger buffer.

```zig
const sakura = @import("sakura");

// Headers only. Cost is independent of image size.
const img = try sakura.imageSize(bytes, .rgba8);

const out = try allocator.alloc(u8, img.byteLen());
defer allocator.free(out);
const scratch = try allocator.alloc(u8, try sakura.scratchSize(bytes, .rgba8));
defer allocator.free(scratch);

const dec = try sakura.decode(bytes, .rgba8, .strict, out, scratch);
if (dec.damage != .none) { /* lenient mode had to tolerate something */ }
```

The allocator appears only because *you* chose to allocate. The library never
touches one.

## Status

**0.1.0 — PNG only.**

PNG is complete across every colour type and bit depth PngSuite exercises, in
both strict and lenient modes.

JPEG is **not implemented**. `src/jpeg.zig` contains the signature test and the
design constraints the implementation must satisfy, nothing more. `sniff`
recognises JPEG, and `decode` returns `error.Unsupported`. If you need JPEG
today, this is not the library.

## Contract

- **No allocator.** Every output buffer is caller-owned.
- **Every buffer size is derivable from the header, before decoding.** This is
  why `imageSize` and `scratchSize` are separate from `decode`.
- **The caller never switches on format.** Bytes go in, `sniff` decides, the
  per-format module is an implementation detail.
- **Straight (non-premultiplied) alpha**, so a caller blending source-over does
  not have to un-premultiply first.
- **Closed error set.** `Error` is deliberately free of prose. Naming *which*
  byte was bad is the caller's job.

## Strict and lenient

`Policy.strict` treats any deviation as an error. `Policy.lenient` decodes what
survives and reports it in `Damage`.

Lenient tolerates exactly one thing beyond truncation: a bad CRC on a chunk the
decoder does not read. A corrupt `tEXt` cannot affect pixels, so skipping it and
saying so is honest. A corrupt `IHDR`, `PLTE`, `tRNS` or `eXIf` is fatal in
*both* modes — those decode to wrong pixels with no other symptom, which is
worse than refusing.

`Damage` has no `corrupt_blocks`. Recovering mid-stream from a damaged DEFLATE
stream is not implemented, and a variant naming a behaviour the decoder cannot
produce is a lie in the type.

## Testing

Two oracles, both pinned:

- **PngSuite** — 161 images compared byte-exact against reference output. The
  16-bit references are the suite's own, so that half is partly self-graded.
- **Real-world corpus** — six ordinary encoders' output, hashed with sha256 and
  verified against ImageMagick. This is the only oracle in the tree the decoder
  did not produce.

```
47/47 tests passed
161 compared, 161 byte-exact
6 matched, 1 absent, 0 faults
```

A corpus that loads nothing must never report success, so the real-world test
counts its own reference rows and fails on a mismatch rather than printing zero
and passing.

Debug is the gate. ReleaseFast is for profiling only.

```sh
zig build test --summary all
```

## Licence

MIT. See `LICENSE`.
