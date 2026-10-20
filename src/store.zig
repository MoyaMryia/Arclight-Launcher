//! Account storage.
//!
//! Tokens are written with mode 0600. Nothing in this file may ever log a
//! token value: the `--json` output is filtered through `Public` below.

const std = @import("std");
const Io = std.Io;

pub const Account = struct {
    /// The Entra application (client) ID this account was logged in with.
    /// Refresh tokens are bound to it; a change requires a new login.
    client_id: []const u8 = "",
    /// Minecraft profile name.
    name: []const u8 = "",
    /// Minecraft profile UUID, 32 lowercase hex chars, no dashes.
    uuid: []const u8 = "",
    /// Microsoft refresh token. NEVER print this.
    refresh_token: []const u8 = "",
    /// Unix seconds of the last successful refresh.
    updated_at: i64 = 0,
};

/// Redacted view, safe for `--json` output and logs.
pub const Public = struct {
    client_id: []const u8,
    name: []const u8,
    uuid: []const u8,
    updated_at: i64,
    has_refresh_token: bool,

    pub fn from(acc: Account) Public {
        return .{
            .client_id = acc.client_id,
            .name = acc.name,
            .uuid = acc.uuid,
            .updated_at = acc.updated_at,
            .has_refresh_token = acc.refresh_token.len != 0,
        };
    }
};

pub const Error = error{
    NoHomeDirectory,
    CorruptAccountFile,
};

/// Resolve `$XDG_CONFIG_HOME/mccli`, falling back to `$HOME/.config/mccli`.
/// Caller owns the returned slice (use an arena).
pub fn configDir(
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    if (environ.get("MCCLI_CONFIG_DIR")) |custom| {
        if (custom.len != 0) return arena.dupe(u8, custom);
    }
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len != 0) return std.fs.path.join(arena, &.{ xdg, "mccli" });
    }
    const home = environ.get("HOME") orelse return Error.NoHomeDirectory;
    return std.fs.path.join(arena, &.{ home, ".config", "mccli" });
}

pub fn accountPath(arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ dir, "account.json" });
}

pub fn load(
    io: Io,
    arena: std.mem.Allocator,
    dir: []const u8,
) !?Account {
    const path = try accountPath(arena, dir);
    const raw = Io.Dir.cwd().readFileAlloc(io, path, arena, Io.Limit.limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const parsed = std.json.parseFromSliceLeaky(Account, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch return Error.CorruptAccountFile;
    return parsed;
}

pub fn save(io: Io, dir: []const u8, acc: Account) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const body = try std.json.Stringify.valueAlloc(arena, acc, .{ .whitespace = .indent_2 });
    const path = try accountPath(arena, dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = body,
        .flags = .{ .permissions = Io.File.Permissions.fromMode(0o600) },
    });
}

pub fn clear(io: Io, arena: std.mem.Allocator, dir: []const u8) !void {
    const path = try accountPath(arena, dir);
    Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

test "public view never carries the refresh token" {
    const acc: Account = .{
        .client_id = "cid",
        .name = "Steve",
        .uuid = "0123456789abcdef0123456789abcdef",
        .refresh_token = "SECRET",
        .updated_at = 1,
    };
    const p = Public.from(acc);
    try std.testing.expect(p.has_refresh_token);
    try std.testing.expectEqualStrings("Steve", p.name);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const body = try std.json.Stringify.valueAlloc(arena_state.allocator(), p, .{});
    try std.testing.expect(std.mem.indexOf(u8, body, "SECRET") == null);
}

test "config dir honours MCCLI_CONFIG_DIR" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();

    try environ.put("MCCLI_CONFIG_DIR", "/tmp/mccli-test");
    try std.testing.expectEqualStrings("/tmp/mccli-test", try configDir(arena, &environ));
}
