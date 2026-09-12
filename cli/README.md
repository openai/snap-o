# Snap-O CLI

The Python client supports Network and Tweaks on macOS and Linux. It requires Python 3 and Android Platform Tools.

From the repository root:

```sh
./cli/snapo --help
python3 -m unittest discover -s cli/tests -p 'test_*.py'
```

The CLI uses its own ADB transport. It shares the Android [`tool-reader/`](../tool-reader/README.md) helper with the macOS app.
For standalone distribution, place `snapo-tool-reader.jar` beside `snapo`. The macOS app bundles both files automatically.

See the [CLI guide](../docs/cli.md) for installation and usage.
