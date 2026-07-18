#!/usr/bin/env bash
# Build the SLOPFARM web player: the Godot game exported straight into the Game Boy
# shell (web/gb_shell.html), producing a self-contained static site under build/web/.
#
# The Godot canvas mounts inside the shell's #gb-screen, and the on-screen pad drives
# the game through window.GameBoyUI (read game-side in scripts/gb_bridge.gd). Because
# the Web preset exports with threads OFF, the result runs on a plain static host with
# NO cross-origin-isolation (COOP/COEP) headers required.
#
# Requires the Godot 4.7 WEB export templates (Editor > Manage Export Templates, or drop
# the matching .tpz). They are NOT bundled in this repo and cannot be fetched from the CI
# sandbox — GitHub release egress is blocked there, the same reason the APK upload in
# DEPLOY.md runs off-sandbox — so run this on a machine or CI where the templates are present.
#
#   tools/export_web.sh                 # release build -> build/web/index.html
#   DEBUG=1 tools/export_web.sh         # debug build (verbose engine errors)
#   GODOT=/path/to/godot tools/export_web.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${1:-build/web/index.html}"
MODE="--export-release"
[ "${DEBUG:-0}" = "1" ] && MODE="--export-debug"

cd "$ROOT"
mkdir -p "$(dirname "$OUT")"

echo "Exporting Web preset ($MODE) -> $OUT"
"$GODOT" --headless --path . "$MODE" "Web" "$OUT"

echo
echo "Done. Serve build/web over HTTP and open it:"
echo "  python3 -m http.server -d build/web 8080   # then http://localhost:8080/"
echo
echo "To publish, upload the whole build/web/ directory to a static host (see DEPLOY.md)."
