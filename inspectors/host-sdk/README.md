# Inspector host API

Inspector code imports `host` from `@snap-o/host`. The host manages native windows,
app selection, ADB forwarding, and native helpers. Each inspector owns its HTTP
requests, event streams, and domain state.

## Connection

`host.connected` indicates whether the selected inspector has an available
endpoint. `host.baseURL` contains its forwarded HTTP base URL, or `null` while
disconnected. Listen for `connection` events and close pending requests and event
streams when the connection changes. Read app metadata and inspector descriptors
from `host.manifest`. Successful metadata always includes `processIdentity`, which
changes when the app process restarts. Each frontend validates its own protocol
version before opening requests; the host does not interpret protocol versions.

```ts
host.addEventListener("connection", (event) => {
  if (event.connected && host.baseURL) {
    const manifest = host.manifest;
    // Connect using the inspector's HTTP protocol.
  }
});
```

The embedded page uses a stable `snapo-inspector` origin. Each inspector has its own
persistent browser data store, scoped to the device, Android user, app, and inspector.
Use ordinary web storage for preferences; windows for the same provider share it. The host does not proxy HTTP requests.

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
