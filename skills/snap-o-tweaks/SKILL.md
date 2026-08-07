---
name: snap-o-tweaks
description: Inspect, stream, and explicitly adjust live Android UI tweak values or invoke app-owned actions through Snap-O. Use when a request mentions Snap-O Tweaks, tweak-enabled Android apps, runtime UI parameters, Compose tweak or action controls, tweak discovery, previously adjusted or currently inactive tweaks, applying all user-made tweak changes, typed values, defaults or resets, tweak batches, explicitly registered actions, the Tweaks REST/SSE API, or selecting between CLI, macOS inspector, in-app overlay, and custom tweak interfaces.
---

# Snap-O Tweaks

Inspect live values and app-owned actions exposed by a debug-enabled Android app. Discovery, reads, and streams are read-only; change or reset values, or invoke an action, only when explicitly requested. Reset everything only when explicitly requested.

## Choose the interaction surface

- **Agents, shells, automation, or CI:** Default to the shared `snapo` CLI; it requires only Python 3 and Android Platform Tools on macOS or Linux.
- **Direct integration:** Use REST and server-sent events. See [references/protocol.md](references/protocol.md) for ADB forwarding, endpoints, typed values, batched updates, and streaming.
- **Desktop inspection:** Use Snap-O's macOS Tweaks inspector.
- **In-app controls:** Integrate `SnapOTweakOverlay`.
- **Custom interfaces:** Build a browser, native, or Compose UI; browsers require a same-origin proxy.

Read [references/interaction-surfaces.md](references/interaction-surfaces.md) for desktop, overlay, release/no-op, and custom-interface integration.

## Resolve the shared CLI

Use the executable shared by the installed Snap-O plugin:

```text
../../scripts/snapo
```

Resolve this plugin-root path relative to this `SKILL.md`, not the current working directory. Call the resolved path `$SNAPO_BIN`; if it is absent, the Snap-O plugin installation is incomplete.

ADB resolves from `PATH`, `ANDROID_SDK_ROOT`, or `ANDROID_HOME`. Use `--adb <path>` or `SNAPO_ADB` to override it; pass `--adb-host <host>` and `--adb-port <port>` together for a remote ADB server.

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

   Select devices with `-s <serial>`, `-d` (USB), or `-e` (emulator). Use `-n <socket>` for every subcommand except `apps` when selection is ambiguous.

3. Include ordinary or app-owned tweaks the user has adjusted, even when their declarations are not currently in composition:

   ```bash
   "$SNAPO_BIN" tweaks list --all -s <serial> -n <socket> --json
   "$SNAPO_BIN" tweaks get 'Typography/Font size' --all -s <serial> -n <socket> --json
   ```

   The expanded list combines current tweaks and actions with retained snapshots of previously adjusted ordinary or app-owned tweaks. App-owned history preserves the effective value and modification status, not the source, callbacks, or observers. In protocol version 4, use `"modified": true` to identify outstanding changes; a missing field always means false, even when `value` differs from `default`. For versions 1, 2, and 3, compare `value` with `default` instead. Actions never include `modified`. Separate screens can reuse tweak names with different declarations; preserve every descriptor from `list --all` instead of deduplicating by name. `get NAME --all` reports an error when multiple declarations match; use `list --all --json` to inspect them. Historical tweaks can be inspected while inactive, but can only be changed or reset when their declaration is active. Actions are active-only.

4. Observe live complete snapshots:

   ```bash
   "$SNAPO_BIN" tweaks watch -s <serial> -n <socket> --json
   "$SNAPO_BIN" tweaks watch -s <serial> -n <socket> --once --json
   ```

   `--once` exits after the first complete snapshot. `--json` emits newline-delimited JSON; `list` and `watch` emit complete tweak and action snapshots. Event streams contain only currently active declarations; use `list --all` for historical value adjustments.

## Change values only when requested

Inspect the descriptor first: the CLI parses `int`, `float`, `boolean`, `color`, `string`, and `enum` according to their declared types. Enum descriptors include an ordered list of enum names in `options`; use an exact option name when setting one. Quote names containing spaces or `/`, string values containing spaces, and hex colors.

```bash
"$SNAPO_BIN" tweaks set 'Typography/Font size' 42 -s <serial> -n <socket>
"$SNAPO_BIN" tweaks set 'Motion/Show' false -s <serial> -n <socket>
"$SNAPO_BIN" tweaks set 'Colors/Accent' '#3B82F6' -s <serial> -n <socket>
"$SNAPO_BIN" tweaks set 'Appearance/Theme' Dark -s <serial> -n <socket>
```

Successful updates and resets produce no output.

Reset only the explicitly requested value, or use `--all` only when the user explicitly requests resetting every modified tweak:

```bash
"$SNAPO_BIN" tweaks reset 'Typography/Font size' -s <serial> -n <socket>
"$SNAPO_BIN" tweaks reset --all -s <serial> -n <socket>
```

## Invoke actions only when requested

Apps declare actions with the `TweakAction(name) { ... }` composable, imported from `com.openai.snapo.tweaks.TweakAction`. The declaration returns `Unit`, registers its callback only while the owner remains in composition, and does not execute the callback during composition. Actions have `"type":"action"`, no `value`, and no `default`. Invoke an action only when the user explicitly requests its app-defined behavior:

```bash
"$SNAPO_BIN" tweaks action 'Preview/Refresh visible content' -s <serial> -n <socket>
```

The action command sends the registered name exactly as provided and does not accept arguments or execute arbitrary code. A descriptor marked `"conflicted":true` has multiple live owners and cannot be invoked; report the server's conflict and ask the app owner to register the shared action once or choose explicit, stable, unique names. Do not deduplicate callbacks or invent numeric suffixes. Reset-all ignores actions.

## Availability and failures

Tweaks use app-local `snapo_tweaks_<pid>` sockets and normally exist only in debug-enabled apps. If no socket appears, check device authorization and selection, whether the app is running, its live Tweaks dependency/integration, debug/runtime policy, and server startup. If a socket exists but `/tweaks` is empty, the current Compose UI has no active tweak declarations; `list --all` can still return retained adjustments. Adjustment history lasts only for the current Android app process. Do not enable release servers or modify apps or dependencies without an explicit request. Preserve validation errors; the CLI cleans up its own temporary ADB forwards.
