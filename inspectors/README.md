# Inspectors

This directory contains the Network and Tweaks frontends bundled with Snap-O.
Each owns its UI, device protocol, styles, tests, and build. They share
`@snap-o/host` for connection state, toolbar controls, and native helpers. The
package layout and host interface are internal to Snap-O.

## Development

Use Node.js 22.12 or later. From this directory:

```sh
npm ci --registry=https://openai.firewall.socket.dev/npm/
npm run dev:network
npm run dev:tweaks
```

The Network development server also serves `/preview.html` with synthetic request
examples. Connected inspectors require the macOS host. Debug builds accept a
loopback development URL in `SNAPO_INSPECTOR_DEV_URL_NETWORK` or
`SNAPO_INSPECTOR_DEV_URL_TWEAKS`.

```sh
npm run format:check
npm run lint
npm run typecheck
npm test
npm run build
```

Each package can run its own tests, typecheck, and build with `npm run <script> -w
<package-name>`. Import checks resolve TypeScript imports, including relative paths
and aliases. Inspectors cannot import one another or host SDK internals.
