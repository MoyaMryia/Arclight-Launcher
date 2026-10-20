# Security Policy

## What this tool stores

| item | where | protection |
|---|---|---|
| Microsoft refresh token | `${XDG_CONFIG_HOME:-~/.config}/arclight/account.json` | file mode `0600`, directory created by the tool |
| Minecraft access token | memory only, never written | — |
| Client ID | `account.json` | public value, not a secret |

There is no keyring integration and no encryption at rest. The threat model is
"another local user on the same machine", not "the disk is stolen".

## Invariants

These are enforced by review, and a violation is a security bug:

1. **No token is ever written to a log, an error message, or `--json` output.**
   The `store.Public` view exists exactly for this.
2. **No telemetry, no update check, no analytics.** The binary contacts only
   the Microsoft/Xbox/Mojang authentication endpoints described in
   `README.md`.
3. **No game content is fetched.** This is a launcher, not a downloader.

If you find code that breaks one of these, treat it as a vulnerability.

## Reporting

Open a GitHub issue titled `[security] <one line summary>` **without**
reproduction details, and state that you are reporting a vulnerability. You
will be asked for details through a private channel.

Do not publish a reproducer before a fix ships.

If a token may have leaked, revoke it first: signing out of the account in
`arclight logout`, then changing the Microsoft account password, invalidates the
refresh token.

## Out of scope

- Anything requiring a bundled Client ID (there is none, and there is no
  allowlisted ID you can use).
- "My antivirus flags the binary." You built it yourself; there is no binary
  distributed by the author.
- Findings that require an attacker who already has read access to your user
  account.
