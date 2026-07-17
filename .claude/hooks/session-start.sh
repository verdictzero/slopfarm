#!/bin/bash
# SessionStart hook: install the Godot 4.7 + Android SDK toolchain for this repo.
#
# Why a hook and not just a committed binary: Claude Code on the web runs each
# session in a fresh, ephemeral container, so the only things that persist are the
# git repo and whatever a startup hook reinstalls. The container filesystem state
# is cached after this hook finishes, so an idempotent install to a stable path
# (/opt) is effectively persistent — the first session on an environment pays the
# download cost, later ones find everything already present and skip in seconds.
#
# Godot itself is only distributed from github.com, which this environment's egress
# policy blocks (403 at the proxy). Docker Hub is reachable, so the Godot binary and
# export templates are pulled out of the barichello/godot-ci image's layers by
# pull_godot.py. The Android SDK comes straight from dl.google.com, which is allowed.
set -euo pipefail

# Web sessions only. Locally you presumably already have your own toolchain.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG=/tmp/slopfarm-toolchain.log
: > "$LOG"

# ---- versions (match the project's Godot 4.7 Android build template) --------
GODOT_DIR=/opt/godot
ANDROID_HOME=/opt/android-sdk
NDK_VERSION=29.0.14206865
BUILD_TOOLS=36.1.0
PLATFORM=android-36
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

log()  { echo "[toolchain] $*"; }
JAVA_HOME_DETECTED="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"

# ---- Godot (binary + export templates), pulled from the docker image --------
if [ ! -x "$GODOT_DIR/godot" ] || [ ! -f /root/.local/share/godot/export_templates/4.7.stable/android_release.apk ]; then
  log "installing Godot 4.7 (binary + export templates) from container registry..."
  python3 "$PROJECT_DIR/.claude/hooks/pull_godot.py" >>"$LOG" 2>&1 \
    || { log "Godot install FAILED — see $LOG"; }
else
  log "Godot already installed"
fi
ln -sf "$GODOT_DIR/godot" /usr/local/bin/godot 2>/dev/null || true

# ---- Android SDK from dl.google.com -----------------------------------------
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if [ ! -x "$SDKMANAGER" ]; then
  log "installing Android command-line tools..."
  mkdir -p "$ANDROID_HOME/cmdline-tools" /tmp/clt
  curl -sSL --retry 3 --max-time 180 -o /tmp/clt/clt.zip "$CMDLINE_TOOLS_URL" >>"$LOG" 2>&1
  rm -rf /tmp/clt/extract && mkdir -p /tmp/clt/extract
  unzip -q -o /tmp/clt/clt.zip -d /tmp/clt/extract
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv /tmp/clt/extract/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"
fi

if [ ! -e "$ANDROID_HOME/ndk/$NDK_VERSION/ndk-build" ]; then
  log "installing Android SDK packages (platform-tools, $PLATFORM, build-tools $BUILD_TOOLS, ndk $NDK_VERSION)..."
  yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >>"$LOG" 2>&1 || true
  yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" \
      "platform-tools" "platforms;$PLATFORM" "build-tools;$BUILD_TOOLS" "ndk;$NDK_VERSION" \
      >>"$LOG" 2>&1 || { log "Android SDK package install FAILED — see $LOG"; }
else
  log "Android SDK already installed"
fi
ln -sf "$ANDROID_HOME/platform-tools/adb" /usr/local/bin/adb 2>/dev/null || true

# ---- Godot editor config for headless Android export ------------------------
if [ ! -f /root/debug.keystore ]; then
  keytool -keyalg RSA -genkeypair -alias androiddebugkey -keypass android \
    -keystore /root/debug.keystore -storepass android \
    -dname "CN=Android Debug,O=Android,C=US" -validity 10000 -deststoretype pkcs12 >>"$LOG" 2>&1 || true
fi
mkdir -p /root/.config/godot
cat > /root/.config/godot/editor_settings-4.tres <<EOF
[gd_resource type="EditorSettings" format=3]

[resource]
export/android/android_sdk_path = "$ANDROID_HOME"
export/android/java_sdk_path = "$JAVA_HOME_DETECTED"
export/android/debug_keystore = "/root/debug.keystore"
export/android/debug_keystore_user = "androiddebugkey"
export/android/debug_keystore_pass = "android"
export/android/force_system_user = false
export/android/shutdown_adb_on_exit = true
EOF

# ---- persist environment for the session ------------------------------------
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export GODOT=\"$GODOT_DIR/godot\""
    echo "export GODOT4_BIN=\"$GODOT_DIR/godot\""
    echo "export ANDROID_HOME=\"$ANDROID_HOME\""
    echo "export ANDROID_SDK_ROOT=\"$ANDROID_HOME\""
    echo "export ANDROID_NDK_ROOT=\"$ANDROID_HOME/ndk/$NDK_VERSION\""
    echo "export JAVA_HOME=\"$JAVA_HOME_DETECTED\""
    echo "export PATH=\"$GODOT_DIR:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:\$PATH\""
  } >> "$CLAUDE_ENV_FILE"
fi

log "toolchain ready: godot $("$GODOT_DIR/godot" --headless --version 2>/dev/null | tail -1), android-sdk at $ANDROID_HOME"
