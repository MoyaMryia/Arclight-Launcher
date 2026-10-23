//! arclight-launcher - a minimal Minecraft: Java Edition launcher.
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
const loaders = @import("loaders.zig");

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
    /// Files the launch needs are not on disk.
    pub const missing_files: u8 = 21;
    /// The game ran and exited with a non-zero status.
    pub const game_failed: u8 = 40;
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
    \\arclight-launcher - minimal Minecraft: Java Edition launcher
    \\
    \\USAGE:
    \\    arclight-launcher <command> [options]
    \\
    \\COMMANDS:
    \\    login              Sign in with a Microsoft account (device code flow)
    \\    versions           List Minecraft versions from Mojang's manifest
    \\    instances          List instance directories under <dir>/instances
    \\    install <version>  Fetch a version, its libraries and assets
    \\                       --fabric | --forge | --neoforge add a mod loader
    \\    launch <version>   Start an installed version (--instance <name> to isolate)
    \\    status             Show the stored account (never prints tokens)
    \\    logout             Forget the stored account
    \\    java               List detected Java runtimes
    \\    help               Show this text
    \\    version            Show version information
    \\
    \\OPTIONS:
    \\    --json             Machine-readable output on stdout
    \\    --dir <path>       Game directory for install/launch (default ~/.minecraft)
    \\    --instance <name>  With launch: run in <dir>/instances/<name>
    \\    --dry-run          With launch: print the java command line, do not run it
    \\    --no-assets        With install: skip assets/objects
    \\    --threads <n>      With install: parallel downloads (default 8)
    \\    --client-id <guid> With login: your own Entra application ID
    \\                       (also $ARCLIGHT_CLIENT_ID, or a client_id file)
    \\    --loader <ver>     With install: pin the loader build
    \\    --installer <path> With install: use a locally downloaded installer jar
    \\
    \\EXIT CODES:
    \\     0 success      2 usage        3 config      10 auth failed
    \\    11 Client ID not authorized by Minecraft Services
    \\    12 account does not own the game
    \\    20 download failed        21 required files missing
    \\    30 no Java runtime found  40 the game exited with a non-zero status
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
    if (eq(cmd, "versions")) return cmdVersions(c, args);
    if (eq(cmd, "instances")) return cmdInstances(c, args);
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
        const line = std.fmt.bufPrint(&buf, "arclight-launcher {s} (zig {s}, {s})\n", .{
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
                "note: arclight-launcher never downloads a runtime\n",
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


const VersionFlags = struct {
    from: ?[]const u8 = null,
    limit: usize = 10,
};

fn parseVersionFlags(args: []const []const u8) ?VersionFlags {
    var f: VersionFlags = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--from")) {
            i += 1;
            if (i >= args.len) return null;
            f.from = args[i];
        } else if (eq(a, "--limit")) {
            i += 1;
            if (i >= args.len) return null;
            f.limit = std.fmt.parseInt(usize, args[i], 10) catch return null;
        } else if (std.mem.startsWith(u8, a, "--from=")) {
            f.from = a["--from=".len..];
        } else if (std.mem.startsWith(u8, a, "--limit=")) {
            f.limit = std.fmt.parseInt(usize, a["--limit=".len..], 10) catch return null;
        } else return null;
    }
    if (f.limit == 0) return null;
    return f;
}

