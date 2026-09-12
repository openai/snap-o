# Plugins

Apps bundle **plugins** that provide **tools**, such as Network, Tweaks, or a custom feature. A plugin includes its Android implementation and an optional **frontend**, the tool’s UI implementation. Snap-O discovers plugins and displays the selected tool’s frontend in the **Tool pane**.

The shared [plugin host SDK](../sdk/host/README.md) provides connection state, toolbar controls, and native helpers. Plugin frontends live beside their Android implementations:

- Network: `plugins/network/frontend`
- Tweaks: `plugins/tweaks/frontend`

For an end-to-end example, read [Build a plugin](../docs/plugins.md) and the [Plugin API reference](../docs/plugin-api.md).

## Directory layout

- `network/android/`: Network core, HTTP client integrations, and no-op variants.
- `network/frontend/`: Network tool UI.
- `tweaks/android/`: Tweaks core, Compose and Views integrations, overlays, and no-op variants.
- `tweaks/frontend/`: Tweaks tool UI.

Shared authoring support lives in [`sdk/`](../sdk/README.md). Demo apps live in [`examples/android/`](../examples/android/README.md).

## Naming compatibility

Plugins are the bundled extensions; tools are the features users interact with. Existing discovery fields, browser origins, and saved preference keys keep their original names. The published Android `NetworkInspector`, `NetworkInspectorConfig`, and `NetworkInspectorServer` APIs also retain their names. See the [discovery contract](../contracts/discovery/README.md#naming-compatibility) for the wire format.

## Development

From the repository root, start a tool's development server:

```sh
./gradlew :network:pluginDev
./gradlew :tweaks-core:pluginDev
```

Run one command per terminal. Gradle downloads the required Node.js runtime. In Snap-O, choose Develop → Use Development Server and enter the URL printed by the server. The Network server also serves `/preview.html` with synthetic request examples.

To check a frontend directly, use Node.js 22.12 or later and run these commands from its `frontend/` directory:

```sh
npm ci --registry=https://openai.firewall.socket.dev/npm/
npm run format:check
npm run lint
npm run typecheck
npm test
npm run build
```

Run the same checks from `sdk/host/` for the host SDK, including `npm run build`. Install dependencies in both frontend directories before running the shared import checks. These checks resolve relative paths and TypeScript aliases. Plugin frontends cannot import one another or host SDK internals.

## App-provided frontends

A plugin can include a frontend ZIP in its AAR. Its manifest descriptor references that asset. Snap-O reads the ZIP from the installed APK through ADB, without starting app code or serving frontend files over the tool endpoint. `index.html` is always the entry point. Both Network and Tweaks use this path. The Mac app contains no tool frontend. Older Android libraries without frontend metadata require an app rebuild with updated libraries, or an explicit development-server override.

See the [Gradle plugin](../sdk/gradle-plugin/README.md) for packaging, custom builds, and development commands. App developers consuming a published AAR do not need Node.js. The frontend and Android implementation update together when the app is rebuilt.

Snap-O checks the selected process identity and package revision before and after reading the archive. It caches up to four validated bundles, keyed by device, Android user, package revision, tool ID, and asset path. The host bounds compressed and expanded data to 16 MiB, limits archives to 1,024 entries, and rejects unsafe paths, symlinks, duplicate files, and invalid checksums. Files stay in memory. WebKit loads the unchanged HTML and assets through `snapo-inspector://<storage-uuid>/`. The origin stays stable for each provider and tool; a document query parameter changes on reload to reject stale bridge messages.

Develop → Inspect Current WebView in Safari enables WebKit's public inspection support. Open the page through Safari's Develop menu. No private WebKit inspection API is used.

## WebView safeguards

The macOS host installs WebKit content rules before running packaged HTML. A page can reach only its own forwarded tool endpoint. CSP response headers block remote scripts, frames, workers, forms, and other resources outside the self-contained frontend. WebKit Lockdown Mode disables WebRTC and reduces the browser's exposed features. Plugin frontends must not depend on WebAssembly or JavaScript evaluation from strings.

Storage is separate for each device, Android user, package, and tool. Pages without verified package metadata use temporary storage. Preferences from the former localhost origin or shared tool storage are not imported.

Switching tools keeps their pages alive. A hidden page retains permission to contact its own endpoint, but cannot present native panels. Before Snap-O releases a forwarded port, it unloads every page authorized to use that endpoint. An endpoint replacement therefore resets in-memory UI state, but preserves settings for the same provider.

Native messages must come from the owning WebView's current main document. The bridge bounds payload size, nesting, concurrent requests, and toolbar fields. Clipboard writes, color picker presentation, and external links require native confirmation. Exports use a save sheet, accept at most 64 MiB, and do not return the selected filesystem path to JavaScript. Only one native action runs at a time. File upload dialogs, JavaScript dialogs, media capture, and downloads are blocked.

Develop → Use Development Server sets a loopback URL for the selected app and tool. The explicit override also permits resources and WebSocket connections from that server. Its HTML is served by the development server, so it does not receive the packaged HTML's host CSP. This override is for trusted local development only.

Run `sh app-macos/scripts/test-tool-selection.sh` and `sh app-macos/scripts/test-tool-recovery.sh` from the repository root. These tests include hostile HTML, synthetic local servers, bridge rejection, storage scopes, and page retirement before port release.

These controls do not prevent WebKit vulnerabilities, resource exhaustion, or data sent through the explicitly allowed Android endpoint. An unresponsive page may delay endpoint cleanup; its port must not be released before it retires. App-provided frontends run JavaScript supplied by the inspected APK. These restrictions are not a guarantee that untrusted code is safe.

Snap-O requires macOS 26 or later. Keep macOS updated: these safeguards depend on WebKit's security fixes. Older WebKit builds ignored content rules for DNS prefetch and preconnect; the [WebKit fix](https://github.com/WebKit/WebKit/commit/ce84da3fd2d634040f3197d526b4ac914e45d2e6) landed in 2025. Tests on macOS 26.6.2 verify HTTP delivery and TCP connection attempts, including preconnect. They do not measure DNS queries or establish coverage of every supported WebKit build.

The standalone [Example tool](../examples/plugin/README.md) demonstrates the authoring APIs with fake data and locally staged packages.
