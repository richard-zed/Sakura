const std = @import("std");
const sakura = @import("sakura");

fn mix(bytes: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    return h;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var it = init.minimal.args.iterate();
    _ = it.next();

    while (it.next()) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024)) catch |e| {
            std.debug.print("{s}\n  READ FAILED {t}\n", .{ path, e });
            continue;
        };
        defer gpa.free(bytes);

        const fmt = sakura.sniff(bytes) orelse {
            std.debug.print("{s}\n  not an image\n", .{path});
            continue;
        };
        const img = sakura.imageSize(bytes, .rgba8) catch |e| {
            std.debug.print("{s}\n  imageSize FAILED {t}\n", .{ path, e });
            continue;
        };
        const out = try gpa.alloc(u8, img.byteLen());
        defer gpa.free(out);
        const sc_len = sakura.scratchSize(bytes, .rgba8) catch |e| {
            std.debug.print("{s}\n  scratchSize FAILED {t}\n", .{ path, e });
            continue;
        };
        const sc = try gpa.alloc(u8, sc_len);
        defer gpa.free(sc);

        const d = sakura.decode(bytes, .rgba8, .strict, out, sc) catch |e| {
            std.debug.print("{s}\n  decode FAILED {t}\n", .{ path, e });
            continue;
        };
        std.debug.print("{s}\n  {s} {d}x{d} out={d} scratch={d} damage={t} mix=0x{x:0>8}\n", .{
            path, @tagName(fmt), d.image.width, d.image.height,
            out.len, sc_len, d.damage, mix(out),
        });
    }
}
