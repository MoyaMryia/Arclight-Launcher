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
const auth = @import("auth.zig");
const launch_mod = @import("launch.zig");
const fabric = @import("fabric.zig");

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
    \\    launch <version>   Start an installed version
    \\    status             Show the stored account (never prints tokens)
    \\    logout             Forget the stored account
    \\    java               List detected Java runtimes
    \\    help               Show this text
    \\    version            Show version information
    \\
    \\OPTIONS:
    \\    --json             Machine-readable output on stdout
    \\    --dir <path>       Game directory for install/launch (default ~/.minecraft)
    \\    --dry-run          With launch: print the java command line, do not run it
    \\    --no-assets        With install: skip assets/objects
    \\    --threads <n>      With install: parallel downloads (default 8)
    \\    --client-id <guid> With login: your own Entra application ID
    \\
    \\EXIT CODES:
    \\     0 success      2 usage        3 config      10 auth failed
    \\    11 Client ID not authorized by Minecraft Services
    \\    12 account does not own the game
    \\    20 download failed                       30 no Java runtime found
    \\
    \\Game files are fetched only from Mojang's own endpoints
    \\(piston-meta, piston-data, libraries.minecraft.net, resources.download.minecraft.net)
    \\and verified against the SHA-1 in Mojang's metadata. Nothing is hosted or
    \\mirrored, and there is no download-source setting.
    \\
    \\No Client ID is bundled: each user registers their own application and
    \\requests access at https://aka.ms/mce-reviewappid.
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
    if (eq(cmd, "login")) return cmdLogin(c, args);
    if (eq(cmd, "install")) return cmdInstall(c, args);
    if (eq(cmd, "launch")) return cmdLaunch(c, args);

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
    /// Install Fabric instead of the bare version.
    fabric: bool = false,
    /// Explicit loader version; empty means "latest stable".
    loader: []const u8 = "",
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
        } else if (eq(a, "--fabric")) {
            f.fabric = true;
        } else if (eq(a, "--loader")) {
            i += 1;
            if (i >= args.len) return null;
            f.loader = args[i];
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

    var loader_id: ?[]const u8 = null;
    if (flags.fabric) {
        const loader = if (flags.loader.len != 0) flags.loader else fabric.resolveLoader(
            c.io,
            c.gpa,
            arena,
            flags.version,
        ) catch |e| {
            c.err("error: cannot resolve a Fabric loader for {s}: {s}\n", .{ flags.version, @errorName(e) });
            return Exit.download;
        };
        loader_id = fabric.installProfile(c.io, c.gpa, arena, game_dir, flags.version, loader) catch |e| {
            c.err("error: Fabric install failed: {s}\n", .{@errorName(e)});
            return Exit.download;
        };
        if (!c.json) c.err("fabric loader {s} -> {s}\n", .{ loader, loader_id.? });
    }

    if (c.json) {
        c.emitJson(.{
            .version = stats.version,
            .fabric = loader_id orelse "",
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

const LoginFlags = struct {
    client_id: []const u8 = "",
};

fn parseLoginFlags(c: Ctx, args: []const []const u8) ?LoginFlags {
    var f: LoginFlags = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--client-id")) {
            i += 1;
            if (i >= args.len) return null;
            f.client_id = args[i];
        } else if (eq(a, "--client-id=*")) {
            return null;
        } else if (std.mem.startsWith(u8, a, "--client-id=")) {
            f.client_id = a["--client-id=".len..];
        } else return null;
    }
    if (f.client_id.len == 0) {
        f.client_id = c.environ.get("ARCLIGHT_CLIENT_ID") orelse "";
    }
    return f;
}

fn cmdLogin(c: Ctx, args: []const []const u8) u8 {
    const flags = parseLoginFlags(c, args) orelse {
        c.err("usage: arclight login [--client-id <guid>]\n", .{});
        return Exit.usage;
    };

    var arena_state = std.heap.ArenaAllocator.init(c.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = store.configDir(arena, c.environ) catch {
        c.err("error: cannot resolve config directory\n", .{});
        return Exit.config;
    };

    // Client ID resolution order: --client-id, ARCLIGHT_CLIENT_ID, then the one
    // this account was last signed in with. Refresh tokens are bound to it, so
    // re-using the stored value is what a re-login after expiry wants.
    var client_id = flags.client_id;
    if (client_id.len == 0) {
        if (store.load(c.io, arena, dir) catch null) |acc| {
            if (acc.client_id.len != 0) client_id = acc.client_id;
        }
    }
    if (client_id.len == 0) {
        c.err(
            "error: no Client ID given and none stored.\n" ++
                "usage: arclight login --client-id <guid>   (or set ARCLIGHT_CLIENT_ID)\n" ++
                "no Client ID is bundled: see README.md\n",
            .{},
        );
        return Exit.usage;
    }

    const result = auth.login(c.io, c.gpa, arena, .{ .client_id = client_id }) catch |e| {
        if (!c.json) c.err("\n", .{});
        return switch (e) {
            auth.Error.AppIdNotAuthorized => Exit.appid_not_authorized,
            auth.Error.GameNotOwned => Exit.no_ownership,
            else => Exit.auth,
        };
    };

    store.save(c.io, dir, .{
        .client_id = result.client_id,
        .name = result.name,
        .uuid = result.uuid,
        .refresh_token = result.refresh_token,
        .updated_at = 0,
    }) catch |e| {
        c.err("error: cannot write account file: {s}\n", .{@errorName(e)});
        return Exit.config;
    };

    if (c.json) {
        c.emitJson(store.Public.from(.{
            .client_id = result.client_id,
            .name = result.name,
            .uuid = result.uuid,
            .refresh_token = result.refresh_token,
            .updated_at = 0,
        }));
    } else {
        c.out("signed in\n");
    }
    return Exit.ok;
}

const LaunchFlags = struct {
    version: []const u8 = "",
    dir: ?[]const u8 = null,
    dry_run: bool = false,
};

fn parseLaunchFlags(args: []const []const u8) ?LaunchFlags {
    var f: LaunchFlags = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--dir")) {
            i += 1;
            if (i >= args.len) return null;
            f.dir = args[i];
        } else if (eq(a, "--dry-run")) {
            f.dry_run = true;
        } else if (a.len != 0 and a[0] == '-') {
            return null;
        } else if (f.version.len == 0) {
            f.version = a;
        } else return null;
    }
    if (f.version.len == 0) return null;
    return f;
}

fn cmdLaunch(c: Ctx, args: []const []const u8) u8 {
    const flags = parseLaunchFlags(args) orelse {
        c.err("usage: arclight launch <version> [--dir <path>] [--dry-run]\n", .{});
        return Exit.usage;
    };

    var arena_state = std.heap.ArenaAllocator.init(c.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const game_dir = flags.dir orelse blk: {
        const home = c.environ.get("HOME") orelse return Exit.usage;
        break :blk std.fs.path.join(arena, &.{ home, ".minecraft" }) catch return Exit.config;
    };

    // A missing account is fatal unless we are only printing the command line.
    var account: ?store.Account = null;
    if (store.configDir(arena, c.environ)) |dir| {
        account = store.load(c.io, arena, dir) catch null;
    } else |_| {}

    const outcome = launch_mod.launch(c.io, c.gpa, arena, .{
        .game_dir = game_dir,
        .version = flags.version,
        .dry_run = flags.dry_run,
        .environ = c.environ,
    }, account) catch |e| {
        switch (e) {
            launch_mod.Error.VersionNotInstalled => c.err(
                "error: {s} is not installed in {s}\n" ++
                    "hint: arclight install {s} --dir {s}\n",
                .{ flags.version, game_dir, flags.version, game_dir },
            ),
            launch_mod.Error.ParentNotInstalled => c.err(
                "error: this version inherits from another one that is not installed\n",
                .{},
            ),
            launch_mod.Error.NotLoggedIn => c.err(
                "error: not logged in (or the stored session expired)\n" ++
                    "hint: arclight login --client-id <guid>\n",
                .{},
            ),
            launch_mod.Error.NoJava => c.err(
                "error: no Java runtime found\n" ++
                    "hint: install a JDK or set JAVA_HOME / ARCLIGHT_JAVA\n",
                .{},
            ),
            launch_mod.Error.NoMainClass => c.err("error: the version json has no mainClass\n", .{}),
            else => c.err("error: launch failed: {s}\n", .{@errorName(e)}),
        }
        return switch (e) {
            launch_mod.Error.NoJava => Exit.java_missing,
            launch_mod.Error.NotLoggedIn => Exit.auth,
            launch_mod.Error.VersionNotInstalled, launch_mod.Error.ParentNotInstalled => Exit.usage,
            else => Exit.download,
        };
    };

    if (flags.dry_run) {
        for (outcome.argv) |a| {
            c.out(a);
            c.out("\n");
        }
        return Exit.ok;
    }
    return if (outcome.exit_code == 0) Exit.ok else Exit.auth;
}
