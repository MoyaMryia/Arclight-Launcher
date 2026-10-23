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
    /// Installation root: holds versions/, libraries/, assets/.
    game_dir: []const u8,
    /// Where the game runs and writes saves/mods/config. Defaults to game_dir.
    /// This is the only thing an instance changes.
    run_dir: ?[]const u8 = null,
    /// Explicit runtime, from the instance record.
    java_exe: ?[]const u8 = null,
    /// Extra JVM arguments, from the instance record.
    extra_jvm: []const []const u8 = &.{},
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
    const chain_list = try loadChain(io, arena, opts.game_dir, opts.version);
    const chain = chain_list.docs;

    const leaf = chain[0];
    const root = chain[chain.len - 1];

    const main_class = blk: {
        for (chain) |doc| {
            if (doc.mainClass) |mc| break :blk mc;
        }
        return Error.NoMainClass;
    };

    // ---- classpath -----------------------------------------------------
    const run_dir = opts.run_dir orelse opts.game_dir;
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var cp: std.ArrayList(u8) = .empty;
    // A loader's version json re-lists libraries the vanilla json already
    // pinned (gson, asm, ...). Duplicate classpath entries are useless to the
    // JVM and fatal to NeoForge's securejarhandler, which keys them by path.
    var seen: std.StringHashMap(void) = .init(arena);

    // oldest first, so a child version wins by being appended later
    var i = chain.len;
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
                    if ((try seen.getOrPut(p)).found_existing) continue;
                    try cp.appendSlice(arena, p);
                    try cp.append(arena, sep);
                }
                // `downloads` without an `artifact` means classifier-only (the
                // natives jars): there is no base jar to put on the classpath.
                continue;
            }
            // No `downloads` block: resolve the maven coordinate. Fabric's
            // libraries all look like this.
            if (try meta.mavenPath(arena, lib, null)) |m| {
                const p = try std.fmt.allocPrint(arena, "{s}/libraries/{s}", .{
                    opts.game_dir, m.rel,
                });
                if ((try seen.getOrPut(p)).found_existing) continue;
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
    for (chain) |doc| {
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
    var assets_dir = try std.fmt.allocPrint(arena, "{s}/assets", .{opts.game_dir});
    const asset_index = blk: {
        for (chain) |doc| {
            if (doc.assets) |a| break :blk a;
        }
        break :blk "legacy";
    };

    // Pre-1.6 style indexes materialise objects by name under
    // assets/virtual/<id>; the version json keeps saying `assets`, so the
    // directory's presence is what tells us which layout this install uses.
    const virtual_dir = try std.fmt.allocPrint(arena, "{s}/assets/virtual/{s}", .{
        opts.game_dir, asset_index,
    });
    if (dirHasEntries(io, virtual_dir)) assets_dir = virtual_dir;

    // ---- logging config --------------------------------------------------
    var log_arg: ?[]const u8 = null;
    for (chain) |doc| {
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
        .{ .name = "game_directory", .value = run_dir },
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

    const java_exe = opts.java_exe orelse
        (java_mod.first(arena, opts.environ, io) catch return Error.NoJava);

    // Versions declare the runtime they were built against. Ancient versions
    // (launchwrapper 1.6 and older) break on Java 9+ with a ClassCastException
    // deep inside the loader, which is baffling without this line.
    const wanted_java = blk: {
        for (chain) |doc| {
            if (doc.javaVersion) |jv| {
                if (jv.majorVersion != 0) break :blk jv.majorVersion;
            }
        }
        break :blk 0;
    };
    if (wanted_java != 0) {
        if (java_mod.majorVersion(io, arena, gpa, java_exe)) |actual| {
            if (actual < wanted_java) {
                std.debug.print(
                    "warning: this version needs Java {d} or newer, {s} reports Java {d}\n" ++
                        "         point JAVA_HOME or ARCLIGHT_JAVA at a matching runtime\n",
                    .{ wanted_java, java_exe, actual },
                );
            } else if (actual >= 9 and std.mem.indexOf(u8, main_class, "launchwrapper") != null) {
                // The one breakage we can predict: launchwrapper 1.x casts the
                // system class loader to URLClassLoader, which stopped being true
                // in Java 9. A version declaring Java 8 is otherwise fine on a
                // newer runtime (1.16.5 runs on 21), so only warn here.
                std.debug.print(
                    "warning: this version loads through launchwrapper, which cannot run on\n" ++
                        "         Java 9+ ({s} reports Java {d}); it fails with\n" ++
                        "         \"AppClassLoader cannot be cast to URLClassLoader\"\n" ++
                        "         set ARCLIGHT_JAVA to a Java {d} runtime\n",
                    .{ java_exe, actual, wanted_java },
                );
            }
        } else |_| {}
    }

    try argv.append(arena, java_exe);

    const jvm_args = try collectArgs(arena, chain, .jvm, &vars);
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

    for (opts.extra_jvm) |a| try argv.append(arena, a);

    try argv.append(arena, main_class);

    const game_args = try collectArgs(arena, chain, .game, &vars);
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
        .cwd = .{ .path = run_dir },
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

pub const Chain = struct {
    /// Leaf first, root last: `docs[0].id` is the version being launched.
    docs: []meta.VersionJson,

    pub fn leaf(self: Chain) meta.VersionJson {
        return self.docs[0];
    }

    pub fn root(self: Chain) meta.VersionJson {
        return self.docs[self.docs.len - 1];
    }
};

pub fn loadChain(
    io: Io,
    arena: std.mem.Allocator,
    game_dir: []const u8,
    version: []const u8,
) !Chain {
    var list: std.ArrayList(meta.VersionJson) = .empty;

    var next: ?[]const u8 = version;
    while (next) |id| {
        if (list.items.len >= max_chain) break;
        const path = try std.fmt.allocPrint(arena, "{s}/versions/{s}/{s}.json", .{ game_dir, id, id });
        const body = Io.Dir.cwd().readFileAlloc(io, path, arena, Io.Limit.unlimited) catch |e| switch (e) {
            error.FileNotFound => return if (list.items.len == 0) Error.VersionNotInstalled else Error.ParentNotInstalled,
            else => return e,
        };
        const doc = try std.json.parseFromSliceLeaky(meta.VersionJson, arena, body, .{
            .ignore_unknown_fields = true,
        });
        try list.append(arena, doc);
        next = doc.inheritsFrom;
    }
    if (list.items.len == 0) return Error.VersionNotInstalled;
    return .{ .docs = try list.toOwnedSlice(arena) };
}

// ---------------------------------------------------------------- preflight

pub const Preflight = struct {
    /// Paths that will stop the game from starting at all.
    fatal: []const []const u8 = &.{},
    /// The client jar we would put on the classpath, if any.
    client_jar: ?[]const u8 = null,
    natives_expected: bool = false,
    natives_dir: ?[]const u8 = null,
    asset_index: ?[]const u8 = null,
    assets_checked: usize = 0,
    assets_missing: usize = 0,
    /// No `versions/<id>/<id>.json`, so nothing can be checked. Versions that
    /// never shipped in Mojang's manifest (April Fools builds, wiki-only
    /// snapshots) land here when the user has not dropped the files in yet.
    no_version_json: bool = false,
    /// The asset index wants a by-name layout (virtual / map_to_resources).
    legacy_layout: bool = false,
    /// The root of the inheritance chain: the id `install` understands.
    root_id: []const u8 = "",

    pub fn ok(self: Preflight) bool {
        return self.fatal.len == 0 and self.assets_missing == 0;
    }

    /// A missing asset degrades the game but does not stop it; a missing jar or
    /// library does. Keep the two apart so a flaky CDN cannot make the game
    /// unlaunchable.
    pub fn blocked(self: Preflight) bool {
        return self.fatal.len != 0;
    }
};

pub fn preflight(
    io: Io,
    arena: std.mem.Allocator,
    game_dir: []const u8,
    version: []const u8,
) !Preflight {
    var fatal: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMap(void) = .init(arena);
    const add = struct {
        fn call(
            list: *std.ArrayList([]const u8),
            map: *std.StringHashMap(void),
            alloc: std.mem.Allocator,
            path: []const u8,
        ) !void {
            // One library can be declared by both a loader and its parent, so
            // the same missing path shows up more than once.
            if ((try map.getOrPut(path)).found_existing) return;
            try list.append(alloc, path);
        }
    }.call;

    const chain_result = loadChain(io, arena, game_dir, version);
    if (chain_result) |chain| {
        var report: Preflight = .{ .root_id = chain.docs[chain.docs.len - 1].id };
        const leaf = chain.leaf();

        // client jar: the leaf's own, else the first one in the chain
        for (chain.docs) |doc| {
            const candidate = try std.fmt.allocPrint(arena, "{s}/versions/{s}/{s}.jar", .{
                game_dir, doc.id, doc.id,
            });
            if (tryStat(io, candidate) != null) {
                report.client_jar = candidate;
                break;
            }
        }
        if (report.client_jar == null) {
            const expected = try std.fmt.allocPrint(arena, "{s}/versions/{s}/{s}.jar", .{
                game_dir, leaf.id, leaf.id,
            });
            try add(&fatal, &seen, arena, expected);
        }

        // libraries + natives
        var needs_natives = false;
        for (chain.docs) |doc| {
            for (doc.libraries orelse &.{}) |lib| {
                if (!meta.allowed(lib.rules)) continue;
                if (lib.natives != null) {
                    if (lib.natives.?.map.get(meta.osName()) != null) needs_natives = true;
                }
                const rel: ?[]const u8 = blk: {
                    if (lib.downloads) |dls| {
                        // Classifier-only libraries (natives) never have a base
                        // jar; the maven guess below would be a false positive.
                        if (dls.artifact) |artifact| break :blk artifact.path;
                        break :blk null;
                    }
                    if (try meta.mavenPath(arena, lib, null)) |m| break :blk m.rel;
                    break :blk null;
                };
                const path_rel = rel orelse continue;
                const path = try std.fs.path.join(arena, &.{ game_dir, "libraries", path_rel });
                if (tryStat(io, path) == null) try add(&fatal, &seen, arena, path);
            }
        }

        if (needs_natives) {
            report.natives_expected = true;
            const dir = try std.fmt.allocPrint(arena, "{s}/versions/{s}/natives", .{
                game_dir, leaf.id,
            });
            report.natives_dir = dir;
            if (!dirHasEntries(io, dir)) try add(&fatal, &seen, arena, dir);
        }

        // log4j config, when the version json carries one out of band
        for (chain.docs) |doc| {
            const logging = doc.logging orelse continue;
            const client_logging = logging.client orelse continue;
            const name = client_logging.file.id orelse client_logging.file.path;
            const path = try std.fmt.allocPrint(arena, "{s}/assets/log_configs/{s}", .{ game_dir, name });
            if (tryStat(io, path) == null) try add(&fatal, &seen, arena, path);
            break;
        }

        // assets: an index and its objects. Not fatal, just reported.
        const index_id = blk: {
            for (chain.docs) |doc| {
                if (doc.assets) |a| break :blk a;
            }
            break :blk "legacy";
        };
        const index_path = try std.fmt.allocPrint(arena, "{s}/assets/indexes/{s}.json", .{
            game_dir, index_id,
        });
        report.asset_index = index_path;

        if (Io.Dir.cwd().readFileAlloc(io, index_path, arena, Io.Limit.limited(32 << 20))) |body| {
            const idx = std.json.parseFromSliceLeaky(meta.AssetIndexFile, arena, body, .{
                .ignore_unknown_fields = true,
            }) catch null;
            if (idx) |parsed| {
                // A virtual index is only usable once the objects are laid out
                // by name; check that, not just the object store.
                if (parsed.virtual or parsed.map_to_resources) {
                    const root = if (parsed.map_to_resources)
                        try std.fs.path.join(arena, &.{ game_dir, "resources" })
                    else
                        try std.fmt.allocPrint(arena, "{s}/assets/virtual/{s}", .{ game_dir, index_id });
                    if (!dirHasEntries(io, root)) try add(&fatal, &seen, arena, root);
                    report.legacy_layout = true;
                }
                var it = parsed.objects.map.iterator();
                while (it.next()) |entry| {
                    const obj = entry.value_ptr.*;
                    if (obj.hash.len < 2) continue;
                    report.assets_checked += 1;
                    const path = try std.fmt.allocPrint(arena, "{s}/assets/objects/{s}/{s}", .{
                        game_dir, obj.hash[0..2], obj.hash,
                    });
                    const st = tryStat(io, path) orelse {
                        report.assets_missing += 1;
                        continue;
                    };
                    if (obj.size != 0 and st.size != obj.size) report.assets_missing += 1;
                }
            }
        } else |_| {
            report.assets_missing = 1;
        }

        report.fatal = try fatal.toOwnedSlice(arena);
        return report;
    } else |err| switch (err) {
        Error.VersionNotInstalled => return .{ .no_version_json = true },
        else => return err,
    }
}

fn tryStat(io: Io, path: []const u8) ?Io.File.Stat {
    return Io.Dir.cwd().statFile(io, path, .{}) catch null;
}

fn dirHasEntries(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    const entry = it.next(io) catch return false;
    return entry != null;
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
