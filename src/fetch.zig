//! HTTP GET -> file, with SHA-1 verification and atomic replace.
//!
//! Every byte this project fetches goes through `get`. There is exactly one
//! host list it is ever pointed at, and that list is built by `meta.zig` from
//! Mojang's own metadata: no mirrors, no third-party CDNs, no user-supplied
//! "download source" setting.

const std = @import("std");
const Io = std.Io;
const http = std.http;

pub const user_agent = "arclight/0.0.0 (+https://github.com/MoyaMryia/Arclight-Launcher)";

pub const Spec = struct {
    url: []const u8,
    /// Absolute path, or relative to the working directory.
    dest: []const u8,
    /// Expected SHA-1, lowercase hex. When present it is always verified.
    sha1: ?[]const u8 = null,
    /// Expected size in bytes, when known.
    size: ?u64 = null,
    /// If `dest` already satisfies `sha1`/`size`, skip the download.
    skip_if_valid: bool = true,
};

pub const Outcome = struct {
    bytes: u64,
    /// True when the file was already present and valid.
    cached: bool,
    sha1: [40]u8,
};

pub const Error = error{
    HttpStatus,
    Sha1Mismatch,
    SizeMismatch,
    EmptyUrl,
};

const max_attempts = 3;

pub fn get(io: Io, gpa: std.mem.Allocator, spec: Spec) !Outcome {
    if (spec.url.len == 0) return Error.EmptyUrl;

    if (spec.dest.len != 0) {
        if (std.fs.path.dirname(spec.dest)) |dir| {
            if (dir.len != 0) Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    if (spec.skip_if_valid) {
        if (tryStat(io, spec.dest)) |st| {
            if (spec.size == null or st.size == spec.size.?) {
                const digest = try sha1File(io, gpa, spec.dest);
                const hex = toHex(digest);
                const ok = if (spec.sha1) |want|
                    std.ascii.eqlIgnoreCase(&hex, want)
                else if (spec.size) |want|
                    st.size == want
                else
                    // Nothing to verify against: trust an existing non-empty
                    // file rather than re-downloading it on every run.
                    st.size != 0;
                if (ok) return .{ .bytes = st.size, .cached = true, .sha1 = hex };
            }
        }
    }

    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const result = downloadOnce(io, gpa, spec) catch |err| {
            if (attempt + 1 == max_attempts) return err;
            const backoff_ms: u64 = 500 * (@as(u64, 1) << @intCast(attempt));
            Io.sleep(io, .{ .nanoseconds = @intCast(backoff_ms * std.time.ns_per_ms) }, .awake) catch {};
            continue;
        };
        return result;
    }
    unreachable;
}

fn downloadOnce(io: Io, gpa: std.mem.Allocator, spec: Spec) !Outcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const part = try std.fmt.allocPrint(arena, "{s}.part", .{spec.dest});

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var file = try Io.Dir.cwd().createFile(io, part, .{ .truncate = true });
    defer file.close(io);

    var buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(file, io, &buf);

    const res = try client.fetch(.{
        .location = .{ .url = spec.url },
        .response_writer = &fw.interface,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = user_agent },
            .{ .name = "accept", .value = "*/*" },
        },
    });
    try fw.interface.flush();

    switch (res.status) {
        .ok => {},
        else => {
            Io.Dir.deleteFileAbsolute(io, part) catch {};
            std.debug.print("http {d} for {s}\n", .{ @intFromEnum(res.status), spec.url });
            return Error.HttpStatus;
        },
    }

    const st = try statOrFail(io, part);

    if (spec.size) |want| {
        if (st.size != want) {
            Io.Dir.deleteFileAbsolute(io, part) catch {};
            return Error.SizeMismatch;
        }
    }

    const digest = try sha1File(io, gpa, part);
    const hex = toHex(digest);

    if (spec.sha1) |want| {
        if (!std.ascii.eqlIgnoreCase(&hex, want)) {
            Io.Dir.deleteFileAbsolute(io, part) catch {};
            return Error.Sha1Mismatch;
        }
    }

    try Io.Dir.renameAbsolute(part, spec.dest, io);
    return .{ .bytes = st.size, .cached = false, .sha1 = hex };
}

fn tryStat(io: Io, path: []const u8) ?Io.File.Stat {
    return Io.Dir.cwd().statFile(io, path, .{}) catch null;
}

fn statOrFail(io: Io, path: []const u8) !Io.File.Stat {
    return Io.Dir.cwd().statFile(io, path, .{});
}

pub fn sha1File(io: Io, gpa: std.mem.Allocator, path: []const u8) ![20]u8 {
    _ = gpa;
    var file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var read_buf: [64 * 1024]u8 = undefined;
    var fr: Io.File.Reader = .init(file, io, &read_buf);

    var hasher = std.crypto.hash.Sha1.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try fr.interface.readSliceShort(&chunk);
        if (n == 0) break;
        hasher.update(chunk[0..n]);
    }
    var out: [20]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub fn toHex(digest: [20]u8) [40]u8 {
    const hex_chars = "0123456789abcdef";
    var out: [40]u8 = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return out;
}

test "toHex" {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("abc", .{}, &digest);
    try std.testing.expectEqualStrings(
        "a9993e364706816aba3e25717850c26c9cd0d89d",
        &toHex(digest),
    );
}
