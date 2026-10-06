# Network CLI

The standalone Python executable lives in
[`skills/snap-o-network-inspector/scripts/snapo-network`](../../../skills/snap-o-network-inspector/scripts/snapo-network).
Keeping it inside the skill makes individual skill installations self-contained.
It requires only Python 3 and Android Platform Tools; no reader JAR or Python packages.

The `ADB and CLI support` section near the end contains the duplicated transport,
discovery, and command helpers. Keep fixes to that section in sync between both scripts.

From the repository root:

```bash
./skills/snap-o-network-inspector/scripts/snapo-network --help
python3 -m unittest discover -s tools/network/cli/tests -p 'test_*.py'
```

See [Network CLI setup](../../../docs/network-inspector.md#cli) for installation and usage.

Output and interception tests use fake responses and explicit event queues. Reload
tests advance a controlled signal instead of waiting for the polling interval.
Real socket tests cover transport framing and cleanup separately.
