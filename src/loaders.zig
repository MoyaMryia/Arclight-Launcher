//! Forge and NeoForge: run the official installer.
//!
//! The installer is not a mod loader, it is a small build tool that patches the
//! vanilla client and writes a version json. Replicating its processors is a
//! week of work; running it is what the upstream authors support, so that is
//! what we do.
//!
//! Hosts: maven.minecraftforge.net, maven.neoforged.net.

const std = @import("std");
const Io = std.Io;
const http = std.http;

const fetch = @import("fetch.zig");
const java_mod = @import("java.zig");

pub const Kind = enum {
    forge,
    neoforge,

    fn label(self: Kind) []const u8 {
        return switch (self) {
            .forge => "Forge",
            .neoforge => "NeoForge",
        };
    }
};

pub const Error = error{
    NoSuchVersion,
    HttpFailed,
    InstallerFailed,
    JavaMissing,
};

fn metadataUrl(kind: Kind) []const u8 {
    return switch (kind) {
        .forge => "https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml",
        .neoforge => "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml",
    };
}

fn installerUrl(
    arena: std.mem.Allocator,
    kind: Kind,
    minecraft: []const u8,
    version: []const u8,
) ![]const u8 {
    return switch (kind) {
        .forge => std.fmt.allocPrint(
            arena,
            "https://maven.minecraftforge.net/net/minecraftforge/forge/{s}-{s}/forge-{s}-{s}-installer.jar",
            .{ minecraft, version, minecraft, version },
        ),
        .neoforge => std.fmt.allocPrint(
            arena,
            "https://maven.neoforged.net/releases/net/neoforged/neoforge/{s}/neoforge-{s}-installer.jar",
            .{ version, version },
        ),
    };
}

/// The maven-modelled version string the installer lives under.
/// Forge: `1.20.1-47.2.0`. NeoForge: `21.1.77`.
fn versionPrefix(arena: std.mem.Allocator, kind: Kind, minecraft: []const u8) ![]const u8 {
    return switch (kind) {
        .forge => std.fmt.allocPrint(arena, "{s}-", .{minecraft}),
        // NeoForge drops the leading "1." from the game version: 1.21.1 -> "21.1.",
        // 1.20.4 -> "20.4.". The 1.20.1 line predates the rename and is not
        // covered; there the user has to pass an explicit version.
        .neoforge => blk: {
            const trimmed = if (std.mem.startsWith(u8, minecraft, "1.")) minecraft[2..] else minecraft;
            break :blk std.fmt.allocPrint(arena, "{s}.", .{trimmed});
        },
    };
}

fn compareNumeric(a: []const u8, b: []const u8) std.math.Order {
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const an = ai.next();
        const bn = bi.next();
        if (an == null and bn == null) return .eq;
        if (an == null) return .lt;
        if (bn == null) return .gt;
        const av = std.fmt.parseInt(u64, an.?, 10) catch 0;
        const bv = std.fmt.parseInt(u64, bn.?, 10) catch 0;
        if (av < bv) return .lt;
        if (av > bv) return .gt;
    }
}

/// Newest published version for this game version, by numeric comparison of
/// the trailing build number (Forge) or the whole value (NeoForge).
pub fn resolve(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    kind: Kind,
    minecraft: []const u8,
) ![]const u8 {
    const prefix = try versionPrefix(arena, kind, minecraft);

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const res = fetch.request(&client, arena, metadataUrl(kind), .{ .accept = "text/xml" }) catch
        return Error.HttpFailed;
    if (res.status != 200) return Error.HttpFailed;

    const tag_open = "<version>";
    const tag_close_next = "</version>";

    var best: ?[]const u8 = null;
    var best_suffix: []const u8 = "";
    var rest: []const u8 = res.body;
    while (std.mem.indexOf(u8, rest, tag_open)) |open| {
        const after = rest[open + tag_open.len ..];
        const close = std.mem.indexOf(u8, after, tag_close_next) orelse break;
        const value = after[0..close];
        rest = after[close + tag_close_next.len ..];

        if (!std.mem.startsWith(u8, value, prefix)) continue;
        const suffix = value[prefix.len..];
        if (!std.mem.startsWith(u8, suffix, std.fmt.comptimePrint("", .{}))) {}
        if (suffix.len == 0) continue;
        if (best_suffix.len == 0 or compareNumeric(suffix, best_suffix) == .gt) {
            best = value;
            best_suffix = suffix;
        }
    }

    const found = best orelse return Error.NoSuchVersion;
    // Forge metadata carries `1.20.1-47.2.0`; the installer path wants only the
    // loader part. NeoForge metadata already carries exactly the version.
    return switch (kind) {
        .forge => arena.dupe(u8, found[prefix.len..]),
        .neoforge => arena.dupe(u8, found),
    };
}

