//! Microsoft account sign-in, device code flow.
//!
//! Chain, exactly as documented at
//! https://minecraft.wiki/w/Microsoft_authentication :
//!
//!   1. Microsoft OAuth2 (consumers tenant only)  -> MS access token
//!   2. Xbox Live user token                      -> xbl token + uhs
//!   3. XSTS (rp://api.minecraftservices.com/)    -> xsts token
//!   4. /authentication/login_with_xbox           -> Minecraft access token
//!   5. /entitlements/mcstore + /minecraft/profile -> ownership + UUID
//!
//! The device code flow is used instead of a loopback redirect: it needs no
//! local HTTP server, no port, and works over SSH.

const std = @import("std");
const Io = std.Io;
const http = std.http;

const fetch = @import("fetch.zig");

const tenant = "consumers";
const scope = "XboxLive.signin offline_access";

const url_device_code = "https://login.microsoftonline.com/" ++ tenant ++ "/oauth2/v2.0/devicecode";
const url_token = "https://login.microsoftonline.com/" ++ tenant ++ "/oauth2/v2.0/token";
const url_xbl = "https://user.auth.xboxlive.com/user/authenticate";
const url_xsts = "https://xsts.auth.xboxlive.com/xsts/authorize";
const url_mc_login = "https://api.minecraftservices.com/authentication/login_with_xbox";
const url_entitlements = "https://api.minecraftservices.com/entitlements/mcstore";
const url_profile = "https://api.minecraftservices.com/minecraft/profile";

pub const Error = error{
    /// The Client ID is not on Mojang's allow list (HTTP 403).
    AppIdNotAuthorized,
    /// Sign-in worked, but the account does not own the game.
    GameNotOwned,
    /// Anything else in the chain: bad config, declined consent, XSTS XErr.
    AuthFailed,
    /// Transport level.
    HttpFailed,
    OutOfTime,
};

pub const Result = struct {
    client_id: []const u8,
    name: []const u8,
    /// 32 lowercase hex chars, no dashes.
    uuid: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    xuid: []const u8,
};

pub const Options = struct {
    client_id: []const u8,
};

const DeviceCode = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    expires_in: u64 = 900,
    interval: u64 = 5,
};

const TokenResponse = struct {
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    error_description: ?[]const u8 = null,
};

