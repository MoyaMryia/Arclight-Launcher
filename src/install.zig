//! Install one version from Mojang's own endpoints.
//!
//! Layout produced inside `--dir`:
//!
//!     versions/<id>/<id>.json
//!     versions/<id>/<id>.jar
//!     versions/<id>/natives/            (legacy natives only)
//!     libraries/<maven path>
//!     assets/indexes/<index id>.json
//!     assets/objects/<xx>/<hash>
//!
//! Nothing here can be pointed at a mirror: every URL comes from the version
//! json, which comes from `piston-meta.mojang.com`.

const std = @import("std");
const Io = std.Io;
const http = std.http;

const fetch = @import("fetch.zig");
const meta = @import("meta.zig");

pub const assets_base = "https://resources.download.minecraft.net";

pub const Options = struct {
    game_dir: []const u8,
    cache_dir: []const u8,
    version: []const u8,
    want_assets: bool = true,
    progress: bool = true,
    threads: usize = 8,
};

pub const Stats = struct {
    version: []const u8,
    client_bytes: u64 = 0,
    libraries: usize = 0,
    libraries_skipped: usize = 0,
    natives_jars: usize = 0,
    assets: usize = 0,
    assets_bytes: u64 = 0,
    /// Pre-1.7 versions map assets into `resources/` instead of `objects/`.
    /// Not implemented; reported so the caller knows why a launch may fail.
    legacy_assets: bool = false,
};

pub const Error = error{
    VersionNotFound,
    MissingClientDownload,
    DownloadFailed,
    NoAssetIndex,
};

const Job = struct {
    url: []const u8,
    dest: []const u8,
    sha1: ?[]const u8 = null,
    size: ?u64 = null,
};

pub fn install(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
) !Stats {
    var stats: Stats = .{ .version = opts.version };

    // --- manifest -> version json -------------------------------------
    const manifest = try meta.loadManifest(io, gpa, arena, opts.cache_dir);
    const version = meta.findVersion(manifest, opts.version) orelse return Error.VersionNotFound;

    const version_json_path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{
        try std.fs.path.join(arena, &.{ opts.game_dir, "versions", version.id }), version.id,
    });
    const doc = try meta.loadVersionJson(io, gpa, arena, version, version_json_path);

    say(opts, "version {s} ({s})\n", .{ doc.id, doc.type orelse "?" });

    // --- client jar ---------------------------------------------------
    const version_dir = try std.fs.path.join(arena, &.{ opts.game_dir, "versions", doc.id });
    const client = (doc.downloads orelse return Error.MissingClientDownload).client orelse
        return Error.MissingClientDownload;
    const client_path = try std.fmt.allocPrint(arena, "{s}/{s}.jar", .{ version_dir, doc.id });
    var solo: http.Client = .{ .allocator = gpa, .io = io };
    defer solo.deinit();
    const client_out = try fetch.getShared(&solo, io, gpa, .{
        .url = client.url,
        .dest = client_path,
        .sha1 = client.sha1,
        .size = client.size,
    });
    stats.client_bytes = client_out.bytes;
    say(opts, "client jar {d} bytes{s}\n", .{ client_out.bytes, if (client_out.cached) " (cached)" else "" });

    // --- libraries ----------------------------------------------------
    try installLibraries(io, gpa, arena, opts, doc, version_dir, &stats);

    // --- assets -------------------------------------------------------
    if (opts.want_assets) {
        const index = doc.assetIndex orelse return Error.NoAssetIndex;
        const index_path = try std.fmt.allocPrint(arena, "{s}/assets/indexes/{s}.json", .{
            opts.game_dir, index.id,
        });
        _ = try fetch.get(io, gpa, .{
            .url = index.url,
            .dest = index_path,
            .sha1 = index.sha1,
            .size = index.size,
        });
        const body = try Io.Dir.cwd().readFileAlloc(io, index_path, arena, Io.Limit.unlimited);
        const idx = try std.json.parseFromSliceLeaky(meta.AssetIndexFile, arena, body, .{
            .ignore_unknown_fields = true,
        });

        if (idx.virtual or idx.map_to_resources) {
            stats.legacy_assets = true;
            say(opts, "note: {s} uses legacy (virtual) assets; those are not unpacked\n", .{index.id});
        }

        var asset_jobs: std.ArrayList(Job) = .empty;
        var it = idx.objects.map.iterator();
        while (it.next()) |entry| {
            const obj = entry.value_ptr.*;
            const prefix = obj.hash[0..2];
            const dest = try std.fmt.allocPrint(arena, "{s}/assets/objects/{s}/{s}", .{
                opts.game_dir, prefix, obj.hash,
            });
            const url = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ assets_base, prefix, obj.hash });
            try asset_jobs.append(arena, .{ .url = url, .dest = dest, .sha1 = obj.hash, .size = obj.size });
            stats.assets_bytes += obj.size;
        }
        stats.assets = asset_jobs.items.len;
        say(opts, "assets: {d} objects ({d} MiB)\n", .{ stats.assets, stats.assets_bytes >> 20 });
        try runBatch(io, gpa, arena, asset_jobs.items, opts);
    }

    return stats;
}

