//! Fabric loader support.
//!
//! Fabric needs no installer jar: the meta server hands out a complete version
//! JSON that inherits from the vanilla one, so "installing Fabric" is one GET
//! plus one file write, then the same library download path the vanilla
//! install uses.
//!
//! Host: `meta.fabricmc.net` only.

const std = @import("std");
const Io = std.Io;
const http = std.http;

const fetch = @import("fetch.zig");
const meta = @import("meta.zig");
const install = @import("install.zig");

pub const Error = error{
    NoLoaderVersion,
    ProfileFailed,
    HttpFailed,
};

const base = "https://meta.fabricmc.net/v2/versions/loader";

/// Pick the first stable loader for `game_version`, else the newest one.
pub fn resolveLoader(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    game_version: []const u8,
) ![]const u8 {
    const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, game_version });

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const res = fetch.request(&client, arena, url, .{}) catch return Error.HttpFailed;
    if (res.status != 200) return Error.NoLoaderVersion;

    const Entry = struct {
        loader: struct {
            version: []const u8,
            stable: ?bool = null,
        },
    };
    const list = std.json.parseFromSliceLeaky([]Entry, arena, res.body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.NoLoaderVersion;
    if (list.len == 0) return Error.NoLoaderVersion;

    for (list) |entry| {
        if (entry.loader.stable orelse false) return entry.loader.version;
    }
    return list[0].loader.version;
}

/// Fetch the profile JSON for `game_version` + `loader` and write it where the
/// launcher expects a version to live. Returns the version id it wrote.
pub fn installProfile(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    game_dir: []const u8,
    game_version: []const u8,
    loader: []const u8,
) ![]const u8 {
    const url = try std.fmt.allocPrint(arena, "{s}/{s}/{s}/profile/json", .{
        base, game_version, loader,
    });

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const res = fetch.request(&client, arena, url, .{}) catch return Error.HttpFailed;
    if (res.status != 200) return Error.ProfileFailed;

    const doc = std.json.parseFromSliceLeaky(meta.VersionJson, arena, res.body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.ProfileFailed;

    // The profile must inherit from the vanilla version we just installed,
    // otherwise the classpath would have no client jar to point at.
    if (doc.inheritsFrom == null) return Error.ProfileFailed;

    const dir = try std.fs.path.join(arena, &.{ game_dir, "versions", doc.id });
    try Io.Dir.cwd().createDirPath(io, dir);

    const dest = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ dir, doc.id });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = res.body });

    var stats: install.Stats = .{ .version = doc.id };
    try install.installLibraries(io, gpa, arena, .{
        .game_dir = game_dir,
        .cache_dir = "",
        .version = doc.id,
        .progress = true,
    }, doc, dir, &stats);

    return doc.id;
}
