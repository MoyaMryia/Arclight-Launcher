//! Instance directories and their `instance.json` records.
//!
//! An instance is a run directory under `<game>/instances/<id>`. Version
//! definitions, libraries and assets stay in the shared installation root.

const std = @import("std");
const Io = std.Io;
const store = @import("store.zig");

pub const Error = error{
    InvalidId,
    InvalidName,
    InvalidVersion,
    InvalidMemory,
    VersionNotInstalled,
    InstanceExists,
    InstanceNotFound,
    NoInstanceRecord,
    RestoreTargetExists,
    TrashNotFound,
};

pub const Entry = struct {
    id: []const u8,
    path: []const u8,
    record: ?store.Instance,
    load_error: ?[]const u8 = null,
};

pub const TrashResult = struct {
    original: []const u8,
    path: []const u8,
};

pub const RestoreResult = struct {
    id: []const u8,
    from: []const u8,
    path: []const u8,
};

pub fn root(arena: std.mem.Allocator, game_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ game_dir, "instances" });
}

pub fn dir(arena: std.mem.Allocator, game_dir: []const u8, id: []const u8) ![]const u8 {
    try validateId(id);
    return std.fs.path.join(arena, &.{ game_dir, "instances", id });
}

pub fn trashRoot(arena: std.mem.Allocator, game_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ game_dir, ".trash", "instances" });
}

pub fn validateId(id: []const u8) !void {
    if (id.len == 0 or id.len > 128) return Error.InvalidId;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return Error.InvalidId;
    if (!std.mem.eql(u8, id, std.mem.trim(u8, id, " \t\r\n"))) return Error.InvalidId;
    if (std.mem.indexOfAny(u8, id, "/\\") != null) return Error.InvalidId;
    for (id) |ch| {
        if (std.ascii.isControl(ch)) return Error.InvalidId;
    }
}

pub fn cleanName(name: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 128) return Error.InvalidName;
    for (trimmed) |ch| {
        if (std.ascii.isControl(ch)) return Error.InvalidName;
    }
    return trimmed;
}

pub fn validateVersion(version: []const u8) !void {
    if (version.len == 0 or version.len > 128) return Error.InvalidVersion;
    if (std.mem.eql(u8, version, ".") or std.mem.eql(u8, version, "..")) return Error.InvalidVersion;
    if (std.mem.indexOfAny(u8, version, "/\\") != null) return Error.InvalidVersion;
    for (version) |ch| {
        if (std.ascii.isControl(ch)) return Error.InvalidVersion;
    }
}

pub fn validateMemory(min: ?u32, max: ?u32) !void {
    if (min) |value| {
        if (value == 0) return Error.InvalidMemory;
    }
    if (max) |value| {
        if (value == 0) return Error.InvalidMemory;
    }
    if (min != null and max != null and min.? > max.?) return Error.InvalidMemory;
}

pub fn effectiveName(id: []const u8, record: ?store.Instance) []const u8 {
    if (record) |inst| {
        if (inst.name.len != 0) return inst.name;
    }
    return id;
}

