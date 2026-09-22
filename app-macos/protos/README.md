# Emulator preview messages

This schema contains the fields Snap-O uses from the Android Emulator screenshot API.
Keep field numbers and enum values compatible with the upstream schema linked in the file.
It does not change the Network or Tweaks protocols.

Generate Swift types with protoc and protoc-gen-swift 1.38.1:

```sh
protoc --proto_path=app-macos/protos \
  --swift_out=app-macos/Snap-O/Device/Emulators \
  app-macos/protos/emulator_preview.proto
```

Keep the generated file's `swiftformat:disable all` directive after regeneration.
Add `swiftlint:enable all` at the end to close the generator's lint suppression.