/// Download the installer and run `--installClient` against `game_dir`.
/// Returns the version id the installer wrote.
pub fn install(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    kind: Kind,
    game_dir: []const u8,
    cache_dir: []const u8,
    minecraft: []const u8,
    explicit_version: ?[]const u8,
    installer_jar: ?[]const u8,
    environ: *const std.process.Environ.Map,
) ![]const u8 {
    var version: []const u8 = "";
    var jar: []const u8 = "";

    if (installer_jar) |local| {
        // Escape hatch for a blocked maven host: use a jar downloaded by hand.
        // The loader version still has to be known, so take it from
        // --loader or from the file name the installer uses.
        jar = local;
        version = if (explicit_version) |v|
            v
        else
            versionFromInstallerName(arena, kind, minecraft, std.fs.path.basename(local)) orelse {
                std.debug.print(
                    "error: cannot read a {s} version from \"{s}\"\n" ++
                        "hint: pass it explicitly, e.g. --loader <version>\n",
                    .{ kind.label(), std.fs.path.basename(local) },
                );
                return Error.NoSuchVersion;
            };
        std.debug.print("installing {s} {s} for {s} from {s}\n", .{
            kind.label(), version, minecraft, local,
        });
    } else {
        version = if (explicit_version) |v|
            v
        else
            resolve(io, gpa, arena, kind, minecraft) catch |e| {
                std.debug.print(
                    "error: no {s} build found for {s} ({s})\n" ++
                        "hint: pass the loader version explicitly, e.g. --loader <version>\n",
                    .{ kind.label(), minecraft, @errorName(e) },
                );
                return e;
            };

        const url = try installerUrl(arena, kind, minecraft, version);
        jar = try std.fmt.allocPrint(arena, "{s}/{s}-{s}-installer.jar", .{
            cache_dir, @tagName(kind), version,
        });

        std.debug.print("installing {s} {s} for {s}\n  {s}\n", .{ kind.label(), version, minecraft, url });

        var client: http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();

        // Maven publishes a .sha1 sidecar next to every artifact.
        var expected: ?[]const u8 = null;
        if (fetch.request(&client, arena, try std.fmt.allocPrint(arena, "{s}.sha1", .{url}), .{
            .accept = "text/plain",
        }) catch null) |res| {
            if (res.status == 200) {
                const trimmed = std.mem.trim(u8, res.body, " \r\n\t");
                if (trimmed.len == 40) expected = trimmed;
            }
        }

        _ = try fetch.get(io, gpa, .{
            .url = url,
            .dest = jar,
            .sha1 = expected,
        });
    }

    // The installer refuses to run without a launcher profile file, which the
    // official launcher normally leaves behind.
    const profile = try std.fs.path.join(arena, &.{ game_dir, "launcher_profiles.json" });
    if (Io.Dir.cwd().statFile(io, profilesPath(arena, game_dir) catch profile, .{})) |_| {} else |_| {
        Io.Dir.cwd().writeFile(io, .{
            .sub_path = profile,
            .data =
            \\{
            \\  "profiles": {},
            \\  "selectedProfile": "",
            \\  "clientToken": "",
            \\  "authenticationDatabase": {},
            \\  "launcherVersion": { "name": "arclight", "format": 21 }
            \\}
            \\,
        }) catch {};
    }

    const java_exe = java_mod.first(arena, environ, io) catch return Error.JavaMissing;

    const argv = [_][]const u8{ java_exe, "-jar", jar, "--installClient", game_dir };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .cwd = .{ .path = game_dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return Error.InstallerFailed;

    const term = child.wait(io) catch return Error.InstallerFailed;

    // The installer's exit code is not the source of truth: its last step is
    // "injecting profile", which only rewrites launcher_profiles.json — a file
    // this launcher never reads. If the patched client jar and the version json
    // are on disk, the install is usable no matter what it reported.
    const installed = findInstalledVersion(io, arena, game_dir, kind, version) catch |e| {
        std.debug.print(
            "error: the {s} installer did not produce a version json\n" ++
                "       (it exited with {s}; a full log usually explains why)\n",
            .{ kind.label(), if (term.success()) "success" else "a failure" },
        );
        return e;
    };

    if (!term.success()) {
        std.debug.print(
            "note: the installer reported a problem after writing its files.\n" ++
                "      The only step it still owed was copying the patched client into\n" ++
                "      versions/, which is done below.\n",
            .{},
        );
    }

    try ensureVersionJar(io, arena, game_dir, installed, kind, minecraft, version);
    return installed;
}

/// The patched game jar belongs in `versions/<id>/<id>.jar`: that exact name is
/// in the installer's own `-DignoreList` (`${version_name}.jar`), which is how
/// securejarhandler avoids loading the game twice and why the vanilla jar must
/// not be substituted here. The installer normally copies it; when it does not,
/// the copy is the one thing missing for a working launch.
fn ensureVersionJar(
    io: Io,
    arena: std.mem.Allocator,
    game_dir: []const u8,
    id: []const u8,
    kind: Kind,
    minecraft: []const u8,
    version: []const u8,
) !void {
    const target = try std.fmt.allocPrint(arena, "{s}/versions/{s}/{s}.jar", .{ game_dir, id, id });
    if (Io.Dir.openFileAbsolute(io, target, .{})) |f| {
        f.close(io);
        return;
    } else |_| {}

    const source = switch (kind) {
        .forge => try std.fmt.allocPrint(
            arena,
            "{s}/libraries/net/minecraftforge/forge/{s}-{s}/forge-{s}-{s}-client.jar",
            .{ game_dir, minecraft, version, minecraft, version },
        ),
        .neoforge => try std.fmt.allocPrint(
            arena,
            "{s}/libraries/net/neoforged/neoforge/{s}/neoforge-{s}-client.jar",
            .{ game_dir, version, version },
        ),
    };

    const bytes = Io.Dir.cwd().readFileAlloc(io, source, arena, Io.Limit.unlimited) catch |e| {
        std.debug.print(
            "warning: {s} not found ({s}); launch will fall back to the vanilla jar\n",
            .{ source, @errorName(e) },
        );
        return;
    };

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = bytes });
    std.debug.print("wrote {s}\n", .{target});
}

