//! Build the Java command line for an installed version and run it.
//!
//! Everything here is local: it reads `versions/<id>/<id>.json` (and its
//! `inheritsFrom` chain), resolves the classpath from `libraries/`, and starts
//! the JVM. The only network access is the refresh of the account token.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const http = std.http;

const fetch = @import("fetch.zig");
const meta = @import("meta.zig");
const store = @import("store.zig");
const auth = @import("auth.zig");
const java_mod = @import("java.zig");

pub const Error = error{
    VersionNotInstalled,
    ParentNotInstalled,
    NoMainClass,
    NotLoggedIn,
    NoJava,
    SpawnFailed,
};

pub const Options = struct {
    game_dir: []const u8,
    version: []const u8,
    /// Print the command line instead of running it.
    dry_run: bool = false,
    /// Extra arguments appended after the game arguments.
    extra: []const []const u8 = &.{},
    environ: *const std.process.Environ.Map,
};

pub const Outcome = struct {
    argv: []const []const u8,
    exit_code: u8 = 0,
};

const max_chain = 8;

pub fn launch(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
    account: ?store.Account,
) !Outcome {
    // ---- account ------------------------------------------------------
    var name: []const u8 = "Player";
    var uuid: []const u8 = "00000000000000000000000000000000";
    var token: []const u8 = "0";
    var uid: []const u8 = "0";

    if (account) |acc| {
        if (!opts.dry_run) {
            const fresh = auth.refresh(io, gpa, arena, acc.client_id, acc.refresh_token) catch
                return Error.NotLoggedIn;
            name = fresh.name;
            uuid = fresh.uuid;
            token = fresh.access_token;
            uid = fresh.xuid;
        } else {
            name = acc.name;
            uuid = acc.uuid;
        }
    } else if (!opts.dry_run) {
        return Error.NotLoggedIn;
    }

    // ---- version json chain -------------------------------------------
    var chain_len: usize = 0;
    var chain: [max_chain]meta.VersionJson = undefined;

    var next: ?[]const u8 = opts.version;
    var depth: usize = 0;
    while (next) |id| {
        if (depth >= max_chain) break;
        const path = try std.fmt.allocPrint(arena, "{s}/versions/{s}/{s}.json", .{
            opts.game_dir, id, id,
        });
        const body = Io.Dir.cwd().readFileAlloc(io, path, arena, Io.Limit.unlimited) catch |e| switch (e) {
            error.FileNotFound => return if (depth == 0) Error.VersionNotInstalled else Error.ParentNotInstalled,
            else => return e,
        };
        chain[chain_len] = try std.json.parseFromSliceLeaky(meta.VersionJson, arena, body, .{
            .ignore_unknown_fields = true,
        });
        chain_len += 1;
        next = chain[chain_len - 1].inheritsFrom;
        depth += 1;
    }
    if (chain_len == 0) return Error.VersionNotInstalled;

    const leaf = chain[0];
    const root = chain[chain_len - 1];

    const main_class = blk: {
        for (chain[0..chain_len]) |doc| {
            if (doc.mainClass) |mc| break :blk mc;
        }
        return Error.NoMainClass;
    };

    // ---- classpath -----------------------------------------------------
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var cp: std.ArrayList(u8) = .empty;

    // oldest first, so a child version wins by being appended later
    var i = chain_len;
    while (i > 0) {
        i -= 1;
        const doc = chain[i];
        for (doc.libraries orelse &.{}) |lib| {
            if (!meta.allowed(lib.rules)) continue;

            if (lib.downloads) |dls| {
                if (dls.artifact) |artifact| {
                    const p = try std.fmt.allocPrint(arena, "{s}/libraries/{s}", .{
                        opts.game_dir, artifact.path,
                    });
                    try cp.appendSlice(arena, p);
                    try cp.append(arena, sep);
                    continue;
                }
            }
            // No `downloads` block: resolve the maven coordinate. Fabric's
            // libraries all look like this.
            if (try meta.mavenPath(arena, lib, null)) |m| {
                const p = try std.fmt.allocPrint(arena, "{s}/libraries/{s}", .{
                    opts.game_dir, m.rel,
                });
                try cp.appendSlice(arena, p);
                try cp.append(arena, sep);
            }
        }
    }
    // A mod loader's version json inherits from vanilla and has no jar of its
    // own: walk the chain and use the first client jar that is actually there.
    var client_jar: []const u8 = try std.fmt.allocPrint(arena, "{s}/versions/{s}/{s}.jar", .{
        opts.game_dir, leaf.id, leaf.id,
    });
    for (chain[0..chain_len]) |doc| {
        const candidate = try std.fmt.allocPrint(arena, "{s}/versions/{s}/{s}.jar", .{
            opts.game_dir, doc.id, doc.id,
        });
        const f = Io.Dir.openFileAbsolute(io, candidate, .{}) catch continue;
        f.close(io);
        client_jar = candidate;
        break;
    }
    try cp.appendSlice(arena, client_jar);

    // ---- natives dir ---------------------------------------------------
    const natives_dir = try std.fmt.allocPrint(arena, "{s}/versions/{s}/natives", .{
        opts.game_dir, leaf.id,
    });
    Io.Dir.cwd().createDirPath(io, natives_dir) catch {};

    // ---- assets ---------------------------------------------------------
    const assets_dir = try std.fmt.allocPrint(arena, "{s}/assets", .{opts.game_dir});
    const asset_index = blk: {
        for (chain[0..chain_len]) |doc| {
            if (doc.assets) |a| break :blk a;
        }
        break :blk "legacy";
    };

    // ---- logging config --------------------------------------------------
    var log_arg: ?[]const u8 = null;
    for (chain[0..chain_len]) |doc| {
        const logging = doc.logging orelse continue;
        const client_logging = logging.client orelse continue;
        const file_name = client_logging.file.id orelse client_logging.file.path;
        const dest = try std.fmt.allocPrint(arena, "{s}/assets/log_configs/{s}", .{
            opts.game_dir, file_name,
        });
        _ = fetch.get(io, gpa, .{
            .url = client_logging.file.url,
            .dest = dest,
            .sha1 = client_logging.file.sha1,
            .size = client_logging.file.size,
        }) catch |e| {
            std.debug.print("warning: could not fetch the logging config: {s}\n", .{@errorName(e)});
            break;
        };
        log_arg = try subst(arena, client_logging.argument, &.{.{ .name = "path", .value = dest }});
        break;
    }

    // ---- variables ------------------------------------------------------
    const vars = [_]Var{
        .{ .name = "auth_player_name", .value = name },
        .{ .name = "version_name", .value = leaf.id },
        .{ .name = "game_directory", .value = opts.game_dir },
        .{ .name = "assets_root", .value = assets_dir },
        .{ .name = "game_assets", .value = assets_dir },
        .{ .name = "assets_index_name", .value = asset_index },
        .{ .name = "auth_uuid", .value = uuid },
        .{ .name = "auth_access_token", .value = token },
        .{ .name = "auth_session", .value = token },
        .{ .name = "auth_xuid", .value = uid },
        .{ .name = "clientid", .value = if (account) |a| a.client_id else "" },
        .{ .name = "user_type", .value = "msa" },
        .{ .name = "version_type", .value = leaf.type orelse "release" },
        .{ .name = "natives_directory", .value = natives_dir },
        .{ .name = "launcher_name", .value = "arclight" },
        .{ .name = "launcher_version", .value = "0.0.0" },
        .{ .name = "classpath", .value = cp.items },
        .{ .name = "classpath_separator", .value = if (builtin.os.tag == .windows) ";" else ":" },
        .{ .name = "library_directory", .value = try std.fmt.allocPrint(arena, "{s}/libraries", .{opts.game_dir}) },
        .{ .name = "primary_jar", .value = client_jar },
        .{ .name = "user_properties", .value = "{}" },
    };

    // ---- assemble -------------------------------------------------------
    var argv: std.ArrayList([]const u8) = .empty;

    const java_exe = java_mod.first(arena, opts.environ, io) catch return Error.NoJava;

    try argv.append(arena, java_exe);

    const jvm_args = try collectArgs(arena, chain[0..chain_len], .jvm, &vars);
    if (jvm_args.len == 0) {
        // Legacy versions carried no jvm argument list at all.
        try argv.append(arena, try std.fmt.allocPrint(arena, "-Djava.library.path={s}", .{natives_dir}));
        try argv.append(arena, "-Dminecraft.launcher.brand=arclight");
        try argv.append(arena, "-Dminecraft.launcher.version=0.0.0");
        try argv.append(arena, "-cp");
        try argv.append(arena, cp.items);
    } else {
        var log_added = false;
        for (jvm_args) |a| {
            if (log_arg) |la| {
                if (std.mem.startsWith(u8, a, "-Dlog4j.configurationFile")) {
                    try argv.append(arena, la);
                    log_added = true;
                    continue;
                }
            }
            try argv.append(arena, a);
        }
        // Versions from 1.7 to current carry the log4j config out of band: the
        // official launcher appends it, it is not in `arguments.jvm`.
        if (log_arg) |la| {
            if (!log_added) try argv.append(arena, la);
        }
    }

    try argv.append(arena, main_class);

    const game_args = try collectArgs(arena, chain[0..chain_len], .game, &vars);
    if (game_args.len == 0) {
        if (root.minecraftArguments) |legacy| {
            var it = std.mem.tokenizeScalar(u8, legacy, ' ');
            while (it.next()) |t| {
                const expanded = try subst(arena, t, &vars);
                if (std.mem.indexOf(u8, expanded, "${") != null) continue;
                try argv.append(arena, expanded);
            }
        }
    } else {
        for (game_args) |a| try argv.append(arena, a);
    }

    for (opts.extra) |e| try argv.append(arena, e);

    const final_argv = try argv.toOwnedSlice(arena);

    if (opts.dry_run) return .{ .argv = final_argv, .exit_code = 0 };

    var child = std.process.spawn(io, .{
        .argv = final_argv,
        .cwd = .{ .path = opts.game_dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return Error.SpawnFailed;

    const term = child.wait(io) catch return Error.SpawnFailed;
    return .{
        .argv = final_argv,
        .exit_code = switch (term) {
            .exited => |code| code,
            else => 1,
        },
    };
}

const Var = struct { name: []const u8, value: []const u8 };

pub fn subst(arena: std.mem.Allocator, template: []const u8, vars: []const Var) ![]const u8 {
    if (std.mem.indexOf(u8, template, "${") == null) return template;

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '$' and template[i + 1] == '{') {
            const end = std.mem.indexOfScalarPos(u8, template, i + 2, '}') orelse {
                try out.append(arena, template[i]);
                i += 1;
                continue;
            };
            const key = template[i + 2 .. end];
            var replaced = false;
            for (vars) |v| {
                if (std.mem.eql(u8, v.name, key)) {
                    try out.appendSlice(arena, v.value);
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try out.appendSlice(arena, template[i .. end + 1]);
            i = end + 1;
        } else {
            try out.append(arena, template[i]);
            i += 1;
        }
    }
    return out.items;
}

const ArgKind = enum { jvm, game };

fn collectArgs(
    arena: std.mem.Allocator,
    chain: []const meta.VersionJson,
    kind: ArgKind,
    vars: []const Var,
) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;

    var idx = chain.len;
    while (idx > 0) {
        idx -= 1;
        const doc = chain[idx];
        const arguments = doc.arguments orelse continue;
        if (arguments != .object) continue;

        const key = switch (kind) {
            .jvm => "jvm",
            .game => "game",
        };
        const list = arguments.object.get(key) orelse continue;
        if (list != .array) continue;

        for (list.array.items) |item| {
            switch (item) {
                .string => |str| {
                    const expanded = try subst(arena, str, vars);
                    // Skip an unresolved launcher-only placeholder rather than
                    // handing a literal ${...} to the JVM.
                    if (std.mem.indexOf(u8, expanded, "${") != null) continue;
                    try out.append(arena, expanded);
                },
                .object => |obj| {
                    const rules_val = obj.get("rules");
                    if (rules_val) |rv| {
                        const rules = try parseRules(arena, rv);
                        if (!meta.allowed(rules)) continue;
                    }
                    const value = obj.get("value") orelse continue;
                    switch (value) {
                        .string => |str| {
                            const expanded = try subst(arena, str, vars);
                            if (std.mem.indexOf(u8, expanded, "${") != null) continue;
                            try out.append(arena, expanded);
                        },
                        .array => |arr| {
                            for (arr.items) |v| {
                                if (v != .string) continue;
                                const expanded = try subst(arena, v.string, vars);
                                if (std.mem.indexOf(u8, expanded, "${") != null) continue;
                                try out.append(arena, expanded);
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }
    return out.toOwnedSlice(arena);
}

fn parseRules(arena: std.mem.Allocator, value: std.json.Value) ![]const meta.Rule {
    if (value != .array) return &.{};
    var rules: std.ArrayList(meta.Rule) = .empty;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const action = if (item.object.get("action")) |a| switch (a) {
            .string => |s| s,
            else => continue,
        } else continue;
        var rule: meta.Rule = .{ .action = action };
        if (item.object.get("os")) |os_val| {
            if (os_val == .object) {
                var os: meta.OsRule = .{};
                if (os_val.object.get("name")) |n| {
                    if (n == .string) os.name = n.string;
                }
                if (os_val.object.get("arch")) |n| {
                    if (n == .string) os.arch = n.string;
                }
                if (os_val.object.get("version")) |n| {
                    if (n == .string) os.version = n.string;
                }
                rule.os = os;
            }
        }
        if (item.object.get("features")) |f| rule.features = f;
        try rules.append(arena, rule);
    }
    return rules.toOwnedSlice(arena);
}
