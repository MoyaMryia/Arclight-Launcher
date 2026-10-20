# Contributing

Thanks for taking a look. This is a small project with one maintainer, so the
honest framing is: some things fit, some things don't, and the second list is
about capacity rather than taste.

## Welcome

- Bug fixes, especially reproducible ones with a failing case.
- Smaller code, fewer moving parts, clearer error messages.
- Documentation fixes.
- Platform support, if you can test it — see "Platform" below.
- Translations of the documentation.

## Out of scope

Might not wrong, just more than one person can keep working:

- a GUI, or a wizard that walks you through setup
- package manager recipes, prebuilt binaries, release artifacts
- automatic download of a Java runtime
- mods, modpacks, mod loaders, installer automation
- offline mode, cracked accounts, `authlib-injector`, any auth bypass
- a bundled or default Client ID
- alternative download sources or mirrors — the host list in `README.md` is
  the whole list
- telemetry, analytics, or a background update check

## Platform

Linux is the tested platform. Windows and macOS are currently uncovered:
nobody has tested them, so no claim is made either way. A patch that makes
either work is welcome — please include how you verified it.

## Issues

- One problem per issue. Include the command, the exit code and the full
  `stderr`.
- Never paste tokens. Redact `refresh_token`, `access_token` and
  `identityToken`; if one leaks, revoke it.
- Issues are read when time allows. Duplicates and off-topic threads may be
  closed without a reply — that is triage, not a verdict.

## Code

- Zig 0.17.0, standard library only. `build.zig.zon` has no dependencies and
  should stay that way.
- `stdout` is for results, `stderr` for diagnostics. Keep that split.
- Exit codes are part of the interface; changing one needs a note in the
  commit body.
- New modules need at least one `test` block that runs under `zig build test`.
- No code path may print a token.
- Do not add region detection beyond what `README.md` describes.
