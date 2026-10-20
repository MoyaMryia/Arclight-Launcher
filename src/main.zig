//! arclight - a minimal Minecraft: Java Edition launcher.
//!
//! Scope is deliberately narrow, see README.md. Anything that would turn this
//! into a distribution channel for game content is out of scope by design.

const std = @import("std");
const Io = std.Io;

const store = @import("store.zig");
const java = @import("java.zig");
const meta = @import("meta.zig");
const install_mod = @import("install.zig");

/// Exit codes are part of the interface: scripts branch on them.
pub const Exit = struct {
    pub const ok: u8 = 0;
    pub const usage: u8 = 2;
    pub const config: u8 = 3;
    pub const auth: u8 = 10;
    /// HTTP 403 `Invalid app registration` - the Client ID is not allowlisted.
    pub const appid_not_authorized: u8 = 11;
    pub const no_ownership: u8 = 12;
    pub const download: u8 = 20;
    pub const java_missing: u8 = 30;
    pub const unimplemented: u8 = 70;
};

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    json: bool = false,

    pub fn out(self: Ctx, bytes: []const u8) void {
        Io.File.stdout().writeStreamingAll(self.io, bytes) catch {};
    }

    pub fn err(self: Ctx, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.debug.print(fmt, args);
    }

    /// Machine-readable payload on stdout, human text on stderr.
    pub fn emitJson(self: Ctx, value: anytype) void {
        const body = std.json.Stringify.valueAlloc(self.gpa, value, .{
            .whitespace = .indent_2,
        }) catch return;
        defer self.gpa.free(body);
        self.out(body);
        self.out("\n");
    }
};

const usage_text =
    \\arclight - minimal Minecraft: Java Edition launcher
    \\
    \\USAGE:
    \\    arclight <command> [options]
    \\
    \\COMMANDS:
    \\    login              Sign in with a Microsoft account (device code flow)
    \\    versions           List Minecraft versions from Mojang's manifest
    \\    install <version>  Fetch a version, its libraries and assets
    \\    status             Show the stored account (never prints tokens)
    \\    logout             Forget the stored account
    \\    java               List detected Java runtimes
    \\    launch <version>   Start a version already installed by the official launcher
    \\    help               Show this text
    \\    version            Show version information
    \\
    \\OPTIONS:
    \\    --json             Machine-readable output on stdout
    \\
    \\EXIT CODES:
    \\     0 success      2 usage        3 config      10 auth failed
    \\    11 AppID not authorized by Minecraft      12 account does not own the game
    \\    20 download failed                       30 no Java runtime found
    \\    70 not implemented yet
    \\
    \\This tool does not download, mirror or host any game files.
    \\
;

const build_version = "0.0.0";

pub fn main(init: std.process.Init) !void {
    const ctx: Ctx = .{
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
        .io = init.io,
        .environ = init.environ_map,
    };

    const argv = try init.minimal.args.toSlice(ctx.arena);

    var args: std.ArrayList([]const u8) = .empty;
    var json = false;

    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            ctx.out(usage_text);
            return;
        } else {
            try args.append(ctx.arena, arg);
        }
    }

    var c = ctx;
    c.json = json;

    const cmd = if (args.items.len == 0) "help" else args.items[0];
    const rest = if (args.items.len > 1) args.items[1..] else &[_][]const u8{};

    const code = dispatch(c, cmd, rest);
    std.process.exit(code);
}

