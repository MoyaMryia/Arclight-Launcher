//! mccli - a minimal Minecraft: Java Edition launcher.
//!
//! Scope is deliberately narrow, see README.md. Anything that would turn this
//! into a distribution channel for game content is out of scope by design.

const std = @import("std");
const Io = std.Io;

const store = @import("store.zig");
const java = @import("java.zig");

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
    \\mccli - minimal Minecraft: Java Edition launcher
    \\
    \\USAGE:
    \\    mccli <command> [options]
    \\
    \\COMMANDS:
    \\    login              Sign in with a Microsoft account (device code flow)
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
    if (eq(cmd, "logout")) return cmdLogout(c);
    if (eq(cmd, "login")) return notImplemented(c, "login", "auth.zig: device code flow");
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
        const line = std.fmt.bufPrint(&buf, "mccli {s} (zig {s}, {s})\n", .{
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
                "hint: install a JDK or set JAVA_HOME / MCCLI_JAVA\n" ++
                "note: mccli never downloads a runtime\n",
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
