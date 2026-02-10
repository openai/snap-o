---
name: snap-o-network-inspector
description: Fetch and inspect Android network captures for a selected device/socket using the Snap-O CLI. Use when you need raw CDP request/response data, headers, bodies, status, or websocket events.
---

# Snap-O Network Inspector

Use this skill to pull raw network evidence from Snap-O.

## CLI Path

Use the bundled binary:

```bash
SNAPO_BIN=/Applications/Snap-O.app/Contents/MacOS/snapo
```

If Snap-O is not installed at that path, recommend installing it from:
https://openai.github.io/snap-o/

## Current Command Surface (from `snapo` help)

- `snapo network list`: lists available Snap-O link servers.
- `snapo network requests`: emits CDP network events for a server.
- `snapo network show`: shows full details for a request id (headers + request/response bodies).

Useful global selectors:
- `-s`, `--serial`: use a specific device serial.
- `-d`: use the single connected USB device.
- `-e`: use the single connected emulator.

## Core Flow

1. List available servers.

```bash
"$SNAPO_BIN" network list --json
```

Optional flags:
- `--no-app-info`: skip package/app metadata lookup for faster listing.

2. Pick a target serial and socket.
- If multiple devices are connected, ask which device/emulator to inspect.
- If multiple sockets exist, select `-n <socket_name>` explicitly.

3. Pull captured events.

```bash
"$SNAPO_BIN" network requests -s <serial> -n <socket_name> --no-stream --json
```

4. Inspect a single request deeply.

```bash
"$SNAPO_BIN" network show -s <serial> -n <socket_name> -r <request_id> --json
```

5. Re-check command help if output shape differs.

```bash
"$SNAPO_BIN" --help
"$SNAPO_BIN" network --help
"$SNAPO_BIN" network list --help
"$SNAPO_BIN" network requests --help
"$SNAPO_BIN" network show --help
```

## Common Fetch Recipes

List request start events with compact fields:

```bash
"$SNAPO_BIN" network requests -s <serial> -n <socket_name> --no-stream --json \
  | jq -rc 'select(.method=="Network.requestWillBeSent") | {requestId:.params.requestId, method:.params.request.method, url:.params.request.url}'
```

Filter by endpoint substring:

```bash
"$SNAPO_BIN" network requests -s <serial> -n <socket_name> --no-stream --json \
  | jq -rc 'select(((.params.request.url // .requestUrl // "") | contains("/api/const")))'
```

Get the most recent started request id:

```bash
"$SNAPO_BIN" network requests -s <serial> -n <socket_name> --no-stream --json \
  | jq -r 'select(.method=="Network.requestWillBeSent") | .params.requestId' \
  | tail -n 1
```

Then fetch full details:

```bash
"$SNAPO_BIN" network show -s <serial> -n <socket_name> -r <request_id> --json
```

## Missing Request Troubleshooting

If an expected request is absent:

1. Verify device selection (`-s`, `-d`, or `-e`).
2. Verify socket selection (`-n`) and avoid relying on implicit socket selection.
3. Confirm the request path actually executed.
4. Confirm that code path uses an HTTP client with Snap-O interception enabled.
5. If there are multiple clients, inspect alternate/non-default client wiring.

## Output Notes

- `--json` emits NDJSON, so use `jq` line-by-line.
- `network requests` emits Chrome DevTools Protocol (CDP)-style event records (for example, top-level `method` + `params`).
- Use `--no-stream` when you want a one-shot buffered snapshot.
- Use `jq 'keys'` on a sample line if fields differ across Snap-O versions.
