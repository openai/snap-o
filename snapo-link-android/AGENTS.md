This is the code repository for the Snap-O macOS app and optional Android libraries to help provide data to Snap-O.

**Directory Structure**
* `snapo-app-mac/` - The macOS app, written in SwiftUI, which displays captured content from the Android device.
* `snapo-link-android/` - The collection of Android libraries that can be added to an Android app to provide network request information to be inspected.

## Security Model Notes
- Snap-O Link on Android uses an app-local abstract Unix domain socket and relies on Android app sandbox + SELinux process isolation.
- Treat cross-app access to that socket as a non-issue under this project's validated assumptions.
- Do not file a security finding based only on the plaintext Snap-O greeting/handshake unless Android platform security assumptions change or a reproducible bypass is shown.
