# Deploy notes

## Web (the Game Boy shell)

The game also ships as a browser build wrapped in a Game Boy handheld shell —
`web/gb_shell.html`, used as the Godot **custom HTML shell**. The engine's canvas mounts
inside the shell's screen and the on-screen pad (D-pad, A/B/C/X/Y/Z, Start/Select, two
sticks) drives the game. It fits phones, foldables and tablets with no per-device code.

Build it (needs the Godot 4.7 **web** export templates installed — see the caveat below):

```
tools/export_web.sh                 # release -> build/web/index.html (+ .js/.wasm/.pck)
python3 -m http.server -d build/web 8080   # then open http://localhost:8080/
```

The Web preset (`export_presets.cfg` → `[preset.1]`) exports with **threads off**, so the
build runs on any plain static host — no cross-origin-isolation (COOP/COEP) headers needed.
`html/canvas_resize_policy=0` leaves the canvas to the shell's CSS (a 640×360 buffer scaled
`pixelated` to fill the 16:9 screen). Upload the whole `build/web/` directory to a static host.

Controls, pad → game:

| Pad | Game |
|---|---|
| D-pad + left stick | move |
| right stick | look |
| A | hit (swing wand / throw) |
| B | use (pick up / feed / load / sell) |
| X | jump (held) · Y | sprint (held) |
| C | drive truck · Z | respawn |

**Export-templates caveat:** the web templates are a large download from GitHub releases,
which the CI sandbox cannot reach (GitHub egress is blocked there — the same reason the SFTP
upload below runs off-sandbox). Run `tools/export_web.sh` on a machine or CI where
*Manage Export Templates* has installed the 4.7 web templates. The Android APK build, by
contrast, works in-session because its templates are already present.

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
