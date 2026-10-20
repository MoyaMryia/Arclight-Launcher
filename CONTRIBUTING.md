# Contributing

## What is accepted

- Reproducible bug reports against `zig build -Doptimize=ReleaseSafe` on
  Zig **0.17.0**, Linux only.
- Patches that make the code smaller, or that fix a bug.
- Patches that remove a dependency (there are none; keep it that way).

## What is rejected without discussion

The following are out of scope by design, not by oversight. Issues or pull
requests asking for them are closed without reply:

- a GUI, a TUI wizard, or any interactive prompt
- a Windows or macOS build, or platform-specific workarounds
- download/install of game files, libraries, assets, or Java runtimes
- mods, modpacks, mod loaders, or installer automation
- offline mode, cracked accounts, `authlib-injector`, or any auth bypass
- a bundled or default Client ID
- translations
- telemetry, analytics, or "update check" phoning home
- packaging into `.exe`, AppImage, Flatpak, Snap, AUR, or any release artifact

## Issue rules

- One issue per problem. Include the command, the exit code, and the full
  stderr.
- **Never paste tokens.** Redact `refresh_token`, `access_token`, and
  `identityToken`. If you paste one, revoke it.
- Off-topic, hostile, or AI-generated noise threads are **locked without
  reply**. Do not expect an explanation.
- There is no feature-request process. There is no roadmap. There is no
  maintainer obligation.

## Code rules

- Zig 0.17.0, standard library only. No `build.zig.zon` dependencies.
- `stdout` is for results, `stderr` for diagnostics. Preserve that.
- Exit codes are part of the interface. Do not change them without a note in
  the commit body.
- New modules need at least one `test` block that runs under `zig build test`.
- No code path may print a token.
- Do not add region detection beyond what `README.md` describes.
