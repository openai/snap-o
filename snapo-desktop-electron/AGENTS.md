# Electron Project Instructions

## npm Registry

- Use the repository registry from `.npmrc`: `https://openai.firewall.socket.dev/npm/`.
- Environment-level `NPM_CONFIG_REGISTRY` values may override `.npmrc`. Pass the repository registry explicitly when adding dependencies or regenerating `package-lock.json`.
- Before committing lockfile changes, verify that `package-lock.json` contains no URLs under `socket-firewall-registry.gateway.*`.
