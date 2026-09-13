# Tweaks CLI

The standalone Python executable lives in
[`skills/snap-o-tweaks/scripts/snapo-tweaks`](../../../skills/snap-o-tweaks/scripts/snapo-tweaks).
Keeping it inside the skill makes individual skill installations self-contained.
It requires only Python 3 and Android Platform Tools; no reader JAR or Python packages.

The `ADB and CLI support` section near the end contains the duplicated transport,
discovery, and command helpers. Keep fixes to that section in sync between both scripts.

From the repository root:

```bash
./skills/snap-o-tweaks/scripts/snapo-tweaks --help
python3 -m unittest discover -s tools/tweaks/cli/tests -p 'test_*.py'
```

See [command-line inspection](../../../docs/cli.md) for installation and usage.
