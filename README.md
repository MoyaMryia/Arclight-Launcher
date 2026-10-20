# Arclight Launcher

A minimal Minecraft: **Java Edition** launcher for the command line.

```
arclight login              # Microsoft account, device code flow
arclight install 1.20.1     # fetch that version from Mojang's own servers
arclight launch 1.20.1      # start it
arclight java               # list detected runtimes
arclight status --json      # scriptable
```

---

## Hard constraints

Read these before opening an issue. They are not negotiable.

**1. Requires Zig 0.17.0 exactly.**

Zig is pre-1.0 and its standard library breaks between releases. This project
is pinned to `0.17.0` and is not expected to build on `0.16` or `0.18`.
There are no binaries, no releases, and no CI artifacts.

```
zig build -Doptimize=ReleaseSafe
./zig-out/bin/arclight help
```

**2. Requires your own Microsoft Entra application (Client ID).**

No Client ID is bundled, and none will be provided. You must:

- register an application in Microsoft Entra ID (personal Microsoft accounts,
  public client flows enabled),
- request access for it at <https://aka.ms/mce-reviewappid>,
- wait for approval (weeks, not minutes).

Without approval, `arclight login` fails with `HTTP 403 Invalid app registration`
and exit code `11`. That is expected behaviour, not a bug.

**3. Microsoft account required. There is no offline mode.**

No cracked accounts, no `authlib-injector`, no "offline login". The account
must own Minecraft: Java Edition.

**4. It does not host, mirror, or redistribute game content.**

Versions, libraries and assets are fetched on demand from Mojang's own
endpoints — the same sources the official launcher uses:

```
piston-meta.mojang.com        version manifest, version json, java runtime index
piston-data.mojang.com        client.jar
libraries.minecraft.net       libraries
resources.download.minecraft.net   assets
```

There is **no bundled client jar, no third-party mirror, and no
download-source setting**. The only host list in the code is the one above, and
every downloaded file is verified against the SHA-1 published in Mojang's own
metadata before it is used.

Fetching from the official source on the user's behalf is what every launcher
in Mojang's AppID allowlist does (MultiMC, Prism, ATLauncher, Modrinth App).
What none of them may do — and this project never does — is serve copies of
game content from its own infrastructure.

**5. Linux only. Unsupported elsewhere.**

Windows and macOS are not tested and not supported. The code deliberately does
not contain platform-specific workarounds.

**6. No support, no SLA, no roadmap.**

This project may be abandoned at any time without notice. There is no
community chat, no Discord, no QQ group, and there will not be one. Issues are
for reproducible bugs, not for feature requests or usage help.

**7. English only.**

No translation will be accepted. This is a deliberate constraint.

---

## Regional compliance

The build defaults to `-Dregion-gate=none`: **no region detection is
performed.**

The upstream author:

- does not distribute binaries,
- does not operate any download server, mirror, or relay,
- does not offer a download-source setting: the binary talks to Mojang's
  official endpoints and to nothing else.

If you build and distribute this tool in a jurisdiction where providing
game-download functionality requires authorization, **you** are responsible
for your own compliance. A `-Dregion-gate=tz` level exists for development
convenience only and is explicitly **not** a compliance measure — do not use
it as one.

---

## Exit codes

Scripts branch on these.

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

`stdout` carries results, `stderr` carries progress and errors, so
`arclight status --json | jq` is safe.

---

## Security

Tokens are stored at `${XDG_CONFIG_HOME:-~/.config}/arclight/account.json` with
mode `0600`. Token values never appear in logs or in `--json` output. See
`SECURITY.md`.

## License

GPL-3.0-or-later. See `LICENSE`.
