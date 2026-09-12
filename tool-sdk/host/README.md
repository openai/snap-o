# Tool plugin host SDK

Tool plugin frontend code imports `host` from `@snap-o/tool-host`. The host manages native windows,
app selection, ADB forwarding, and native helpers. Each frontend owns its HTTP
requests, event streams, and domain state.

## Connection and ownership

The native host owns process and tool isolation. It creates a separate page for each tool and replaces the page when its app/process identity changes. Before releasing an old forwarded port, it unloads every page authorized to use it. A frontend does not need to route requests between processes or protect another tool's endpoint.

`host.connected` indicates whether this page's selected tool has an available endpoint. `host.baseURL` contains its forwarded HTTP base URL, or `null` while disconnected. Hidden tool pages can remain alive and receive a disconnected connection state.

`host.onConnection(callback)` delivers the current `ToolConnection` or `null` immediately. Return a cleanup function to close that connection's stream before replacement or disconnection. Unsubscribe when the UI unmounts; this also runs its cleanup. Use `connection.signal` with requests that should abort on disconnection.

Read app metadata from `host.manifest` and the selected descriptor from `host.tool`. Each frontend checks its tool's `protocolVersion`; the host does not interpret domain API versions.

```ts
const unsubscribe = host.onConnection((connection) => {
  if (!connection) return;
  const events = new EventSource(new URL("events", connection.baseURL));
  events.addEventListener("tick", showTick);
  return () => events.close();
});
```

Unloading the page closes its event streams. A loaded page's EventSource retries a closed transport, so replacing a stream or removing its UI still requires cleanup. This is separate from the host's process isolation.

The [Example tool](../../examples/tool/README.md) demonstrates this lifecycle using fake data, ordinary HTTP requests, and an event stream.

The embedded page uses a stable `snapo-inspector` origin. Each tool has its own persistent browser data store, scoped to the device, Android user, app, and tool. Use ordinary web storage for preferences; windows for the same provider share it. The host does not proxy HTTP response bodies.

## Toolbar

`setToolbar({ actions, search, endActions })` replaces the toolbar. The main area has at most three controls, counting optional search as one. `endActions` puts buttons in the separate trailing area. Action IDs are unique, and `search` is reserved when search is present.

```ts
await host.setToolbar({
  actions: [{ id: "clear", icon: "clear", label: "Clear", onClick: clear }],
  search: { label: "Search", value: query, onChange: setQuery },
  endActions: [{ id: "share", icon: "export", label: "Share", onClick: share }]
});
```

Set `enabled: false` to disable an action. Clear the toolbar with `setToolbar({})` when its UI unmounts.

## Native helpers

- `openColorPicker({ value, onChange, onClose })` opens the native color picker and
  returns a handle with `setValue(value)` and `close()`. Closing an old handle
  cannot close a newer picker. Colors use hexadecimal RGBA strings.
- `copyText(text)` writes to the system clipboard.
- `saveFile({ name, data })` presents a save dialog for a `Blob` and returns whether
  the file was saved.

Use ordinary HTTP or HTTPS anchors for external links. App launch and tool
selection belong to the native host, not this API.

## Package development

From `tool-sdk/host/`, run `npm ci`, `npm run build`, `npm test`, and `npm run typecheck`. `npm pack` builds and creates a local tarball. The package exposes compiled ES modules and TypeScript declarations under `dist/`; tests and TypeScript implementation sources are excluded.

Package versions follow the SDK's `package.json`. Host bridge API compatibility is recorded separately by each tool's `hostApiVersion`. No package has been published by this setup. See [authoring package validation](../../release/authoring.md) before publishing.