fn cmdVersions(c: Ctx, args: []const []const u8) u8 {
    const flags = parseVersionFlags(args) orelse {
        c.err("usage: arclight versions [--from <version>] [--limit <n>]\n", .{});
        return Exit.usage;
    };

    const dir = store.configDir(c.arena, c.environ) catch {
        c.err("error: cannot resolve config directory (HOME unset?)\n", .{});
        return Exit.config;
    };
    const cache_dir = std.fs.path.join(c.arena, &.{ dir, "cache" }) catch return Exit.config;

    const manifest = meta.loadManifest(c.io, c.gpa, c.arena, cache_dir) catch |e| {
        c.err("error: cannot load version manifest: {s}\n", .{@errorName(e)});
        return Exit.download;
    };

    // The list runs newest to oldest. --from starts at a named version;
    // --limit says how many to print from there.
    var start: usize = 0;
    if (flags.from) |wanted| {
        start = blk: {
            for (manifest.versions, 0..) |v, i| {
                if (std.mem.eql(u8, v.id, wanted)) break :blk i;
            }
            c.err("error: no version called '{s}' in the manifest\n", .{wanted});
            return Exit.usage;
        };
    }
    const shown_end = @min(manifest.versions.len, start + flags.limit);

    if (c.json) {
        c.emitJson(.{
            .latest = manifest.latest,
            .total = manifest.versions.len,
            .versions = manifest.versions[start..shown_end],
        });
    } else {
        var buf: [256]u8 = undefined;
        c.out(std.fmt.bufPrint(&buf, "latest release: {s}\nlatest snapshot: {s}\n\n", .{
            manifest.latest.release, manifest.latest.snapshot,
        }) catch "");
        for (manifest.versions[start..shown_end]) |v| {
            c.out(std.fmt.bufPrint(&buf, "{s:<12} {s}\n", .{ v.id, v.type }) catch "");
        }
        var buf2: [160]u8 = undefined;
        c.out(std.fmt.bufPrint(&buf2, "\n(versions {d}-{d} of {d})\n", .{
            start + 1, shown_end, manifest.versions.len,
        }) catch "");
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
    /// Install Forge / NeoForge by running their installer.
    loader_kind: ?loaders.Kind = null,
    /// Explicit loader version; empty means "latest stable".
    loader: []const u8 = "",
    /// Local installer jar, for when the maven host is unreachable.
    installer: ?[]const u8 = null,
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
        } else if (eq(a, "--forge")) {
            f.loader_kind = .forge;
        } else if (eq(a, "--neoforge")) {
            f.loader_kind = .neoforge;
        } else if (eq(a, "--loader")) {
            i += 1;
            if (i >= args.len) return null;
            f.loader = args[i];
        } else if (eq(a, "--installer")) {
            i += 1;
            if (i >= args.len) return null;
            f.installer = args[i];
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
        c.err("usage: arclight-launcher install <version> [--dir <path>] [--no-assets] [--threads N]\n", .{});
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
        .progress = install_mod.stderrIsTty(c.io),
    }) catch |e| {
        c.err("error: install failed: {s}\n", .{@errorName(e)});
        return switch (e) {
            install_mod.Error.VersionNotFound => Exit.usage,
            else => Exit.download,
        };
    };

    var loader_id: ?[]const u8 = null;
    if (flags.loader_kind) |kind| {
        loader_id = loaders.install(
            c.io,
            c.gpa,
            arena,
            kind,
            game_dir,
            cache_dir,
            flags.version,
            if (flags.loader.len != 0) flags.loader else null,
            flags.installer,
            c.environ,
        ) catch |e| {
            c.err("error: {s} install failed: {s}\n", .{ @tagName(kind), @errorName(e) });
            return switch (e) {
                loaders.Error.JavaMissing => Exit.java_missing,
                loaders.Error.NoSuchVersion => Exit.usage,
                else => Exit.download,
            };
        };
        if (!c.json) c.err("{s} installed as: {s}\n", .{ @tagName(kind), loader_id.? });
    }
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
            .assets_failed = stats.assets_failed,
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
        c.err("usage: arclight-launcher login [--client-id <guid>]\n", .{});
        return Exit.usage;
    };

    var arena_state = std.heap.ArenaAllocator.init(c.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = store.configDir(arena, c.environ) catch {
        c.err("error: cannot resolve config directory\n", .{});
        return Exit.config;
    };

    // Client ID resolution order: --client-id, ARCLIGHT_CLIENT_ID, the
    // client_id file, then the ID this account was last signed in with.
    // Refresh tokens are bound to it, so re-using the stored value is what a
    // re-login after expiry wants.
    var client_id = flags.client_id;
    var source: []const u8 = "--client-id";

    if (client_id.len == 0) {
        if (c.environ.get("ARCLIGHT_CLIENT_ID")) |env| {
            if (env.len != 0) {
                client_id = env;
                source = "ARCLIGHT_CLIENT_ID";
            }
        }
    }
    if (client_id.len == 0) {
        if (store.loadClientId(c.io, arena, dir) catch null) |file_id| {
            client_id = file_id;
            source = "the client_id file";
        }
    }
    if (client_id.len == 0) {
        if (store.load(c.io, arena, dir) catch null) |acc| {
            if (acc.client_id.len != 0) {
                client_id = acc.client_id;
                source = "the stored account";
            }
        }
    }

    if (client_id.len == 0) {
        printClientIdGuide(c, dir);
        return Exit.usage;
    }

    if (!c.json) c.err("using Client ID from {s}\n", .{source});

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
    /// Re-download whatever preflight reports as missing before launching.
    repair: bool = false,
    /// Run under <dir>/instances/<name>: own saves/, mods/, config/.
    instance: ?[]const u8 = null,
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
        } else if (eq(a, "--repair")) {
            f.repair = true;
        } else if (eq(a, "--instance")) {
            i += 1;
            if (i >= args.len) return null;
            f.instance = args[i];
        } else if (a.len != 0 and a[0] == '-') {
            return null;
        } else if (f.version.len == 0) {
            f.version = a;
        } else return null;
    }
    if (f.version.len == 0 and f.instance == null) return null;
    return f;
}

