#!/bin/bash
# install-m8emu-pi4.sh
#
# One-command installer for m8emu v0.3.0 on a Raspberry Pi 4 with a 5" DSI screen.
#
# Run on your x86_64 PC. It:
#   1. Verifies dependencies and firmware (SHA-256 checked)
#   2. Cross-compiles m8emu for aarch64 (~5-10 minutes)
#   3. Deploys the build to the Pi over SSH
#   4. Configures the Pi: runtime deps, DSI overlay, CPU governor, launcher, README
#
# Usage:
#   ./install-m8emu-pi4.sh user@pi-ip
#   ./install-m8emu-pi4.sh drclab@192.168.1.23 --firmware /path/M8_V6_5_2C_HEADLESS.hex
#
# Flags:
#   --firmware PATH      Firmware file (default: $HOME/M8_V6_5_2C_HEADLESS.hex)
#   --dsi-overlay NAME   DSI overlay (default: vc4-kms-dsi-ili9881-5inch)
#   --skip-build         Reuse ~/m8emu-cross/build/linux-arm64
#   --skip-pi-config     Deploy binaries only, don't touch config.txt or governor
#   -h, --help           Show this help
#
set -euo pipefail

# ---------------- Defaults ----------------
TARGET=""
FIRMWARE="$HOME/M8_V6_5_2C_HEADLESS.hex"
DSI_OVERLAY="vc4-kms-dsi-ili9881-5inch"
SKIP_BUILD=0
SKIP_PI_CONFIG=0

WORK_DIR="$HOME/m8emu-cross"
BUILD_DIR="$WORK_DIR/build/linux-arm64"
REMOTE_DIR="\$HOME/m8emu-pi4"
EXPECTED_HASH="434dd3d2e06765b4c3c523f21142bc57cd0811b6a7dc6a7b9596876fcb744f5c"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------- Parse arguments ----------------
while [ $# -gt 0 ]; do
    case "$1" in
        --firmware)       FIRMWARE="$2"; shift 2 ;;
        --dsi-overlay)    DSI_OVERLAY="$2"; shift 2 ;;
        --skip-build)     SKIP_BUILD=1; shift ;;
        --skip-pi-config) SKIP_PI_CONFIG=1; shift ;;
        -h|--help)        sed -n '2,25p' "$0"; exit 0 ;;
        -*)               echo "Unknown flag: $1" >&2; exit 1 ;;
        *)                TARGET="$1"; shift ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "Usage: $0 user@host [--firmware PATH] [--dsi-overlay NAME] [--skip-build] [--skip-pi-config]"
    exit 1
fi

# ---------------- Step 0: Preflight ----------------
log "Preflight checks"

# Architecture
[ "$(uname -m)" = "x86_64" ] || die "Run this on your x86_64 PC, not on the Pi."

# Cross-compiler
MISSING=()
for pkg in gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu qemu-user curl dpkg-dev; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    log "Installing cross-compiler: ${MISSING[*]}"
    sudo apt update
    sudo apt install -y "${MISSING[@]}"
fi

# Firmware
log "Checking firmware: $FIRMWARE"
[ -f "$FIRMWARE" ] || die "Firmware not found: $FIRMWARE
Download:
  wget -O $FIRMWARE https://raw.githubusercontent.com/Dirtywave/M8HeadlessFirmware/main/Releases/M8_V6_5_2C_HEADLESS.hex"

HASH=$(sha256sum "$FIRMWARE" | awk '{print $1}')
[ "$HASH" = "$EXPECTED_HASH" ] || die "Firmware hash mismatch.
  expected: $EXPECTED_HASH
  got:      $HASH"

# SSH
log "Checking SSH to $TARGET"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" 'true' 2>/dev/null \
    || die "Cannot SSH to $TARGET without a password.
Set up key authentication:  ssh-copy-id $TARGET"

# ---------------- Step 1: Cross-compile ----------------
if [ "$SKIP_BUILD" = "0" ]; then
    log "Cloning m8emu v0.3.0"
    rm -rf "$WORK_DIR"
    git clone --recurse-submodules \
        https://github.com/karimkfoure/m8emu.git "$WORK_DIR"
    cd "$WORK_DIR"
    git checkout v0.3.0

    log "Cross-compiling for linux-arm64 (this will take 5-10 minutes)"
    export M8_FIRMWARE="$FIRMWARE"
    ./scripts/build.sh linux-arm64 2>&1 | tee "$HOME/m8-cross-build.log"
else
    log "Skipping build (--skip-build)"
fi

