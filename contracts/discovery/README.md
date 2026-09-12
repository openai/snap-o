# Plugin discovery

Tool identity comes from installed Android manifest resources. Running instances come from abstract Unix sockets. An HTTP response proves connection readiness; metadata alone does not.

## Naming compatibility

Apps bundle plugins that provide tools. A plugin’s optional frontend appears in the Tool pane when its tool is selected. Discovery version 1 retains the `snapo.inspector.<id>` manifest key, `<inspector>` XML element, `inspectors` JSON field, and `pluginId` asset-request field. Asset paths and the `snapo-inspector` browser origin also remain unchanged. These names identify the discovery format, not tool-specific protocols.

## Socket and manifest names

Use `snapo_<id>_<pid>`, where `id` matches `[a-z][a-z0-9.-]{0,99}` and `pid` is a positive decimal process ID. A plugin library contributes one application-level manifest entry:

```xml
<meta-data
    android:name="snapo.inspector.network"
    android:resource="@xml/snapo_network_inspector" />
```

The key is derived from the socket ID. It does not depend on the library's Java package. Independent plugin libraries contribute separate entries through manifest merging.

## Descriptor version 1

```xml
<inspector
    version="1"
    id="network"
    name="Network"
    icon="@drawable/snapo_network_inspector_icon" />
```

The descriptor ID must match the manifest key and socket ID. `name` is a nonempty string or string resource, limited to 200 characters. `icon` references a drawable or mipmap resource and is required by the authoring plugin. Tool protocol versions are not part of discovery. Tools define their own HTTP compatibility rules. `version` identifies this descriptor schema, independently of the wire protocol.

App labels and icons come from Android package information, not the tool descriptor. PIDs, process names, Android users, and process lifetimes come from process metadata. Do not put runtime state, credentials, or captured traffic in manifest resources.

## Optional frontend

A descriptor can include `frontendAssets="snapo/inspectors/tweaks/frontend.zip"` and `hostApiVersion="2"`. These fields appear together. `frontendAssets` is a relative APK asset path to a ZIP, not a URL or resource name. Its path must not contain empty segments, `.` or `..`, backslashes, or control characters. The ZIP contains `index.html` at its root and any relative scripts, styles, and other assets.

Reader output represents these fields as `frontend: {"assetPath": "snapo/inspectors/tweaks/frontend.zip", "hostApiVersion": 2}`. The host API version identifies the JavaScript bridge contract, independently of the Android wire protocol. The authoring plugin generates this host API version; it is not an author setting. Hosts reject unsupported host API versions before executing the frontend. Clients that do not display frontends can ignore this optional object. Network and Tweaks both package frontends through the Gradle packaging plugin. The Mac host requires this metadata unless a development server is selected; it has no bundled frontend fallback.

Manifest entries point to compiled XML resource IDs. Loading does not depend on the XML resource's source filename surviving resource optimization. APK assets use literal paths and must retain the descriptor's path.

Clients that do not display a frontend can omit asset loading. The desktop reads the referenced ZIP using a separate asset reader. It verifies the process identity, Android user, package, package revision, tool ID, asset path, and host API version against the selected metadata. Both compressed and expanded contents are limited to 16 MiB. Archives can contain at most 1,024 entries; `index.html` must be UTF-8 and at most 4 MiB. Absolute paths, traversal, duplicates, symlinks, and invalid checksums are rejected.

## Reading metadata

Use `PackageManager.getApplicationInfo` with `GET_META_DATA`, `ApplicationInfo.loadXmlMetaData`, and `PackageManager.getResourcesForApplication` in a separate reader process. Resolve the correct Android user and verify package ownership against the process UID. The [bundled reader](../../tool-reader/README.md) supports non-debuggable apps without invoking app code.

Cache installed metadata separately from live connections. Invalidate it when the installed package or resource configuration changes. A missing or malformed descriptor is not evidence that the socket disappeared; show the app and an unsupported-tool state. Never infer that a plugin is enabled merely because its descriptor is installed. When a new socket appears, refresh metadata for all visible tool sockets in that process and update their cached records together.

Clients can send `OPTIONS /` over a forwarded socket to check HTTP readiness without fetching app metadata. The Network and Tweaks servers return a successful empty response. They no longer serve `/.snap-o/info` or `/.snap-o/appicon`.

### Reader output

The reader emits one JSON line per process. Each record has `version: 1` and a positive `pid`. Successful records contain `app` and a nonempty `processIdentity`; clients must reject successful records without that identity. The identity combines boot identity, PID, and process start time, so clients can distinguish a replacement process that reuses a PID. Error records can omit `app` and `processIdentity`.

The CLI runs the bundled reader through ADB in batches of at most 64 socket names per device. Listing apps does not forward or connect to tool sockets. Commands validate the selected descriptor before sending tool requests.

## Protocol migration

Host bridge API 2 removes tool protocol versions from connection metadata. The Gradle plugin generates this compatibility marker. Hosts and frontends must use the same host API; older frontends are rejected before loading.

Discovery does not carry tool protocol versions. Network protocol 4 and Tweaks protocol 8 provide their own HTTP version endpoints. Their clients check those endpoints before using the tools; they do not fall back to descriptor versions. Update the clients and Android libraries together.

The optional frontend descriptor and ZIP loading remain in descriptor version 1. Command-line clients do not need to download or execute frontend assets. App identity and icons come from Android resources. Network history, SSE, interception, tweak values, and tweak actions keep their existing payload formats.
