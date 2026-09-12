# Tool frontend bundle

The Tool Gradle Plugin validates frontend ZIPs before including them in Android assets. The Mac validates the same contract when loading a tool frontend.

- The ZIP is at most 16 MiB, with at most 16 MiB of expanded file content.
- There are at most 1024 entries, including directories.
- Paths are unique after removing a directory's trailing slash. They contain at most 1024 UTF-16 code units, with no backslashes, control characters, empty segments, `.` segments, or `..` segments.
- Symbolic links are unsupported. Files use stored or deflated ZIP compression, with matching sizes and CRC checksums.
- A root `index.html` file is required. It contains valid UTF-8 and is at most 4 MiB.

These limits apply to packaged frontends. A development-server frontend follows the Mac's development-server policy.