fn cmdLaunch(c: Ctx, args: []const []const u8) u8 {
    const flags = parseLaunchFlags(args) orelse {
        c.err(
            "usage: arclight-launcher launch <version> [--dir <path>] [--instance <name>]\n" ++
                "                                    [--dry-run] [--repair]\n",
            .{},
        );
        return Exit.usage;
    };

    var arena_state = std.heap.ArenaAllocator.init(c.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const game_dir = flags.dir orelse blk: {
        const home = c.environ.get("HOME") orelse return Exit.usage;
        break :blk std.fs.path.join(arena, &.{ home, ".minecraft" }) catch return Exit.config;
    };

    // An instance only changes where the game runs; versions, libraries and
    // assets stay shared in the installation root.
    var run_dir = game_dir;
    var instance_record: ?store.Instance = null;
    if (flags.instance) |name| {
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null) {
            c.err("error: instance name must not contain a path separator\n", .{});
            return Exit.usage;
        }
        run_dir = std.fs.path.join(arena, &.{ game_dir, "instances", name }) catch return Exit.config;
        Io.Dir.cwd().createDirPath(c.io, run_dir) catch |e| {
            c.err("error: cannot create instance directory: {s}\n", .{@errorName(e)});
            return Exit.config;
        };
        // Legacy versions read by-name assets from <gameDir>/resources. Point
        // the instance at the shared copy instead of duplicating it.
        const shared_resources = std.fs.path.join(arena, &.{ game_dir, "resources" }) catch return Exit.config;
        const instance_resources = std.fs.path.join(arena, &.{ run_dir, "resources" }) catch return Exit.config;
        io_link_or_symlink: {
            if (Io.Dir.cwd().statFile(c.io, instance_resources, .{})) |_| break :io_link_or_symlink else |_| {}
            if (Io.Dir.cwd().statFile(c.io, shared_resources, .{})) |_| {
                Io.Dir.cwd().symLink(c.io, shared_resources, instance_resources, .{ .is_directory = true }) catch {};
            } else |_| {}
        }
        instance_record = store.loadInstance(c.io, arena, run_dir) catch null;
        if (!c.json) c.err("instance: {s}\n", .{run_dir});
    }

    // `launch --instance <name>` reads the version from the instance record, so
    // a configured instance needs no other arguments.
    var version = flags.version;
    if (version.len == 0) {
        const rec = instance_record orelse {
            c.err(
                "error: no instance.json in {s}\n" ++
                    "hint: launch once with a version to record it:\n" ++
                    "      arclight-launcher launch <version> --instance {s}\n",
                .{ run_dir, flags.instance.? },
            );
            return Exit.usage;
        };
        if (rec.version.len == 0) {
            c.err("error: instance.json has no \"version\"\n", .{});
            return Exit.config;
        }
        version = rec.version;
    } else if (flags.instance != null and instance_record == null) {
        // First launch of this instance: remember what it runs.
        store.saveInstance(c.io, run_dir, .{ .version = version }) catch |e| {
            c.err("warning: cannot write instance.json: {s}\n", .{@errorName(e)});
        };
    }

    // Preflight before any network work: fail fast, and tell the user exactly
    // what is missing instead of letting the JVM die on it.
    var check = launch_mod.preflight(c.io, arena, game_dir, version) catch |e| {
        c.err("error: cannot inspect {s}: {s}\n", .{ version, @errorName(e) });
        return Exit.config;
    };

    if (check.no_version_json) {
        c.err(
            "error: no versions/{s}/{s}.json in {s}\n" ++
                "hint: `arclight-launcher install {s}` if it is in Mojang's manifest,\n" ++
                "      otherwise place the version json and jar yourself\n",
            .{ version, version, game_dir, version },
        );
        return Exit.missing_files;
    }

    if (flags.repair and (check.blocked() or check.assets_missing != 0)) {
        if (repairVersion(c, arena, game_dir, version, check.root_id)) |_| {
            check = launch_mod.preflight(c.io, arena, game_dir, version) catch check;
        } else |e| {
            c.err("error: repair failed: {s}\n", .{@errorName(e)});
            return Exit.download;
        }
    }

    if (check.blocked()) {
        c.err("preflight: {d} required file(s) missing\n", .{check.fatal.len});
        for (check.fatal, 0..) |path, i| {
            if (i >= 8) {
                c.err("  ... and {d} more\n", .{check.fatal.len - i});
                break;
            }
            c.err("  {s}\n", .{path});
        }
        if (check.natives_expected and check.natives_dir != null) {
            c.err("hint: legacy natives are unpacked by `install`, not by hand\n", .{});
        }
        c.err(
            "hint: `arclight-launcher launch {s} --repair` fetches what is missing first\n" ++
                "      or `arclight-launcher install {s} --dir {s}`\n" ++
                "      versions that never shipped in Mojang's manifest (April Fools\n" ++
                "      snapshots, wiki builds) have to have their files placed by hand\n",
            .{ version, check.root_id, game_dir },
        );
        return Exit.missing_files;
    }

    if (check.assets_missing != 0 and !c.json) {
        c.err(
            "warning: {d} of {d} asset objects are missing; the game will start but\n" ++
                "         textures, sounds or the menu panorama may be incomplete.\n" ++
                "         `install` fills them in.\n",
            .{ check.assets_missing, check.assets_checked },
        );
    }

    // A missing account is fatal unless we are only printing the command line.
    var account: ?store.Account = null;
    if (store.configDir(arena, c.environ)) |dir| {
        account = store.load(c.io, arena, dir) catch null;
    } else |_| {}

    const outcome = launch_mod.launch(c.io, c.gpa, arena, .{
        .game_dir = game_dir,
        .run_dir = run_dir,
        .java_exe = if (instance_record) |r| r.java else null,
        .extra_jvm = if (instance_record) |r| r.jvm_args else &.{},
        .version = version,
        .dry_run = flags.dry_run,
        .environ = c.environ,
    }, account) catch |e| {
        switch (e) {
            launch_mod.Error.VersionNotInstalled => c.err(
                "error: {s} is not installed in {s}\n" ++
                    "hint: arclight-launcher install {s} --dir {s}\n",
                .{ flags.version, game_dir, flags.version, game_dir },
            ),
            launch_mod.Error.ParentNotInstalled => c.err(
                "error: this version inherits from another one that is not installed\n",
                .{},
            ),
            launch_mod.Error.NotLoggedIn => c.err(
                "error: not logged in (or the stored session expired)\n" ++
                    "hint: arclight-launcher login --client-id <guid>\n",
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
    if (outcome.exit_code != 0) {
        // The child's own status is not one of ours: passing it through would
        // collide with codes like 11 (Client ID) or 20 (download).
        c.err("game exited with status {d}\n", .{outcome.exit_code});
        return Exit.game_failed;
    }
    return Exit.ok;
}

/// Neither arclight-launcher nor any downstream GUI ships a Client ID, so the very
/// first run has to explain how to get one. Keep this copy-pasteable.
fn printClientIdGuide(c: Ctx, dir: []const u8) void {
    c.err(
        \\No Client ID found.
        \\
        \\arclight-launcher does not ship one, and neither should anything built on it.
        \\Each user registers their own application. It is free and takes one
        \\visit to the Azure portal plus a wait for approval.
        \\
        \\  1. https://portal.azure.com -> Microsoft Entra ID -> App registrations
        \\     -> New registration.
        \\  2. Name: anything without "Minecraft", "Mojang", "Microsoft",
        \\     "Xbox", "Live", "Discord" or "Hypixel" in it.
        \\     Supported account types: "Personal Microsoft accounts only".
        \\     Redirect URI: platform "Mobile and desktop applications",
        \\     value http://localhost
        \\  3. Authentication -> Allow public client flows: Yes -> Save.
        \\  4. Manifest -> "accessTokenAcceptedVersion": 2
        \\  5. Overview -> copy the Application (client) ID.
        \\  6. Request access for that ID at https://aka.ms/mce-reviewappid
        \\     and wait. Without it, sign-in fails with HTTP 403 and exit 11.
        \\
        \\Then pass it on the first run:
        \\
        \\  arclight-launcher login --client-id <guid>
        \\
        \\or set ARCLIGHT_CLIENT_ID, or put the bare ID on one line in:
        \\
    , .{});
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "  {s}/client_id\n", .{dir}) catch "";
    c.err("{s}", .{line});
    c.err(
        \\
        \\Do not hand out a personal Client ID: the allow list entry belongs to
        \\whoever registered it, and it can be revoked at any time.
        \\
    , .{});
}

/// Re-install the manifest version at the root of the chain, then top up the
/// loader's own libraries. `install` is idempotent, so this only fetches what
/// preflight reported missing.
fn repairVersion(
    c: Ctx,
    arena: std.mem.Allocator,
    game_dir: []const u8,
    version: []const u8,
    root_id: []const u8,
) !void {
    const config = try store.configDir(arena, c.environ);
    const cache_dir = try std.fs.path.join(arena, &.{ config, "cache" });

    _ = install_mod.install(c.io, c.gpa, arena, .{
        .game_dir = game_dir,
        .cache_dir = cache_dir,
        .version = root_id,
        .want_assets = true,
        .progress = install_mod.stderrIsTty(c.io),
    }) catch |e| return e;

    // Anything above the root is a loader; its libraries are already resolved
    // in its own version json, so the same downloader covers them.
    const chain = try launch_mod.loadChain(c.io, arena, game_dir, version);
    if (chain.docs.len > 1) {
        const leaf = chain.leaf();
        const version_dir = try std.fs.path.join(arena, &.{ game_dir, "versions", leaf.id });
        var stats: install_mod.Stats = .{ .version = leaf.id };
        try install_mod.installLibraries(c.io, c.gpa, arena, .{
            .game_dir = game_dir,
            .cache_dir = cache_dir,
            .version = leaf.id,
            .progress = install_mod.stderrIsTty(c.io),
        }, leaf, version_dir, &stats);
    }
}

fn cmdInstances(c: Ctx, args: []const []const u8) u8 {
    var dir_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eq(args[i], "--dir")) {
            i += 1;
            if (i >= args.len) return Exit.usage;
            dir_arg = args[i];
        } else return Exit.usage;
    }

    var arena_state = std.heap.ArenaAllocator.init(c.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const game_dir = dir_arg orelse blk: {
        const home = c.environ.get("HOME") orelse return Exit.usage;
        break :blk std.fs.path.join(arena, &.{ home, ".minecraft" }) catch return Exit.config;
    };
    const root = std.fs.path.join(arena, &.{ game_dir, "instances" }) catch return Exit.config;

    var list: std.ArrayList([]const u8) = .empty;
    if (Io.Dir.cwd().openDir(c.io, root, .{ .iterate = true })) |dir_handle| {
        var dir = dir_handle;
        defer dir.close(c.io);
        var it = dir.iterate();
        while (it.next(c.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            try_list: {
                const name = arena.dupe(u8, entry.name) catch break :try_list;
                list.append(arena, name) catch break :try_list;
                const dir_path = std.fs.path.join(arena, &.{ root, name }) catch break :try_list;
                if (store.loadInstance(c.io, arena, dir_path) catch null) |rec| {
                    const shown = std.fmt.allocPrint(arena, "{s}\t{s}", .{ name, rec.version }) catch break :try_list;
                    list.items[list.items.len - 1] = shown;
                }
            }
        }
    } else |_| {}

    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    if (c.json) {
        c.emitJson(.{ .root = root, .instances = list.items });
    } else if (list.items.len == 0) {
        c.out("no instances yet\n");
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "create one with: launch <version> --instance <name>\n", .{}) catch "";
        c.out(line);
    } else {
        for (list.items) |name| {
            c.out(name);
            c.out("\n");
        }
    }
    return Exit.ok;
}
