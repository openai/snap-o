# Plugin SDK

These components let Android apps bundle plugins for Snap-O:

- [`host/`](host/README.md): `@snap-o/plugin-host`, the frontend API for connection state, toolbar controls, and native actions.
- [`runtime/`](runtime/README.md): `plugin-runtime`, the shared Android HTTP and streaming server.
- [`gradle-plugin/`](gradle-plugin/README.md): builds frontends and packages plugin metadata and assets.

Start with [Build a plugin](../docs/plugins.md) and the [Plugin API reference](../docs/plugin-api.md).

Concrete plugins live in [`plugins/`](../plugins/README.md). The independent [`examples/plugin/`](../examples/plugin/README.md) project demonstrates authoring with locally staged package artifacts.

Run the Android workspace with `./gradlew` from the repository root. See [authoring validation](../release/authoring.md) for local package staging and consumer tests.
