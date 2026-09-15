# Tool plugin host SDK

Tool plugin frontend code imports `host` from `@snap-o/tool-host`. The host manages native windows,
app selection, API transport, and native helpers. Each frontend owns its HTTP
requests, event streams, and domain state.

## Connection and ownership

The native host owns process and tool isolation. It creates a separate page for each tool and replaces the page when its app or process identity changes. A frontend does not need to route requests between processes or protect another tool's endpoint.

The SDK initializes automatically when you subscribe. Toolbar and color picker calls also initialize it internally. Use `host.onError(callback)` to show initialization failures; it returns an unsubscribe function. Late subscribers receive the most recent initialization failure. A later connection subscription, toolbar call, or color picker call can retry initialization. A successful retry clears the stored failure.

`onError` also receives uncaught errors from connection callbacks. Native operation failures remain on that operation’s Promise; handle them at the call site. Your frontend still handles its own HTTP and JSON errors.

```ts
const stopErrors = host.onError((error) => showError(error.message));
```

`host.connection` contains the selected tool's connection details, or `null` while disconnected. Hidden tool pages can remain alive and receive a disconnected connection state.

`host.onConnection(callback)` delivers the current `ToolConnection` or `null` immediately. Return a cleanup function to close that connection's stream before replacement or disconnection. Async callbacks are also supported, but must resolve without a cleanup function; register cleanup synchronously for streams. The SDK does not wait for an async callback before delivering the next connection change. Unsubscribe when the UI unmounts; this also runs its cleanup. Use `connection.signal` with requests that should abort on disconnection.

Use the browser's `fetch` and `EventSource` APIs with relative `/api/...` URLs. Set `redirect: "error"` and `cache: "no-store"` on fetches. Use `connection.signal` to abort requests when the connection ends. Protocol compatibility belongs to the tool and its clients; the host does not expose a protocol version. `connection.processIdentity` is an opaque token that changes when the Android process restarts. Raw discovery metadata stays internal.

```ts
const unsubscribe = host.onConnection((connection) => {
  if (!connection) return;
  const events = new EventSource("/api/events");
  events.addEventListener("tick", showTick);
  return () => events.close();
});
```

Unloading the page closes its event streams. A loaded page's EventSource retries a closed transport, so replacing a stream or removing its UI still requires cleanup. This is separate from the host's process isolation.

The [Example tool](../../examples/tool/README.md) demonstrates this lifecycle using fake data, ordinary HTTP requests, and an event stream.

The embedded page and its API requests share the `snapo://tool` origin. Frontend files keep their bundle paths, while `/api/...` routes go to Android with `/api` removed. There is no added `/assets` prefix or endpoint to obtain from the SDK. A development override proxies local frontend files under the same origin; API requests still go to Android. Vite HMR connects directly to the local server; set its HMR host and client port explicitly.

## Browser storage

The embedded page uses a stable `snapo://tool` origin. Its persistent browser data is scoped to the device, Android user, package name, and tool ID. Snap-O reuses that storage after app updates and reinstalls with the same identifiers. Another installation can therefore read data left by the previous installation.

Treat `localStorage` and other browser storage as untrusted preference storage. Store only disposable UI settings. Do not store credentials, access tokens, captured traffic, personal data, or other sensitive information. Windows for the same provider share this storage.

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
  cannot close a newer picker. Colors use hexadecimal RGBA strings. While an
  update is in flight, `setValue` keeps only the latest pending color. Its promise
  resolves when pending updates finish.
- `copyText(text)` writes to the system clipboard.
- `saveFile({ name, data })` presents a save dialog for a `Blob` and returns whether
  the file was saved.

Use ordinary HTTP or HTTPS anchors for external links. App launch and tool
selection belong to the native host, not this API.

## Package development

From `tool-sdk/host/`, run `npm ci`, `npm run build`, `npm test`, and `npm run typecheck`. The Gradle plugin build compiles and bundles the SDK automatically. Its embedded archive contains ES modules and TypeScript declarations under `dist/`; tests and TypeScript implementation sources are excluded.

The package is private and is not published to npm. The Tool Packager Gradle plugin supplies it as a fixed local dependency at `file:.gradle/tool-host` while preserving the `@snap-o/tool-host` import. The Gradle plugin version pins the bundled SDK. Generated `hostApiVersion` metadata separately identifies the native API; a distribution change does not change the host bridge contract. See [authoring package validation](../../release/authoring.md) when developing SDK changes.
