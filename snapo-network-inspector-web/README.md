# Snap-O Network Inspector Web UI

This project contains the React renderer embedded in Snap-O's native macOS app. The Swift app hosts the built files in a `WKWebView` and provides device and network operations through the WebKit message bridge in `src/network/client.ts`.

The renderer also retains its HTTP transport so it can run in a browser-hosted environment. It contains only portable web UI code.

## Requirements

- Node.js 22.12+

## Development

```bash
cd snapo-network-inspector-web
npm install --registry=https://openai.firewall.socket.dev/npm/
npm run dev
```

Running the renderer by itself uses the HTTP endpoints under `/api/network/...`. To use the native WebKit bridge and inspect a connected device, build and run the Swift app in `snapo-app-mac`.

## Validation

```bash
npm run lint
npm test
npm run build
```

## Transport boundary

The renderer talks to `src/network/client.ts`. Inside Snap-O it invokes Swift commands and listens for events over the WebKit bridge. Outside Snap-O it attempts HTTP endpoints under `/api/network/...`.
