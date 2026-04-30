# Snap-O Desktop (Electron)

This is the web-technology implementation of Snap-O's Network Inspector. The renderer is a React app with no direct Electron imports; desktop-specific behavior lives behind an Electron preload bridge so the same UI can later be hosted by a browser or MCP app transport.

The Electron backend talks directly to the local ADB server and Snap-O link sockets. It does not shell out to the Compose desktop app or the `snapo` CLI.

## Requirements

- Node.js 20+
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

## Package macOS helper

```bash
npm run package:mac
npm run package:mac:release
```

Those commands emit helper app bundles under `build/macos/main/app/` and `build/macos/main-release/app/`, matching the shape consumed by the host macOS app build.

## CLI

The packaged helper app can also run the existing Snap-O CLI commands instead of opening a window:

```bash
snapo network list
snapo network list --json
snapo network list --no-app-info
snapo network requests -e -n snapo_server_12345
snapo network requests -s emulator-5554 -n snapo_server_12345 --json
snapo network requests -d --no-stream
snapo network show -e -n snapo_server_12345 -r <requestId>
snapo network show -s emulator-5554 -n snapo_server_12345 -r <requestId> --json
```

For local development, use Electron's Node mode so the CLI runs without launching the desktop app:

```bash
npm run cli -- network list
```

## Transport Boundary

The renderer talks to `src/network/client.ts`. In Electron, that client uses `window.snapONetwork` from `electron/preload.ts`. Outside Electron, it attempts HTTP endpoints under `/api/network/...`, which gives a future Codex App browser or MCP-hosted version a compatible surface without rewriting UI code.