const form = "application/x-www-form-urlencoded";
const json = "application/json";

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn login(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: Options,
) !Result {
    if (opts.client_id.len < 30) return Error.AuthFailed;

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // ---- 1. device code ------------------------------------------------
    const dc_body = try std.fmt.allocPrint(
        arena,
        "client_id={s}&scope={s}",
        .{ opts.client_id, "XboxLive.signin%20offline_access" },
    );
    const dc_res = fetch.request(&client, arena, url_device_code, .{ .payload = dc_body, .content_type = form }) catch
        return Error.HttpFailed;
    if (dc_res.status != 200) {
        say("error: Microsoft rejected the Client ID (HTTP {d})\n{s}\n", .{ dc_res.status, dc_res.body });
        return Error.AuthFailed;
    }
    const dc = std.json.parseFromSliceLeaky(DeviceCode, arena, dc_res.body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.AuthFailed;

    say(
        \\
        \\  Open this URL in a browser:
        \\    {s}
        \\  and enter the code:
        \\    {s}
        \\
        \\  Waiting for the sign-in to complete ({d} minutes)...
        \\
    , .{ dc.verification_uri, dc.user_code, dc.expires_in / 60 });

    // ---- 1b. poll for the MS token -------------------------------------
    const poll_body = try std.fmt.allocPrint(
        arena,
        "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id={s}&device_code={s}",
        .{ opts.client_id, dc.device_code },
    );

    var interval = dc.interval;
    var waited: u64 = 0;
    var ms_access: []const u8 = undefined;
    var ms_refresh: []const u8 = undefined;

    while (waited < dc.expires_in) {
        Io.sleep(io, .{ .nanoseconds = @intCast(interval * std.time.ns_per_s) }, .awake) catch {};
        waited += interval;

        const res = fetch.request(&client, arena, url_token, .{ .payload = poll_body, .content_type = form }) catch
            continue;
        const parsed = std.json.parseFromSliceLeaky(TokenResponse, arena, res.body, .{
            .ignore_unknown_fields = true,
        }) catch continue;

        if (res.status == 200) {
            ms_access = parsed.access_token orelse return Error.AuthFailed;
            ms_refresh = parsed.refresh_token orelse "";
            break;
        }
        const err = parsed.@"error" orelse return Error.AuthFailed;
        if (std.mem.eql(u8, err, "authorization_pending")) continue;
        if (std.mem.eql(u8, err, "slow_down")) {
            interval += 5;
            continue;
        }
        say("error: sign-in failed: {s}\n{s}\n", .{
            err, parsed.error_description orelse "",
        });
        return Error.AuthFailed;
    }

    if (ms_access.len == 0) return Error.OutOfTime;
    say("  Microsoft sign-in complete.\n", .{});

    // ---- 2..5 ----------------------------------------------------------
    return complete(io, arena, &client, opts.client_id, ms_access, ms_refresh);
}

/// Resolve the rest of the chain from a Microsoft access token. Shared by
/// `login` (fresh) and `refresh` (after a token refresh).
fn complete(
    io: Io,
    arena: std.mem.Allocator,
    client: *http.Client,
    client_id: []const u8,
    ms_access: []const u8,
    ms_refresh: []const u8,
) !Result {
    _ = io;

    // ---- Xbox Live ------------------------------------------------------
    const xbl_body = try std.fmt.allocPrint(arena,
        \\{{"Properties":{{"AuthMethod":"RPS","SiteName":"user.auth.xboxlive.com","RpsTicket":"d={s}"}},"RelyingParty":"http://auth.xboxlive.com","TokenType":"JWT"}}
    , .{ms_access});
    const xbl_res = fetch.request(client, arena, url_xbl, .{ .payload = xbl_body, .content_type = json }) catch
        return Error.HttpFailed;
    if (xbl_res.status != 200) {
        say("error: Xbox Live rejected the token (HTTP {d})\n", .{xbl_res.status});
        return Error.AuthFailed;
    }
    const Xbl = struct {
        Token: []const u8,
        DisplayClaims: struct {
            xui: []struct {
                uhs: []const u8,
                xid: ?[]const u8 = null,
            },
        },
    };
    const xbl = std.json.parseFromSliceLeaky(Xbl, arena, xbl_res.body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.AuthFailed;
    if (xbl.DisplayClaims.xui.len == 0) return Error.AuthFailed;
    const uhs = xbl.DisplayClaims.xui[0].uhs;
    const xuid = xbl.DisplayClaims.xui[0].xid orelse "";

    // ---- XSTS -----------------------------------------------------------
    const xsts_body = try std.fmt.allocPrint(arena,
        \\{{"Properties":{{"SandboxId":"RETAIL","UserTokens":["{s}"]}},"RelyingParty":"rp://api.minecraftservices.com/","TokenType":"JWT"}}
    , .{xbl.Token});
    const xsts_res = fetch.request(client, arena, url_xsts, .{ .payload = xsts_body, .content_type = json }) catch
        return Error.HttpFailed;
    if (xsts_res.status != 200) {
        if (std.json.parseFromSliceLeaky(struct { XErr: ?u32 = null }, arena, xsts_res.body, .{
            .ignore_unknown_fields = true,
        })) |x| {
            say("{s}\n", .{xstsHint(x.XErr)});
        } else |_| {}
        return Error.AuthFailed;
    }
    const Xsts = struct { Token: []const u8 };
    const xsts = std.json.parseFromSliceLeaky(Xsts, arena, xsts_res.body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.AuthFailed;

    // ---- Minecraft token ------------------------------------------------
    const mc_body = try std.fmt.allocPrint(arena,
        \\{{"identityToken":"XBL3.0 x={s};{s}"}}
    , .{ uhs, xsts.Token });
    const mc_res = fetch.request(client, arena, url_mc_login, .{ .payload = mc_body, .content_type = json }) catch
        return Error.HttpFailed;
    if (mc_res.status != 200) {
        if (std.mem.indexOf(u8, mc_res.body, "Invalid app registration") != null) {
            say(
                \\error: this Client ID is not authorized by Minecraft Services.
                \\       Request access for it at https://aka.ms/mce-reviewappid
                \\       Nothing is bundled here: each user registers their own application.
                \\
            , .{});
            return Error.AppIdNotAuthorized;
        }
        say("error: Minecraft login failed (HTTP {d})\n{s}\n", .{ mc_res.status, mc_res.body });
        return Error.AuthFailed;
    }
    const Mc = struct {
        access_token: []const u8,
        expires_in: u64 = 86400,
    };
    const mc = std.json.parseFromSliceLeaky(Mc, arena, mc_res.body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.AuthFailed;

    // ---- ownership ------------------------------------------------------
    const auth_header = try std.fmt.allocPrint(arena, "Bearer {s}", .{mc.access_token});

    const ent_res = fetch.request(client, arena, url_entitlements, .{ .authorization = auth_header }) catch
        return Error.HttpFailed;
    const Ent = struct {
        items: []const struct { name: []const u8 } = &.{},
    };
    var owns = false;
    if (std.json.parseFromSliceLeaky(Ent, arena, ent_res.body, .{
        .ignore_unknown_fields = true,
    })) |ent| {
        for (ent.items) |item| {
            if (std.mem.eql(u8, item.name, "game_minecraft") or
                std.mem.eql(u8, item.name, "product_minecraft"))
            {
                owns = true;
            }
        }
    } else |_| {}

    // ---- profile --------------------------------------------------------
    const prof_res = fetch.request(client, arena, url_profile, .{ .authorization = auth_header }) catch
        return Error.HttpFailed;
    if (prof_res.status != 200) {
        say(
            \\error: this account has no Minecraft profile.
            \\       It does not own Java Edition, or it is a Game Pass account that has
            \\       never signed in to the official launcher.
            \\
        , .{});
        return Error.GameNotOwned;
    }
    const Prof = struct { id: []const u8, name: []const u8 };
    const prof = std.json.parseFromSliceLeaky(Prof, arena, prof_res.body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.AuthFailed;

    if (!owns) {
        say("warning: the account has no game_minecraft entitlement; the profile exists anyway.\n", .{});
    }

    return .{
        .client_id = client_id,
        .name = prof.name,
        .uuid = prof.id,
        .access_token = mc.access_token,
        .refresh_token = ms_refresh,
        .xuid = xuid,
    };
}

fn xstsHint(xerr: ?u32) []const u8 {
    const code = xerr orelse return "error: XSTS authorization failed (no XErr given)";
    return switch (code) {
        2148916227 => "error: this account is banned from Xbox Live.",
        2148916233 => "error: this account has no Xbox profile. Sign in once at https://www.xbox.com/ and retry.",
        2148916235 => "error: Xbox Live is not available in this account's country.",
        2148916236, 2148916237 => "error: this account needs adult verification (South Korea).",
        2148916238 => "error: this is a child account. An adult must add it to a Microsoft family first.",
        else => "error: XSTS authorization failed (unmapped error code).",
    };
}

/// Exchange a stored refresh token for a fresh Minecraft access token.
pub fn refresh(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    client_id: []const u8,
    refresh_token: []const u8,
) !Result {
    if (refresh_token.len == 0) return Error.AuthFailed;

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const body = try std.fmt.allocPrint(
        arena,
        "grant_type=refresh_token&client_id={s}&refresh_token={s}&scope=XboxLive.signin%20offline_access",
        .{ client_id, refresh_token },
    );
    const res = fetch.request(&client, arena, url_token, .{ .payload = body, .content_type = form }) catch
        return Error.HttpFailed;
    if (res.status != 200) {
        say(
            \\error: the stored session could not be refreshed.
            \\       The refresh token may be bound to a different Client ID,
            \\       or it may have been revoked. Run `arclight login` again.
            \\
        , .{});
        return Error.AuthFailed;
    }
    const parsed = std.json.parseFromSliceLeaky(TokenResponse, arena, res.body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.AuthFailed;

    const access = parsed.access_token orelse return Error.AuthFailed;
    const rotated = parsed.refresh_token orelse refresh_token;
    return complete(io, arena, &client, client_id, access, rotated);
}