log "Verifying build artifacts"
for f in m8emu \
         aot/libm8aot.so \
         aot/libm8native-boot.so \
         aot/libm8native-static.so \
         aot/libm8native-regions.so; do
    [ -f "$BUILD_DIR/$f" ] || die "Missing artifact: $BUILD_DIR/$f"
done
ls -lh "$BUILD_DIR/m8emu" "$BUILD_DIR"/aot/*.so

# ---------------- Step 2: Pi configuration ----------------
if [ "$SKIP_PI_CONFIG" = "0" ]; then
    log "Configuring $TARGET (runtime deps, DSI overlay, governor)"

    ssh "$TARGET" "bash -s -- '$DSI_OVERLAY'" << 'REMOTE_CONFIG'
set -e
DSI_OVERLAY="$1"
CFG=/boot/firmware/config.txt

# Runtime libraries
sudo apt update -qq
sudo apt install -y --no-install-recommends \
    libasound2 libdrm2 libgbm1 libegl1 libgles2 \
    libudev1 libdbus-1-3 libpulse0 libsndio7.0 evtest 2>/dev/null || true

# DSI overlay (idempotent)
if ! grep -q '^dtoverlay=vc4-kms-dsi-' "$CFG"; then
    echo "dtoverlay=$DSI_OVERLAY" | sudo tee -a "$CFG" >/dev/null
    echo "Added dtoverlay=$DSI_OVERLAY"
fi
grep -q '^display_auto_detect=1' "$CFG" || \
    echo 'display_auto_detect=1' | sudo tee -a "$CFG" >/dev/null
grep -q '^dtoverlay=vc4-kms-v3d' "$CFG" || \
    echo 'dtoverlay=vc4-kms-v3d' | sudo tee -a "$CFG" >/dev/null

# CPU governor: immediate
echo performance | \
    sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true

# CPU governor: persist across reboots
sudo tee /etc/systemd/system/cpu-performance.service >/dev/null << 'UNIT'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now cpu-performance.service >/dev/null 2>&1 || true

echo "Pi configured."
REMOTE_CONFIG
fi

# ---------------- Step 3: Deploy build ----------------
log "Deploying build to $TARGET:$REMOTE_DIR"
ssh "$TARGET" "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
scp -q -r "$BUILD_DIR"/* "$TARGET:$REMOTE_DIR/"

# ---------------- Step 4: Launcher + README ----------------
log "Installing launcher and README on the Pi"
ssh "$TARGET" 'bash -s' << 'REMOTE_FILES'
set -e
cd ~/m8emu-pi4

# --- Launcher ---
cat > m8.sh << 'LAUNCHER'
#!/bin/bash
# m8emu launcher for Raspberry Pi 4 + 5" DSI display
# Usage: sudo ./m8.sh [m8emu flags]
set -euo pipefail
cd "$(dirname "$0")"

# Elevate if needed (DRM master + systemctl)
if [ "$(id -u)" -ne 0 ]; then exec sudo -E "$0" "$@"; fi

WAS_GRAPHICAL=0
systemctl is-active --quiet graphical.target && WAS_GRAPHICAL=1

cleanup() {
    if [ "$WAS_GRAPHICAL" = "1" ]; then
        echo "Restoring graphical desktop..."
        systemctl isolate graphical.target || true
    fi
}
trap cleanup EXIT INT TERM

# Release DRM master from labwc/wayfire
if [ "$WAS_GRAPHICAL" = "1" ]; then
    echo "Stopping desktop to free the DSI display for m8emu..."
    systemctl isolate multi-user.target
    sleep 1
fi

export LD_LIBRARY_PATH="$PWD/lib"
export M8RT_STALL_POLICY=deterministic
export SDL_VIDEODRIVER=kmsdrm
export SDL_RENDER_DRIVER=opengles2
export SDL_KMSDRM_DEVICE_INDEX=1

# Defaults: fullscreen demo autoplay with generous audio buffers
if [ $# -eq 0 ]; then
    set -- --fullscreen --demo simple --play --audio-frames 1024 --queue-ms 60
fi

./m8emu "$@"
LAUNCHER
chmod +x m8.sh

# --- README ---
cat > README.md << 'DOC'
# M8 Headless on Raspberry Pi 4 + 5" DSI Screen

Native ARM64 build of m8emu v0.3.0 running fullscreen on a Raspberry Pi 4
with a 5-inch DSI panel and the 3.5 mm headphone jack.

## Run

```bash
sudo ~/m8emu-pi4/m8.sh                     # demo, autoplay, fullscreen
sudo ~/m8emu-pi4/m8.sh --card /path.img    # your card
sudo ~/m8emu-pi4/m8.sh --demo simple       # demo, no autoplay
