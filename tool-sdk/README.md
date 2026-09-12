# Tool plugin SDK

These components let Android apps bundle tool plugins for Snap-O:

- [`host/`](host/README.md): `@snap-o/tool-host`, the frontend API for connection state, toolbar controls, and native actions.
- [`runtime/`](runtime/README.md): `tool-runtime`, the shared Android HTTP and streaming server.
- [`gradle-plugin/`](gradle-plugin/README.md): builds frontends and packages tool plugin metadata and assets.

Start with [Build a tool plugin](../docs/plugins.md) and the [Tool plugin API reference](../docs/plugin-api.md).

Concrete tool plugins live in [`tools/`](../tools/README.md). The independent [`examples/tool/`](../examples/tool/README.md) project demonstrates authoring with locally staged package artifacts.

Run the Android workspace with `./gradlew` from the repository root. See [authoring validation](../release/authoring.md) for local package staging and consumer tests.