/// Unpack one natives jar. Tolerates existing directories: two legacy natives
/// jars both carry `META-INF/`, and pulling them into one directory must not
/// fail the install.
fn extractJar(fr: *Io.File.Reader, dest: Io.Dir, opts: Options) void {

    var iter = std.zip.Iterator.init(fr) catch |err| {
        say(opts, "warning: not a readable zip: {s}\n", .{@errorName(err)});
        return;
    };
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        const maybe_entry = iter.next() catch |err| {
            say(opts, "warning: zip iteration failed: {s}\n", .{@errorName(err)});
            return;
        };
        const entry = maybe_entry orelse break;
        entry.extract(fr, .{ .allow_backslashes = true }, &name_buf, dest) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => {
                const name = name_buf[0..@min(entry.filename_len, name_buf.len)];
                say(opts, "warning: skipped {s}: {s}\n", .{ name, @errorName(err) });
                continue;
            },
        };
    }
}

/// Download the libraries (and legacy natives) declared by one version json.
/// Shared by the vanilla install and by `fabric.zig`, which needs the same
/// treatment for the profile JSON the Fabric meta server hands out.
pub fn installLibraries(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
    doc: meta.VersionJson,
    version_dir: []const u8,
    stats: *Stats,
) !void {
    var jobs: std.ArrayList(Job) = .empty;
    var native_list: std.ArrayList(Job) = .empty;

    for (doc.libraries orelse &.{}) |lib| {
        if (!meta.allowed(lib.rules)) {
            stats.libraries_skipped += 1;
            continue;
        }

        if (lib.downloads) |dls| {
            if (dls.artifact) |artifact| {
                const dest = try std.fs.path.join(arena, &.{ opts.game_dir, "libraries", artifact.path });
                try jobs.append(arena, .{
                    .url = artifact.url,
                    .dest = dest,
                    .sha1 = artifact.sha1,
                    .size = artifact.size,
                });
                stats.libraries += 1;
            }
        } else if (try meta.mavenPath(arena, lib, null)) |m| {
            // Entries with no `downloads` block: Fabric ships its libraries
            // as bare maven coordinates plus a base url.
            const dest = try std.fs.path.join(arena, &.{ opts.game_dir, "libraries", m.rel });
            try jobs.append(arena, .{ .url = m.url, .dest = dest });
            stats.libraries += 1;
        }

        // Legacy natives: a classifier jar that must be unpacked.
        if (lib.natives) |natives| {
            const key = natives.map.get(meta.osName()) orelse continue;
            if (key.len == 0) continue;

            var url: ?[]const u8 = null;
            var sha1: ?[]const u8 = null;
            var size: ?u64 = null;

            if (lib.downloads) |dls| {
                if (dls.classifiers) |classifiers| {
                    if (classifiers.map.get(key)) |artifact| {
                        url = artifact.url;
                        sha1 = artifact.sha1;
                        size = artifact.size;
                    }
                }
            }
            if (url == null) {
                if (try meta.mavenPath(arena, lib, key)) |m| url = m.url;
            }
            const jar_url = url orelse continue;

            const dest = try std.fmt.allocPrint(arena, "{s}/natives/{s}.jar", .{
                opts.cache_dir, try sanitize(arena, key),
            });
            try native_list.append(arena, .{ .url = jar_url, .dest = dest, .sha1 = sha1, .size = size });
            stats.natives_jars += 1;
        }
    }

    say(opts, "libraries: {d} to fetch, {d} skipped by rules\n", .{ jobs.items.len, stats.libraries_skipped });
    try runBatch(io, gpa, arena, jobs.items, opts);

    if (native_list.items.len != 0) {
        try runBatch(io, gpa, arena, native_list.items, opts);
        const natives_dir = try std.fs.path.join(arena, &.{ version_dir, "natives" });
        try Io.Dir.cwd().createDirPath(io, natives_dir);
        const out_dir = try Io.Dir.cwd().openDir(io, natives_dir, .{});
        defer out_dir.close(io);
        for (native_list.items) |job| {
            var jar = try Io.Dir.openFileAbsolute(io, job.dest, .{});
            defer jar.close(io);
            var rbuf: [64 * 1024]u8 = undefined;
            var fr: Io.File.Reader = .init(jar, io, &rbuf);
            extractJar(&fr, out_dir, opts);
        }
        say(opts, "natives unpacked into {s}\n", .{natives_dir});
    }
}


