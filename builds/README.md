# Builds

Prebuilt Android APKs of SlopFarm, committed here so they can be downloaded straight from GitHub
(no upload-size limit).

- **`slopfarm.apk`** — latest signed **debug** build (arm64-v8a, Android 7+). Debug-signed for
  sideloading/testing, not the Play Store. On a device, enable "install unknown apps" for your
  browser/file manager, then open the file.

Rebuild it from the repo root with:

    godot --headless --path . --export-debug "Android" builds/slopfarm.apk
