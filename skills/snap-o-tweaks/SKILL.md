---
name: snap-o-tweaks
description: Inspect, stream, and explicitly adjust live Android UI tweak values through Snap-O. Use when a request mentions Snap-O Tweaks, tweak-enabled Android apps, runtime UI parameters, Compose tweak or overlay controls, tweak discovery, typed values, defaults or resets, atomic tweak batches, the Tweaks REST/SSE API, or selecting between CLI, macOS inspector, in-app overlay, and custom tweak interfaces.
---

# Snap-O Tweaks

Inspect live values exposed by a debug-enabled Android app. Discovery, reads,
and streams are read-only; change or reset values only when explicitly
requested. Reset everything only when explicitly requested.

## Choose the interaction surface

- **Agents, shells, automation, or CI:** Default to the shared `snapo` CLI;
  it requires only Python 3 and Android Platform Tools on macOS or Linux.
- **Direct integration:** Use REST and server-sent events. See
  [references/protocol.md](references/protocol.md) for ADB forwarding,
  endpoints, typed values, atomic updates, and streaming.
- **Desktop inspection:** Use Snap-O's macOS Tweaks inspector.
- **In-app controls:** Integrate `SnapOTweakOverlay`.
- **Custom interfaces:** Build a browser, native, or Compose UI; browsers
  require a same-origin proxy.

Read [references/interaction-surfaces.md](references/interaction-surfaces.md)
for desktop, overlay, release/no-op, and custom-interface integration.

## Resolve the shared CLI

Use the executable shared by the installed Snap-O plugin:

```text
../../scripts/snapo
```

Resolve this plugin-root path relative to this `SKILL.md`, not the current
working directory. Call the resolved path `$SNAPO_BIN`; if it is absent, the
Snap-O plugin installation is incomplete.

ADB resolves from `PATH`, `ANDROID_SDK_ROOT`, or `ANDROID_HOME`. Use
`--adb <path>` or `SNAPO_ADB` to override it; pass `--adb-host <host>` and
`--adb-port <port>` together for a remote ADB server.

## Discover and inspect

1. Discover running tweak-enabled apps:

   ```bash
   "$SNAPO_BIN" tweaks apps --json
   ```

2. Select the device and, when multiple app sockets exist, the app socket:

   ```bash
   "$SNAPO_BIN" tweaks list -s <serial> -n <socket> --json
   "$SNAPO_BIN" tweaks get 'Typography/Font size' -s <serial> -n <socket> --json
   ```

   Select devices with `-s <serial>`, `-d` (USB), or `-e` (emulator). Use
   `-n <socket>` for every subcommand except `apps` when selection is ambiguous.

3. Observe live complete snapshots:

   ```bash
   "$SNAPO_BIN" tweaks watch -s <serial> -n <socket> --json
   "$SNAPO_BIN" tweaks watch -s <serial> -n <socket> --once --json
   ```

   `--once` exits after the first complete snapshot. `--json` emits
   newline-delimited JSON; `list` and `watch` emit complete tweak snapshots.

## Change values only when requested

Inspect the descriptor first: the CLI parses `int`, `float`, `boolean`,
`color`, and `string` according to their declared types. Quote names containing
spaces or `/`, string values containing spaces, and hex colors.

```bash
"$SNAPO_BIN" tweaks set 'Typography/Font size' 42 -s <serial> -n <socket> --json
"$SNAPO_BIN" tweaks set 'Motion/Show' false -s <serial> -n <socket> --json
"$SNAPO_BIN" tweaks set 'Colors/Accent' '#3B82F6' -s <serial> -n <socket> --json
```

Submit related updates together as one atomic JSON batch:

```bash
"$SNAPO_BIN" tweaks set \
  --values-json '{"Typography/Font size":42,"Motion/Show":false}' \
  -s <serial> -n <socket> --json
```

Reset only the explicitly requested value, or use `--all` only for an explicit
reset-everything request:

```bash
"$SNAPO_BIN" tweaks reset 'Typography/Font size' -s <serial> -n <socket> --json
"$SNAPO_BIN" tweaks reset --all -s <serial> -n <socket> --json
```

## Availability and failures

Tweaks use app-local `snapo_tweaks_<pid>` sockets and normally exist only in
debug-enabled apps. If none appear, check device authorization, device
selection, whether the app is running, and whether its current UI declares
tweaks. Do not enable release servers or modify apps or dependencies without
an explicit request. Preserve validation errors; the CLI cleans up its own
temporary ADB forwards.
