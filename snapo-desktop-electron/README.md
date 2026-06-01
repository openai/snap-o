# Snap-O Desktop (Electron)

This is the web-technology implementation of Snap-O's Network Inspector. The renderer is a React app with no direct Electron imports; desktop-specific behavior lives behind an Electron preload bridge so the same UI can later be hosted by a browser or MCP app transport.

The Electron backend talks directly to the local ADB server and Snap-O network sockets. It does not shell out to another desktop helper or the `snapo` CLI.

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
snapo network requests -e -n snapo_network_12345
snapo network requests -s emulator-5554 -n snapo_network_12345 --json
snapo network requests -d --no-stream
snapo network requests -e --filter 'backend-api -sentinel' --sanitize --json --no-stream
snapo network show -e -n snapo_network_12345 -r <requestId>
snapo network show -s emulator-5554 -n snapo_network_12345 -r <requestId> --json
snapo network show -e -n snapo_network_12345 -r <requestId> --sanitize --json
```

`network requests --filter <text>` uses the same case-insensitive URL search syntax as the Network Inspector search bar. Separate terms require every included term, prefix a term with `-` to exclude it, and use quotes or backslash escapes for whitespace.

The CLI always replaces request `Authorization` and `Cookie` values and response `Set-Cookie` values with `[REDACTED]`. Add `--sanitize` to `network requests` or `network show` to remove those headers entirely, matching HAR export. `--sanitize` does not remove URL query values or request and response bodies.

For local development, use Electron's Node mode so the CLI runs without launching the desktop app:

```bash
npm run cli -- network list
```

## Transport Boundary

The renderer talks to `src/network/client.ts`. In Electron, that client uses `window.snapONetwork` from `electron/preload.ts`. Outside Electron, it attempts HTTP endpoints under `/api/network/...`, which gives a future Codex App browser or MCP-hosted version a compatible surface without rewriting UI code.