pub fn versionInstalled(
    io: Io,
    arena: std.mem.Allocator,
    game_dir: []const u8,
    version: []const u8,
) !bool {
    try validateVersion(version);
    const path = try std.fmt.allocPrint(arena, "{s}/versions/{s}/{s}.json", .{
        game_dir, version, version,
    });
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

pub fn list(
    io: Io,
    arena: std.mem.Allocator,
    game_dir: []const u8,
) ![]Entry {
    const base = try root(arena, game_dir);
    var out: std.ArrayList(Entry) = .empty;

    var dir_handle = Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(arena),
        else => return err,
    };
    defer dir_handle.close(io);

    var it = dir_handle.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const id = arena.dupe(u8, entry.name) catch continue;
        const path = std.fs.path.join(arena, &.{ base, id }) catch continue;

        var load_error: ?[]const u8 = null;
        const record = store.loadInstance(io, arena, path) catch |err| blk: {
            load_error = @errorName(err);
            break :blk null;
        };
        out.append(arena, .{
            .id = id,
            .path = path,
            .record = record,
            .load_error = load_error,
        }) catch continue;
    }

    std.mem.sort(Entry, out.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

pub fn loadRequired(
    io: Io,
    arena: std.mem.Allocator,
    game_dir: []const u8,
    id: []const u8,
) !store.Instance {
    const path = try dir(arena, game_dir, id);
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return Error.InstanceNotFound;
    return (try store.loadInstance(io, arena, path)) orelse Error.NoInstanceRecord;
}

pub fn create(
    io: Io,
    arena: std.mem.Allocator,
    game_dir: []const u8,
    id: []const u8,
    name: []const u8,
    version: []const u8,
    java: ?[]const u8,
    min_memory_mb: ?u32,
    max_memory_mb: ?u32,
    jvm_args: []const []const u8,
) !store.Instance {
    try validateId(id);
    const display_name = try cleanName(name);
    try validateVersion(version);
    try validateMemory(min_memory_mb, max_memory_mb);
    if (!try versionInstalled(io, arena, game_dir, version)) return Error.VersionNotInstalled;

    const path = try dir(arena, game_dir, id);
    if (pathExists(io, path)) return Error.InstanceExists;
    try Io.Dir.cwd().createDirPath(io, path);

    const inst: store.Instance = .{
        .schema_version = 1,
        .name = display_name,
        .version = version,
        .java = java,
        .min_memory_mb = min_memory_mb,
        .max_memory_mb = max_memory_mb,
        .jvm_args = jvm_args,
    };
    store.saveInstance(io, path, inst) catch |err| {
        Io.Dir.cwd().deleteTree(io, path) catch {};
        return err;
    };
    return inst;
}

pub fn remove(
    io: Io,
    arena: std.mem.Allocator,
    game_dir: []const u8,
    id: []const u8,
    permanent: bool,
) !TrashResult {
    const path = try dir(arena, game_dir, id);
    if (!pathExists(io, path)) return Error.InstanceNotFound;

    if (permanent) {
        try Io.Dir.cwd().deleteTree(io, path);
        return .{ .original = path, .path = "" };
    }

    const trash_base = try trashRoot(arena, game_dir);
    const trash_parent = try std.fs.path.join(arena, &.{ trash_base, id });
    try Io.Dir.cwd().createDirPath(io, trash_parent);

    const now = std.Io.Clock.real.now(io);
    var stamp: u64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
    var dest: []const u8 = undefined;
    while (true) {
        dest = try std.fmt.allocPrint(arena, "{s}/{d}", .{ trash_parent, stamp });
        if (!pathExists(io, dest)) break;
        stamp += 1;
    }
    try Io.Dir.cwd().rename(path, Io.Dir.cwd(), dest, io);
    return .{ .original = path, .path = dest };
}

pub fn restore(
    io: Io,
    arena: std.mem.Allocator,
    game_dir: []const u8,
    id: []const u8,
) !RestoreResult {
    try validateId(id);
    const trash_base = try trashRoot(arena, game_dir);
    const trash_parent = try std.fs.path.join(arena, &.{ trash_base, id });

    var dir_handle = Io.Dir.cwd().openDir(io, trash_parent, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return Error.TrashNotFound,
        else => return err,
    };
    defer dir_handle.close(io);

    var best: u64 = 0;
    var best_name: ?[]const u8 = null;
    var it = dir_handle.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const stamp = std.fmt.parseInt(u64, entry.name, 10) catch continue;
        if (stamp >= best) {
            best = stamp;
            best_name = arena.dupe(u8, entry.name) catch continue;
        }
    }
    const selected = best_name orelse return Error.TrashNotFound;

    const from = try std.fs.path.join(arena, &.{ trash_parent, selected });
    const target = try dir(arena, game_dir, id);
    if (pathExists(io, target)) return Error.RestoreTargetExists;
    try Io.Dir.cwd().createDirPath(io, try root(arena, game_dir));
    try Io.Dir.cwd().rename(from, Io.Dir.cwd(), target, io);
    return .{ .id = id, .from = from, .path = target };
}

fn pathExists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

test "instance ids and versions reject path escapes" {
    try std.testing.expectError(Error.InvalidId, validateId(""));
    try std.testing.expectError(Error.InvalidId, validateId("."));
    try std.testing.expectError(Error.InvalidId, validateId(".."));
    try std.testing.expectError(Error.InvalidId, validateId("a/b"));
    try std.testing.expectError(Error.InvalidId, validateId("a\\b"));
    try validateId("1.20.1 Fabric");
    try std.testing.expectError(Error.InvalidVersion, validateVersion(".."));
    try validateVersion("1.20.1 Fabric");
}

test "display names are trimmed and memory is ordered" {
    try std.testing.expectEqualStrings("Survival", try cleanName("  Survival  "));
    try std.testing.expectError(Error.InvalidName, cleanName("   "));
    try validateMemory(1024, 4096);
    try validateMemory(null, 4096);
    try validateMemory(null, null);
    try std.testing.expectError(Error.InvalidMemory, validateMemory(4096, 1024));
    try std.testing.expectError(Error.InvalidMemory, validateMemory(0, 4096));
}
