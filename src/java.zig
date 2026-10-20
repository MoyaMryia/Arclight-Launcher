//! Locate a Java runtime. This tool never downloads a JDK: a missing runtime
//! is a hard error with a message that tells the user what to do.

const std = @import("std");
const Io = std.Io;

pub const Error = error{JavaNotFound};

fn isExecutableFile(io: Io, path: []const u8) bool {
    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Collect `java` candidates, in preference order:
///   1. `$ARCLIGHT_JAVA` (explicit override)
///   2. `$JAVA_HOME/bin/java`
///   3. every `PATH` entry containing an executable `java`
///
/// Returns a de-duplicated list allocated from `arena`.
pub fn candidates(
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    io: Io,
) ![][]const u8 {
    var seen = std.StringHashMap(void).init(arena);
    var out: std.ArrayList([]const u8) = .empty;

    const push = struct {
        fn call(
            list: *std.ArrayList([]const u8),
            seen_map: *std.StringHashMap(void),
            value: []const u8,
        ) !void {
            if (value.len == 0) return;
            if (seen_map.contains(value)) return;
            try seen_map.put(value, {});
            try list.append(seen_map.allocator, value);
        }
    }.call;

    // 1. explicit override
    if (environ.get("ARCLIGHT_JAVA")) |custom| {
        if (custom.len != 0) try push(&out, &seen, try arena.dupe(u8, custom));
    }

    // 2. JAVA_HOME
    if (environ.get("JAVA_HOME")) |home| {
        if (home.len != 0) {
            const path = try std.fs.path.join(arena, &.{ home, "bin", "java" });
            if (isExecutableFile(io, path)) try push(&out, &seen, path);
        }
    }

    // 3. PATH
    if (environ.get("PATH")) |path_var| {
        var it = std.mem.splitScalar(u8, path_var, ':');
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            const path = try std.fs.path.join(arena, &.{ entry, "java" });
            if (isExecutableFile(io, path)) try push(&out, &seen, path);
        }
    }

    return out.toOwnedSlice(arena);
}

/// Best-effort first match. Never returns a JDK newer requirement than asked
/// for; version probing happens in `launch` where the child process is needed.
pub fn first(
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    io: Io,
) ![]const u8 {
    const list = try candidates(arena, environ, io);
    if (list.len == 0) return Error.JavaNotFound;
    return list[0];
}
