# Inspectors

This directory contains the Network and Tweaks frontends bundled with Snap-O. Each owns its UI, device protocol, styles, tests, and build. They share `@snap-o/host` for connection state, toolbar controls, and native helpers. The package layout and host interface are internal to Snap-O.

## Development

Use Node.js 22.12 or later. From this directory:

```sh
npm ci --registry=https://openai.firewall.socket.dev/npm/
npm run dev:network
npm run dev:tweaks
```

The Network development server also serves `/preview.html` with synthetic request examples. Connected inspectors require the macOS host. Debug builds accept a loopback development URL in `SNAPO_INSPECTOR_DEV_URL_NETWORK` or `SNAPO_INSPECTOR_DEV_URL_TWEAKS`.

```sh
npm run format:check
npm run lint
npm run typecheck
npm test
npm run build
```

Each package can run its own tests, typecheck, and build with `npm run <script> -w <package-name>`. Import checks resolve TypeScript imports, including relative paths and aliases. Inspectors cannot import one another or host SDK internals.

## WebView safeguards

The macOS host installs WebKit content rules before running bundled HTML. A page can reach only its own forwarded inspector endpoint. CSP blocks remote scripts, frames, workers, forms, and other resources outside the self-contained frontend. WebKit Lockdown Mode disables WebRTC and reduces the browser's exposed features. Inspectors must not depend on WebAssembly or JavaScript evaluation from strings.

Storage is separate for each device, Android user, package, and inspector. Pages without verified package metadata use temporary storage. Existing preferences shared only by inspector ID are not imported into the new storage scopes.

Switching inspectors keeps their pages alive. A hidden page retains permission to contact its own endpoint, but cannot present native panels. Before Snap-O releases a forwarded port, it unloads every page authorized to use that endpoint. An endpoint replacement therefore resets in-memory UI state, but preserves settings for the same provider.

Native messages must come from the owning WebView's current main document. The bridge bounds payload size, nesting, concurrent requests, and toolbar fields. Clipboard writes, color picker presentation, and external links require native confirmation. Exports use a save sheet, accept at most 64 MiB, and do not return the selected filesystem path to JavaScript. Only one native action runs at a time. File upload dialogs, JavaScript dialogs, media capture, and downloads are blocked.

The explicit debug development URL also permits resources from that loopback server. Its HTML is served by the development server, so it does not receive the bundled HTML's host CSP. This override is for trusted local development only.

Run `sh snapo-app-mac/scripts/test-inspector-selection.sh` and `sh snapo-app-mac/scripts/test-inspector-recovery.sh` from the repository root. These tests include hostile HTML, synthetic local servers, bridge rejection, storage scopes, and page retirement before port release.

These controls do not prevent WebKit vulnerabilities, resource exhaustion, or data sent through the explicitly allowed Android endpoint. An unresponsive page may delay endpoint cleanup; its port must not be released before it retires. App-provided frontend bundles are not loaded yet. Their loader still needs separate archive, path, and size validation.

Snap-O requires macOS 26 or later. Keep macOS updated: these safeguards depend on WebKit's security fixes. Older WebKit builds ignored content rules for DNS prefetch and preconnect; the [WebKit fix](https://github.com/WebKit/WebKit/commit/ce84da3fd2d634040f3197d526b4ac914e45d2e6) landed in 2025. Tests on macOS 26.6.2 verify HTTP delivery and TCP connection attempts, including preconnect. They do not measure DNS queries or establish coverage of every supported WebKit build.
