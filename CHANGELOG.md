# Changelog

## 0.1.0

The first release.

- **Main window.** Shows the bridge address and Connect. When connected, it shows the
  bridge's and Tracy viewer's status and live tracks, with an error card when the bridge
  can't be reached.
- **Place setup.** Inserts or updates the Tracy module, turns on Allow HTTP Requests, and
  points the place at the connected bridge. It asks first, and each change can be undone.
- **Capture.** During a playtest, one click takes a MicroProfiler capture. Needs LibMP.
- **Settings.** The Global tab holds the bridge address, auto-connect, setup checks and
  captures. The Place tab holds the Tracy module's streaming, MicroProfiler mode and
  built-in plots.
- **Help.** The steps from download to a live trace.
- **Bundled module.** Includes Tracy-Luau's module 0.5.0.
