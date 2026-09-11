# Inspector host API

Inspector code imports `host` from `@snap-o/host`. The host manages native windows,
app selection, ADB forwarding, and native helpers. Each inspector owns its HTTP
requests, event streams, and domain state.

## Connection and ownership

The native host owns process and inspector isolation. It creates a separate page for each inspector and replaces the page when its app/process identity changes. Before releasing an old forwarded port, it unloads every page authorized to use it. A frontend does not need to route requests between processes or protect another inspector's endpoint.

`host.connected` indicates whether this page's selected inspector has an available endpoint. `host.baseURL` contains its forwarded HTTP base URL, or `null` while disconnected. Hidden inspector pages can remain alive and receive a disconnected connection state.

Listen for `connection` events to stop polling, abort pending requests, and close event streams while inactive or disconnected. Resume work when connected again. Dispose listeners and resources when your frontend unmounts. These are page resource lifetimes, not a replacement for host isolation.

Read app metadata from `host.manifest` and the selected descriptor from `host.inspector`. Each frontend validates its own `host.inspector.protocolVersion`; the host does not interpret domain protocol versions. Successful metadata includes `processIdentity`, which changes when the app process restarts.

```ts
host.addEventListener("connection", () => {
  if (host.connected && host.baseURL) {
    // Validate host.inspector.protocolVersion and start this tool's requests.
  } else {
    // Stop this page's requests, timers, and streams.
  }
});
```

The [Example tool](../../snapo-link-android/example/README.md) demonstrates this lifecycle using fake data, ordinary HTTP requests, and an event stream.

The embedded page uses a stable `snapo-inspector` origin. Each inspector has its own persistent browser data store, scoped to the device, Android user, app, and inspector. Use ordinary web storage for preferences; windows for the same provider share it. The host does not proxy HTTP response bodies.

## Toolbar

`setToolbar({ start, end })` replaces the inspector's toolbar. The start group has
at most three actions, including at most one search field. The optional end group
contains buttons. Each group appears in one native pill. Action IDs are unique
across both groups.

```ts
await host.setToolbar({
  start: [
    { type: "button", id: "clear", icon: "clear", label: "Clear", onClick: clear },
    { type: "search", id: "search", label: "Search", value: query, onChange: setQuery }
  ],
  end: [{ type: "button", id: "share", icon: "export", label: "Share", onClick: share }]
});
```

Set `enabled: false` to disable an action. Clear the toolbar when the frontend
unmounts with `setToolbar({ start: [] })`.

## Native helpers

- `openColorPicker({ value, onChange, onClose })` opens the native color picker and
  returns a handle with `setValue(value)` and `close()`. Closing an old handle
  cannot close a newer picker. Colors use hexadecimal RGBA strings.
- `copyText(text)` writes to the system clipboard.
- `saveFile({ name, data })` presents a save dialog for a `Blob` and returns whether
  the file was saved.

Use ordinary HTTP or HTTPS anchors for external links. App launch and inspector
selection belong to the native host, not this API.

## Package development

From `inspectors/`, run `npm ci`, `npm run build`, `npm test`, and `npm run typecheck`. `npm pack --workspace=@snap-o/host` builds and creates a local tarball. The package exposes compiled ES modules and TypeScript declarations under `dist/`; tests and TypeScript implementation sources are excluded.

Package versions follow the SDK's `package.json`. Host bridge API compatibility is recorded separately by each inspector's `hostApiVersion`. No package has been published by this setup. Names remain provisional; see [authoring package validation](../../release/authoring.md) before publishing.