fn dispatch(c: Ctx, cmd: []const u8, args: []const []const u8) u8 {
    if (eq(cmd, "help")) {
        c.out(usage_text);
        return Exit.ok;
    }
    if (eq(cmd, "version")) return cmdVersion(c);
    if (eq(cmd, "status")) return cmdStatus(c);
    if (eq(cmd, "java")) return cmdJava(c);
    if (eq(cmd, "versions")) return cmdVersions(c);
    if (eq(cmd, "logout")) return cmdLogout(c);
    if (eq(cmd, "login")) return notImplemented(c, "login", "auth.zig: device code flow");
    if (eq(cmd, "install")) return cmdInstall(c, args);
    if (eq(cmd, "launch")) {
        if (args.len != 1) {
            c.err("error: launch needs exactly one version id\n", .{});
            return Exit.usage;
        }
        return notImplemented(c, "launch", "launch.zig: version json + classpath");
    }

    c.err("error: unknown command '{s}'\n\n", .{cmd});
    c.out(usage_text);
    return Exit.usage;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const VersionInfo = struct {
    name: []const u8,
    zig: []const u8,
    platform: []const u8,
};

fn cmdVersion(c: Ctx) u8 {
    const info: VersionInfo = .{
        .name = build_version,
        .zig = "0.17.0",
        .platform = @tagName(@import("builtin").os.tag),
    };
    if (c.json) {
        c.emitJson(info);
    } else {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "arclight {s} (zig {s}, {s})\n", .{
            info.name, info.zig, info.platform,
        }) catch return Exit.ok;
        c.out(line);
    }
    return Exit.ok;
}

const AccountStatus = struct {
    logged_in: bool = false,
    client_id: []const u8 = "",
    name: []const u8 = "",
    uuid: []const u8 = "",
    config_dir: []const u8 = "",
};

fn cmdStatus(c: Ctx) u8 {
    const dir = store.configDir(c.arena, c.environ) catch {
        c.err("error: cannot resolve config directory (HOME unset?)\n", .{});
        return Exit.config;
    };

    var status: AccountStatus = .{ .config_dir = dir };

    const maybe_acc = store.load(c.io, c.arena, dir) catch |e| {
        c.err("error: cannot read account file: {s}\n", .{@errorName(e)});
        return Exit.config;
    };

    if (maybe_acc) |acc| {
        status.logged_in = true;
        status.client_id = acc.client_id;
        status.name = acc.name;
        status.uuid = acc.uuid;
    }

    if (c.json) {
        c.emitJson(status);
    } else if (status.logged_in) {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "logged in as {s} ({s})\nclient id: {s}\nconfig dir: {s}\n",
            .{ status.name, status.uuid, status.client_id, status.config_dir },
        ) catch return Exit.ok;
        c.out(line);
    } else {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "not logged in\nconfig dir: {s}\n",
            .{status.config_dir},
        ) catch return Exit.ok;
        c.out(line);
    }
    return Exit.ok;
}

fn cmdLogout(c: Ctx) u8 {
    const dir = store.configDir(c.arena, c.environ) catch {
        c.err("error: cannot resolve config directory (HOME unset?)\n", .{});
        return Exit.config;
    };
    store.clear(c.io, c.arena, dir) catch |e| {
        c.err("error: {s}\n", .{@errorName(e)});
        return Exit.config;
    };
    if (c.json) {
        c.emitJson(.{ .ok = true });
    } else {
        c.out("logged out\n");
    }
    return Exit.ok;
}

fn cmdJava(c: Ctx) u8 {
    const list = java.candidates(c.arena, c.environ, c.io) catch {
        c.err("error: cannot enumerate Java candidates\n", .{});
        return Exit.java_missing;
    };

    if (list.len == 0) {
        c.err(
            "error: no Java runtime found\n" ++
                "hint: install a JDK or set JAVA_HOME / ARCLIGHT_JAVA\n" ++
                "note: arclight never downloads a runtime\n",
            .{},
        );
        if (c.json) c.emitJson(.{ .found = [_][]const u8{}, .count = @as(usize, 0) });
        return Exit.java_missing;
    }

    if (c.json) {
        c.emitJson(.{ .found = list, .count = list.len });
    } else {
        for (list) |p| {
            c.out(p);
            c.out("\n");
        }
    }
    return Exit.ok;
}

fn notImplemented(c: Ctx, what: []const u8, detail: []const u8) u8 {
    c.err("error: '{s}' is not implemented yet ({s})\n", .{ what, detail });
    if (c.json) c.emitJson(.{ .err = "not_implemented", .cmd = what });
    return Exit.unimplemented;
}

