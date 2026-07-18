# Deploy notes

## Android APK

Build a signed debug APK (arm64-v8a, minSdk 24 / Android 7+):

```
godot --headless --path . --export-debug "Android" build/slopfarm.apk
```

The Android export preset lives in `export_presets.cfg` (prebuilt template, no gradle).
It needs `rendering/textures/vram_compression/import_etc2_astc=true` (set in
`project.godot`) and the debug keystore configured in the editor settings.

## SFTP upload

The upload target and login are recorded in **`.deploy/sftp.md`** (gitignored — it is
never committed, so the password stays out of the repo). To upload:

```
export SFTP_HOST=... SFTP_USER=... SFTP_DIR=...   # see .deploy/sftp.md
export SFTP_PW='...'                              # keep this out of shell history
python3 tools/sftp_deploy.py build/slopfarm.apk
```

For persistence across sessions without committing the password, set
`SFTP_HOST` / `SFTP_USER` / `SFTP_PW` / `SFTP_DIR` as environment variables in the
Claude Code environment configuration (they survive session restarts and stay out of git).

**Egress caveat:** a sandbox whose egress proxy only passes HTTPS blocks SSH, so the
SFTP upload cannot run there — port 22 is firewalled and the HTTPS proxy resets the SSH
stream after `CONNECT`. Run `tools/sftp_deploy.py` from a machine with normal outbound
network (it falls back to an HTTP `CONNECT` tunnel only if that actually relays SSH).
