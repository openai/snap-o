# Snap-O Desktop (Electron)

This is the web-technology implementation of Snap-O's Network Inspector. The renderer is a React app with no direct Electron imports; desktop-specific behavior lives behind an Electron preload bridge so the same UI can later be hosted by a browser or MCP app transport.

The Electron backend talks directly to the local ADB server and Snap-O network sockets. It does not shell out to another desktop helper or the `snapo` CLI.

## Requirements

- Node.js 22.12+
- A running local ADB server
- A connected Android app with the Snap-O network dependencies

## Development

```bash
cd snapo-desktop-electron
npm install
npm run dev
```

## Build

```bash
npm run build
npm run start
```

Local `npm run start` and `npm run dev` builds expose **View > Toggle Developer Tools**.

## Package macOS helper

```bash
npm run package:mac
npm run package:mac:release
```

Those commands emit helper app bundles under `build/macos/main/app/` and `build/macos/main-release/app/`, matching the shape consumed by the host macOS app build.

The host macOS Xcode target invokes a Makefile target on each build and reruns packaging only when the helper is missing or Electron/package inputs are newer. Dependency install is also timestamp-based, so unchanged local Run builds do not rerun `npm ci`.

## CLI

The packaged helper app can also run the existing Snap-O CLI commands instead of opening a window:

```bash
snapo network list
snapo network list --json
snapo network list --no-app-info
snapo network requests -e -n snapo_network_12345
snapo network requests -s emulator-5554 -n snapo_network_12345 --json
snapo network requests -d --no-stream
snapo network requests -e --filter 'backend-api -sentinel' --json --no-stream
snapo network show -e -n snapo_network_12345 -r <requestId>
snapo network show -s emulator-5554 -n snapo_network_12345 -r <requestId> --json
```

`network requests --filter <text>` uses the same case-insensitive URL search syntax as the Network Inspector search bar. Separate terms require every included term, prefix a term with `-` to exclude it, and use quotes or backslash escapes for whitespace.

The CLI always replaces request `Authorization` and `Cookie` values and response `Set-Cookie` values with `[REDACTED]`.

For local development, use Electron's Node mode so the CLI runs without launching the desktop app:

```bash
npm run cli -- network list
```

## Transport Boundary

The renderer talks to `src/network/client.ts`. In Electron, that client uses `window.snapONetwork` from `electron/preload.ts`. Outside Electron, it attempts HTTP endpoints under `/api/network/...`, which gives a future Codex App browser or MCP-hosted version a compatible surface without rewriting UI code.