fn cmdVersions(c: Ctx) u8 {
    const dir = store.configDir(c.arena, c.environ) catch {
        c.err("error: cannot resolve config directory (HOME unset?)\n", .{});
        return Exit.config;
    };
    const cache_dir = std.fs.path.join(c.arena, &.{ dir, "cache" }) catch return Exit.config;

    const manifest = meta.loadManifest(c.io, c.gpa, c.arena, cache_dir) catch |e| {
        c.err("error: cannot load version manifest: {s}\n", .{@errorName(e)});
        return Exit.download;
    };

    const limit: usize = 10;
    const shown = @min(manifest.versions.len, limit);

    if (c.json) {
        c.emitJson(.{
            .latest = manifest.latest,
            .total = manifest.versions.len,
            .versions = manifest.versions[0..shown],
        });
    } else {
        var buf: [256]u8 = undefined;
        c.out(std.fmt.bufPrint(&buf, "latest release: {s}\nlatest snapshot: {s}\n\n", .{
            manifest.latest.release, manifest.latest.snapshot,
        }) catch "");
        for (manifest.versions[0..shown]) |v| {
            c.out(std.fmt.bufPrint(&buf, "{s:<12} {s}\n", .{ v.id, v.type }) catch "");
        }
        var buf2: [128]u8 = undefined;
        c.out(std.fmt.bufPrint(&buf2, "\n({d} versions total)\n", .{manifest.versions.len}) catch "");
    }
    return Exit.ok;
}

const InstallFlags = struct {
    version: []const u8 = "",
    dir: ?[]const u8 = null,
    assets: bool = true,
    threads: usize = 8,
};

fn parseInstallFlags(args: []const []const u8) ?InstallFlags {
    var f: InstallFlags = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--dir")) {
            i += 1;
            if (i >= args.len) return null;
            f.dir = args[i];
        } else if (eq(a, "--no-assets")) {
            f.assets = false;
        } else if (eq(a, "--threads")) {
            i += 1;
            if (i >= args.len) return null;
            f.threads = std.fmt.parseInt(usize, args[i], 10) catch return null;
        } else if (a.len != 0 and a[0] == '-') {
            return null;
        } else if (f.version.len == 0) {
            f.version = a;
        } else {
            return null;
        }
    }
    if (f.version.len == 0) return null;
    return f;
}

fn cmdInstall(c: Ctx, args: []const []const u8) u8 {
    const flags = parseInstallFlags(args) orelse {
        c.err("usage: arclight install <version> [--dir <path>] [--no-assets] [--threads N]\n", .{});
        return Exit.usage;
    };

    const config = store.configDir(c.arena, c.environ) catch {
        c.err("error: cannot resolve config directory (HOME unset?)\n", .{});
        return Exit.config;
    };

    var arena_state = std.heap.ArenaAllocator.init(c.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const game_dir = flags.dir orelse blk: {
        const home = c.environ.get("HOME") orelse {
            c.err("error: --dir is required when HOME is unset\n", .{});
            return Exit.usage;
        };
        break :blk std.fs.path.join(arena, &.{ home, ".minecraft" }) catch return Exit.config;
    };
    const cache_dir = std.fs.path.join(arena, &.{ config, "cache" }) catch return Exit.config;

    if (!c.json) c.err("installing {s} into {s}\n", .{ flags.version, game_dir });

    const stats = install_mod.install(c.io, c.gpa, arena, .{
        .game_dir = game_dir,
        .cache_dir = cache_dir,
        .version = flags.version,
        .want_assets = flags.assets,
        .threads = flags.threads,
    }) catch |e| {
        c.err("error: install failed: {s}\n", .{@errorName(e)});
        return switch (e) {
            install_mod.Error.VersionNotFound => Exit.usage,
            else => Exit.download,
        };
    };

    if (c.json) {
        c.emitJson(.{
            .version = stats.version,
            .client_bytes = stats.client_bytes,
            .libraries = stats.libraries,
            .libraries_skipped = stats.libraries_skipped,
            .natives_jars = stats.natives_jars,
            .assets = stats.assets,
            .assets_bytes = stats.assets_bytes,
            .legacy_assets = stats.legacy_assets,
        });
    } else {
        var buf: [256]u8 = undefined;
        c.out(std.fmt.bufPrint(&buf, "done: {d} libraries, {d} assets, client jar {d} bytes\n", .{
            stats.libraries, stats.assets, stats.client_bytes,
        }) catch "");
    }
    return Exit.ok;
}
