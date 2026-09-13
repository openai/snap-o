# Network CLI

The standalone Python executable lives in
[`skills/snap-o-network-inspector/scripts/snapo-network`](../../../skills/snap-o-network-inspector/scripts/snapo-network).
Keeping it inside the skill makes individual skill installations self-contained.
It requires only Python 3 and Android Platform Tools; no reader JAR or Python packages.

From the repository root:

```bash
./skills/snap-o-network-inspector/scripts/snapo-network --help
python3 -m unittest discover -s tools/network/cli/tests -p 'test_*.py'
```

See [command-line inspection](../../../docs/cli.md) for installation and usage.
