//! Mojang metadata: version manifest, version JSON, and the `rules` evaluator.
//!
//! Only two hosts are ever reached from here and from `install.zig`:
//! `piston-meta.mojang.com` (manifest, version json, java runtime index) and
//! the URLs those documents point at (piston-data, libraries.minecraft.net,
//! resources.download.minecraft.net). There is no mirror setting.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const manifest_url = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

pub const Manifest = struct {
    latest: Latest,
    versions: []const Version,

    pub const Latest = struct {
        release: []const u8,
        snapshot: []const u8,
    };
};

pub const Version = struct {
    id: []const u8,
    type: []const u8,
    url: []const u8,
    sha1: ?[]const u8 = null,
    releaseTime: ?[]const u8 = null,
};

pub const OsRule = struct {
    name: ?[]const u8 = null,
    arch: ?[]const u8 = null,
    /// Regex in the format. Not evaluated: a rule that only constrains
    /// `os.version` is treated as matching, which is permissive but only ever
    /// affects old macOS-only entries.
    version: ?[]const u8 = null,
};

pub const Rule = struct {
    action: []const u8,
    os: ?OsRule = null,
    /// Feature flags. The official launcher defaults every flag to false, and
    /// so do we: a rule keyed on a feature matches only when the flag is false.
    features: ?std.json.Value = null,
};

pub const Artifact = struct {
    /// Logging configs carry `id` instead of `path`.
    id: ?[]const u8 = null,
    path: []const u8 = "",
    sha1: []const u8 = "",
    size: u64 = 0,
    url: []const u8 = "",
};

pub const LibraryDownloads = struct {
    artifact: ?Artifact = null,
    classifiers: ?std.json.ArrayHashMap(Artifact) = null,
};

pub const Library = struct {
    name: []const u8,
    downloads: ?LibraryDownloads = null,
    rules: ?[]const Rule = null,
    /// Legacy natives mapping, e.g. `{"linux": "natives-linux"}`.
    natives: ?std.json.ArrayHashMap([]const u8) = null,
    /// Maven repository for libraries that predate `downloads`.
    url: ?[]const u8 = null,
};

pub const AssetIndex = struct {
    id: []const u8,
    sha1: ?[]const u8 = null,
    size: ?u64 = null,
    totalSize: ?u64 = null,
    url: []const u8,
};

pub const AssetObject = struct {
    hash: []const u8,
    size: u64 = 0,
};

pub const AssetIndexFile = struct {
    objects: std.json.ArrayHashMap(AssetObject),
    map_to_resources: bool = false,
    virtual: bool = false,
};

pub const ClientDownload = struct {
    sha1: []const u8 = "",
    size: u64 = 0,
    url: []const u8,
};

pub const Downloads = struct {
    client: ?ClientDownload = null,
    server: ?ClientDownload = null,
};

pub const JavaVersion = struct {
    component: []const u8 = "",
    majorVersion: u32 = 0,
};

pub const LoggingFile = struct {
    argument: []const u8 = "-Dlog4j.configurationFile=${path}",
    file: Artifact,
    type: []const u8 = "log4j2-xml",
};

pub const VersionJson = struct {
    id: []const u8,
    type: ?[]const u8 = null,
    mainClass: ?[]const u8 = null,
    assets: ?[]const u8 = null,
    assetIndex: ?AssetIndex = null,
    downloads: ?Downloads = null,
    libraries: ?[]const Library = null,
    javaVersion: ?JavaVersion = null,
    /// 1.13+: structured jvm/game arguments. Kept untyped for now.
    arguments: ?std.json.Value = null,
    /// 1.12.2 and older: a single template string.
    minecraftArguments: ?[]const u8 = null,
    inheritsFrom: ?[]const u8 = null,
    releaseTime: ?[]const u8 = null,
    logging: ?struct { client: ?LoggingFile = null } = null,
};

// ---------------------------------------------------------------- rules

pub fn osName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "windows",
        .macos => "osx",
        else => "linux",
    };
}

