# Snap-O App Inspector Web UI

This project contains the Preact App Inspector renderer embedded in Snap-O's native macOS app. The Swift app hosts the built files in a `WKWebView` and provides device, Network Inspector, and Snap-O Tweaks operations through the WebKit message bridge in `src/network/client.ts`.

Components use `preact` and `preact/hooks` with native DOM events. Text inputs use `onInput` for live edits. Expensive render trees use `useMemo` to retain unchanged children. Icons use `lucide-preact`; React, ReactDOM, and `preact/compat` are not used.

The full inspector requires Snap-O's native WebKit bridge. There is no standalone HTTP host or MCP Apps integration.

## Requirements

- Node.js 22.12+

## Development

```bash
cd snapo-network-inspector-web
npm install --registry=https://openai.firewall.socket.dev/npm/
npm run dev
```

To inspect a connected device, build and run the Swift app in `snapo-app-mac`. The development server provides the synthetic request preview below; opening the full inspector without the native bridge is unsupported.

### Request detail preview

With the development server running, open `/preview.html` to review the request detail layout with synthetic data. The selector includes JSON, HTTP error, server-sent event, and connection failure examples. Sections, JSON expansion, and copy controls use the real detail component. No device or API server is needed.

The preview uses a separate HTML entry point and a client that only copies text and downloads files. It cannot discover devices or connect to inspectors. Neither the preview nor its client is included in the production build. Changes to the shared detail components and styles appear through hot reload.

## Validation

```bash
npm run lint
npm test
npm run build
```

## Transport boundary

The renderer talks to `src/network/client.ts`, which invokes Swift commands and listens for events over the WebKit bridge. Snap-O owns device access and persistent inspector preferences. The CLI and Android APIs are separate from this renderer.
