# Arclight Launcher

A small launcher for **Minecraft: Java Edition**, for the command line, written
in Zig.

```
arclight login              # sign in with your Microsoft account
arclight install 1.20.1     # fetch that version from Mojang's own servers
arclight launch 1.20.1      # start it
arclight java               # show detected Java runtimes
arclight status --json      # scriptable
```

## Status

Work in progress. `versions`, `java`, `status` and `logout` work today;
`login`, `install` and `launch` are being written.

## Requirements

**Zig 0.17.0.** This is built and tested against that release. Zig is pre-1.0
and changes its standard library between releases, so other versions are not
expected to compile; the version is pinned in `build.zig.zon` on purpose.

**Your own Microsoft Entra application (Client ID).** None is bundled. You
register one (personal Microsoft accounts, public client flows enabled) and
request access for it at <https://aka.ms/mce-reviewappid>. Until it is
approved, signing in fails with `HTTP 403 Invalid app registration` and exit
code `11` — that is the API's answer, not a defect in this program.

**A Microsoft account that owns Minecraft: Java Edition.** There is no offline
mode, no cracked account support, and no way to point the launcher at a
different authentication service.

**A Java runtime.** `arclight java` shows what it finds. A missing runtime is
reported as an error; the launcher does not download one.

## What it downloads, and from where

Game content comes from Mojang's own endpoints, the same ones the official
launcher uses:

| host | content |
|---|---|
| `piston-meta.mojang.com` | version manifest, version json, java runtime index |
| `piston-data.mojang.com` | client jar |
| `libraries.minecraft.net` | libraries |
| `resources.download.minecraft.net` | assets |

There is no bundled client jar, no third-party mirror, and no download-source
setting to configure. Every file is verified against the SHA-1 published in
Mojang's metadata before it is used, and nothing is written into place until
the hash matches.

## Platform support

Mainly Linux: that is what it is developed and tested on. Windows and macOS
are not covered — there is one maintainer and neither has been tested, so
nothing is promised there. Patches that add or fix support are welcome if you
can test them.

## Regional notes

No region detection is performed; the build default is `-Dregion-gate=none`.
Downloads go to Mojang's official CDN and nowhere else, and there is no mirror
or "download source" option to switch to something local. If you redistribute
this program, compliance in your jurisdiction is yours to handle.

## Support

Best effort, by one person. There is no support agreement, no SLA and no
release schedule. Issues on GitHub are the only channel — there is no chat
server. If something sits unanswered for a while, that is capacity, not
judgement.

## Exit codes

Scripts can branch on these.

| code | meaning |
|-----:|---------|
| 0 | success |
| 2 | usage error |
| 3 | config error (unreadable account file, no `HOME`) |
| 10 | authentication failed |
| 11 | Client ID not authorized by Minecraft Services (HTTP 403) |
| 12 | account does not own the game |
| 20 | download failed |
| 30 | no Java runtime found |
| 70 | not implemented yet |

`stdout` carries results and `stderr` carries progress, errors and hints, so
`arclight status --json | jq` is safe. Token values never appear in either.

## Building

```
zig build -Doptimize=ReleaseSafe
./zig-out/bin/arclight help
```

Source only: no binaries are published, and the repository ships no release
artifacts.

## Documentation

English for now. Translations are welcome as pull requests.

## Security

Tokens are stored at `${XDG_CONFIG_HOME:-~/.config}/arclight/account.json`
with mode `0600`, and are never logged. See `SECURITY.md`.

## License

GPL-3.0-or-later. See `LICENSE`.