pub fn osArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        .arm => "arm32",
        else => @tagName(builtin.cpu.arch),
    };
}

fn ruleMatches(rule: Rule) bool {
    if (rule.os) |os| {
        if (os.name) |name| {
            if (!std.mem.eql(u8, name, osName())) return false;
        }
        if (os.arch) |arch| {
            if (!std.mem.eql(u8, arch, osArch())) return false;
        }
        // os.version is a regex we do not evaluate; permissive.
    }
    if (rule.features) |features| {
        if (features != .object) return false;
        var it = features.object.iterator();
        while (it.next()) |entry| {
            // Every feature defaults to false, so a rule matches only if the
            // document expects the flag to be false.
            switch (entry.value_ptr.*) {
                .bool => |b| if (b) return false,
                else => return false,
            }
        }
    }
    return true;
}

/// Vanilla semantics: no rules means allowed. Otherwise the document is
/// processed in order, the last matching rule decides, and a document with
/// rules that match nothing denies.
pub fn allowed(rules: ?[]const Rule) bool {
    const list = rules orelse return true;
    if (list.len == 0) return true;

    var result = false;
    for (list) |rule| {
        if (!ruleMatches(rule)) continue;
        result = std.mem.eql(u8, rule.action, "allow");
    }
    return result;
}

// ---------------------------------------------------------------- maven

pub const MavenPath = struct {
    /// `<group path>/<artifact>/<version>/<file>.jar`, relative to `libraries/`.
    rel: []const u8,
    url: []const u8,
};

/// Resolve `group:artifact:version[:classifier]` against the library's maven
/// base. Needed for entries that carry no `downloads` block: Fabric ships all
/// of its libraries that way.
pub fn mavenPath(
    arena: std.mem.Allocator,
    lib: Library,
    classifier: ?[]const u8,
) !?MavenPath {
    var parts = std.mem.splitScalar(u8, lib.name, ':');
    const group = parts.next() orelse return null;
    const artifact = parts.next() orelse return null;
    const version = parts.next() orelse return null;
    const name_classifier = parts.next();

    const cls = classifier orelse name_classifier;
    const file = if (cls) |c|
        try std.fmt.allocPrint(arena, "{s}-{s}-{s}.jar", .{ artifact, version, c })
    else
        try std.fmt.allocPrint(arena, "{s}-{s}.jar", .{ artifact, version });

    const group_path = try arena.dupe(u8, group);
    for (group_path) |*ch| {
        if (ch.* == '.') ch.* = '/';
    }

    const rel = try std.fmt.allocPrint(arena, "{s}/{s}/{s}/{s}", .{ group_path, artifact, version, file });
    const base = lib.url orelse "https://libraries.minecraft.net/";
    const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), rel });
    return .{ .rel = rel, .url = url };
}

// ---------------------------------------------------------------- loading

pub fn loadManifest(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cache_dir: []const u8,
) !Manifest {
    const path = try std.fs.path.join(arena, &.{ cache_dir, "version_manifest_v2.json" });
    _ = try @import("fetch.zig").get(io, gpa, .{ .url = manifest_url, .dest = path });

    const body = try Io.Dir.cwd().readFileAlloc(io, path, arena, Io.Limit.unlimited);
    return std.json.parseFromSliceLeaky(Manifest, arena, body, .{
        .ignore_unknown_fields = true,
    });
}

pub fn findVersion(manifest: Manifest, id: []const u8) ?Version {
    for (manifest.versions) |v| {
        if (std.mem.eql(u8, v.id, id)) return v;
    }
    return null;
}

pub fn loadVersionJson(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    version: Version,
    dest: []const u8,
) !VersionJson {
    _ = try @import("fetch.zig").get(io, gpa, .{
        .url = version.url,
        .dest = dest,
        .sha1 = version.sha1,
    });
    const body = try Io.Dir.cwd().readFileAlloc(io, dest, arena, Io.Limit.unlimited);
    return std.json.parseFromSliceLeaky(VersionJson, arena, body, .{
        .ignore_unknown_fields = true,
    });
}
