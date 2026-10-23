# Arclight Launcher

A small launcher for **Minecraft: Java Edition**, for the command line, written
in Zig.

```
arclight-launcher login              # sign in with your Microsoft account
arclight-launcher install 1.20.1     # fetch that version from Mojang's own servers
arclight-launcher launch 1.20.1      # start it  (--dry-run prints the argv instead)
arclight-launcher instance list      # structured instance records
arclight-launcher java               # show detected Java runtimes
arclight-launcher status --json      # scriptable
```

## Status

All commands work: `login`, `install`, `launch`, `versions`, `instance`,
`instances`, `java`, `status`, `logout`. `launch` refreshes the stored session
before starting the game, and `launch --dry-run` prints the exact argv without
running it.

Instances: `--instance <id>` runs the game in `<dir>/instances/<id>`, so saves,
mods, config and logs stay separate while `versions/`, `libraries/` and
`assets/` are shared by every instance. Without `--instance` the game runs
directly in `<dir>`, which is what a single install wants.

`instance list` is the structured interface. `instances` remains as a legacy
text list.

```
arclight-launcher instance list --json
arclight-launcher instance create survival --version 1.16.5 --name "Survival"
arclight-launcher instance show survival --json
arclight-launcher instance set survival --max-memory 4096 --jvm-arg -XX:+UseG1GC
arclight-launcher instance set survival --version 1.20.1
arclight-launcher instance remove survival             # move to .trash
arclight-launcher instance restore survival            # newest trashed copy
arclight-launcher instance remove survival --permanent # delete instead
```

The directory name is the stable instance id. `name` is display-only:

```json
{
  "schema_version": 1,
  "name": "Survival",
  "version": "1.16.5",
  "java": null,
  "min_memory_mb": 1024,
  "max_memory_mb": 4096,
  "jvm_args": ["-XX:+UseG1GC"]
}
```

`java` overrides JAVA_HOME/PATH for this instance. `min_memory_mb` and
`max_memory_mb` become `-Xms` / `-Xmx` before the extra JVM arguments.
`jvm_args` are appended after the arguments the version JSON asks for. On
`instance set`, passing `--jvm-arg` replaces the whole list; use
`--clear-jvm-args` to remove it. All fields are optional.

`instance remove` moves the directory to
`<dir>/.trash/instances/<id>/<timestamp>`; `instance restore <id>` puts the
newest copy back. `--permanent` deletes it without a trash copy.

`install` takes an optional mod loader:

```
arclight-launcher install 1.20.1 --fabric        # profile json from meta.fabricmc.net
arclight-launcher install 1.20.1 --forge         # runs the official installer
arclight-launcher install 1.21.1 --neoforge      # runs the official installer
```

## Requirements

**Zig 0.17.0.** This is built and tested against that release. Zig is pre-1.0
and changes its standard library between releases, so other versions are not
expected to compile; the version is pinned in `build.zig.zon` on purpose.

**Your own Microsoft Entra application (Client ID).** None is bundled or built
into the launcher: the allow list entry belongs to whoever registered it and
can be revoked at any time. Run `arclight-launcher login` with
no arguments and it prints the six steps. In short: register an application
with personal Microsoft accounts and public client flows enabled, request
access for it at <https://aka.ms/mce-reviewappid>, then pass the ID with
`--client-id`, `$ARCLIGHT_CLIENT_ID`, or a one-line `client_id` file in the
config directory. Until it is approved, signing in fails with `HTTP 403 Invalid
app registration` and exit code `11` — that is the API's answer, not a defect.

**A Microsoft account that owns Minecraft: Java Edition.** There is no offline
mode, no cracked account support, and no way to point the launcher at a
different authentication service.

**A Java runtime.** `arclight-launcher java` shows what it finds. A missing runtime is
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
are not covered — there is only one maintainer and neither has been tested, so
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
| 21 | required files missing |
| 30 | no Java runtime found |
| 40 | the game exited with a non-zero status |

`stdout` carries results and `stderr` carries progress, errors and hints, so
`arclight-launcher status --json | jq` is safe. Token values never appear in either.

## Building

```
zig build -Doptimize=ReleaseSafe
./zig-out/bin/arclight-launcher help
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