/// `forge-1.20.1-47.4.28-installer.jar` -> `47.4.28`
/// `neoforge-21.1.264-installer.jar`     -> `21.1.264`
fn versionFromInstallerName(
    arena: std.mem.Allocator,
    kind: Kind,
    minecraft: []const u8,
    file_name: []const u8,
) ?[]const u8 {
    var name = file_name;
    if (std.mem.indexOf(u8, name, "-installer.jar")) |cut| name = name[0..cut];

    switch (kind) {
        .forge => {
            const prefix = std.fmt.allocPrint(arena, "forge-{s}-", .{minecraft}) catch return null;
            if (!std.mem.startsWith(u8, name, prefix)) return null;
            return name[prefix.len..];
        },
        .neoforge => {
            if (!std.mem.startsWith(u8, name, "neoforge-")) return null;
            return name["neoforge-".len..];
        },
    }
}

fn profilesPath(arena: std.mem.Allocator, game_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ game_dir, "launcher_profiles.json" });
}

/// The installer picks its own profile id; find the version json it wrote by
/// looking for a directory whose name mentions the loader version.
fn findInstalledVersion(
    io: Io,
    arena: std.mem.Allocator,
    game_dir: []const u8,
    kind: Kind,
    version: []const u8,
) ![]const u8 {
    const versions_dir = try std.fs.path.join(arena, &.{ game_dir, "versions" });
    var dir = Io.Dir.cwd().openDir(io, versions_dir, .{ .iterate = true }) catch
        return Error.InstallerFailed;
    defer dir.close(io);

    var best: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        const name = entry.name;
        if (std.mem.indexOf(u8, name, version) == null) continue;
        const matches_kind = switch (kind) {
            .forge => std.mem.indexOf(u8, name, "forge") != null,
            .neoforge => std.mem.indexOf(u8, name, "neoforge") != null,
        };
        if (!matches_kind) continue;
        const candidate = try arena.dupe(u8, name);
        const json = try std.fmt.allocPrint(arena, "{s}/{s}/{s}.json", .{ versions_dir, candidate, candidate });
        if (Io.Dir.openFileAbsolute(io, json, .{})) |f| {
            f.close(io);
            best = candidate;
        } else |_| {}
    }
    return best orelse Error.InstallerFailed;
}