fn sanitize(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, name);
    for (out) |*ch| {
        if (ch.* == '/' or ch.* == '\\') ch.* = '-';
    }
    return out;
}

const Maven = struct { url: []const u8, dest: []const u8 };

/// Resolve `group:artifact:version[:classifier]` against the library's maven
/// base (default `libraries.minecraft.net`).
fn mavenArtifact(
    arena: std.mem.Allocator,
    game_dir: []const u8,
    lib: meta.Library,
    classifier: ?[]const u8,
) !?Maven {
    var parts = std.mem.splitScalar(u8, lib.name, ':');
    const group = parts.next() orelse return null;
    const artifact = parts.next() orelse return null;
    const version = parts.next() orelse return null;
    const name_classifier = parts.next();

    const cls = classifier orelse name_classifier;
    const file = if (cls) |c|
        try std.fmt.allocPrint(arena, "{s}-{s}-{s}.jar", .{ artifact, version, c })
    else
        try std.fmt.allocPrint(arena, "{s}-{s}.jar", .{ artifact, version });

    const group_path = try arena.dupe(u8, group);
    for (group_path) |*ch| {
        if (ch.* == '.') ch.* = '/';
    }

    const base = lib.url orelse "https://libraries.minecraft.net/";
    const rel = try std.fmt.allocPrint(arena, "{s}/{s}/{s}/{s}", .{ group_path, artifact, version, file });
    const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), rel });
    const dest = try std.fs.path.join(arena, &.{ game_dir, "libraries", rel });
    return .{ .url = url, .dest = dest };
}

// ---------------------------------------------------------------- batch

fn runBatch(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    jobs: []const Job,
    opts: Options,
) !void {
    if (jobs.len == 0) return;

    const width = @min(@max(opts.threads, 1), jobs.len);
    if (width <= 1) {
        var client: http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        var failures: usize = 0;
        for (jobs, 0..) |job, i| {
            _ = fetch.getShared(&client, io, gpa, .{
                .url = job.url,
                .dest = job.dest,
                .sha1 = job.sha1,
                .size = job.size,
            }) catch {
                failures += 1;
                continue;
            };
            progress(opts, i + 1, jobs.len);
        }
        if (opts.progress) std.debug.print("\n", .{});
        if (failures != 0) return Error.DownloadFailed;
        return;
    }

    var ctx: Batch = .{
        .io = io,
        .gpa = gpa,
        .jobs = jobs,
        .total = jobs.len,
        .progress = opts.progress,
        .mutex = .init,
    };

    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(arena);
    for (0..width) |_| {
        const t = try std.Thread.spawn(.{}, worker, .{&ctx});
        try threads.append(arena, t);
    }
    for (threads.items) |t| t.join();

    if (opts.progress) std.debug.print("\n", .{});
    if (ctx.failures.load(.monotonic) != 0) return Error.DownloadFailed;
}

const Batch = struct {
    io: Io,
    gpa: std.mem.Allocator,
    jobs: []const Job,
    total: usize,
    progress: bool,
    next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    failures: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    mutex: Io.Mutex,
};

fn worker(ctx: *Batch) void {
    var client: http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.jobs.len) return;
        const job = ctx.jobs[i];

        _ = fetch.getShared(&client, ctx.io, ctx.gpa, .{
            .url = job.url,
            .dest = job.dest,
            .sha1 = job.sha1,
            .size = job.size,
        }) catch |err| {
            ctx.mutex.lockUncancelable(ctx.io);
            ctx.failures.store(ctx.failures.load(.monotonic) + 1, .monotonic);
            std.debug.print("\nerror: {s} <- {s} ({s})\n", .{ job.dest, job.url, @errorName(err) });
            ctx.mutex.unlock(ctx.io);
            continue;
        };

        const n = ctx.done.fetchAdd(1, .monotonic) + 1;
        if (ctx.progress) {
            ctx.mutex.lockUncancelable(ctx.io);
            std.debug.print("\r  {d}/{d}", .{ n, ctx.total });
            ctx.mutex.unlock(ctx.io);
        }
    }
}

fn progress(opts: Options, done: usize, total: usize) void {
    if (!opts.progress) return;
    std.debug.print("\r  {d}/{d}", .{ done, total });
}

fn say(opts: Options, comptime fmt: []const u8, args: anytype) void {
    _ = opts;
    std.debug.print(fmt, args);
}
