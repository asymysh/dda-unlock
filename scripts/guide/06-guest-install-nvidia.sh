#!/usr/bin/env bash
#
# Install the proprietary NVIDIA driver inside a Fedora guest VM that has
# a GPU passed through via Hyper-V DDA.
#
# Detects the GPU architecture and picks the right RPM Fusion akmod branch.
#
# Usage:
#   chmod +x 06-guest-install-nvidia.sh
#   ./06-guest-install-nvidia.sh
#
# After it finishes, reboot the VM and run `nvidia-smi` to verify.

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "Run as a normal user (the script uses sudo where needed)."
    exit 1
fi

C_BLUE='\033[1;34m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_OFF='\033[0m'
hdr()  { echo -e "\n${C_BLUE}===== $* =====${C_OFF}"; }
ok()   { echo -e "${C_GREEN}[OK]${C_OFF} $*"; }
warn() { echo -e "${C_YELLOW}[!!]${C_OFF} $*"; }
err()  { echo -e "${C_RED}[XX]${C_OFF} $*"; }

# ---------------------------------------------------------------------------
# 1. Confirm a passed-through NVIDIA GPU is visible
# ---------------------------------------------------------------------------
hdr "Detecting NVIDIA GPU"
gpu_line=$(lspci -nn | grep -iE 'nvidia.*\[10de:' | grep -iE 'vga|3d|display' | head -1)
if [[ -z "$gpu_line" ]]; then
    err "No NVIDIA Display-class device found via lspci."
    err "Is DDA actually working? Run lspci -nn from this guest."
    exit 1
fi
echo "  $gpu_line"
device_id=$(echo "$gpu_line" | grep -oE '10de:[0-9a-f]+' | head -1 | cut -d: -f2)
echo "  Device ID: 10de:$device_id"

# ---------------------------------------------------------------------------
# 2. Map device ID to architecture
# ---------------------------------------------------------------------------
# References:
#   https://nouveau.freedesktop.org/CodeNames.html
#   https://en.wikipedia.org/wiki/List_of_Nvidia_graphics_processing_units
case "$device_id" in
    # Pascal (GP10x) — GTX 1050/1060/1070/1080/Ti, Titan Xp
    1b00|1b02|1b06|1b30|1b38|1b80|1b81|1b82|1b83|1b84|1b87|\
    1bb0|1bb1|1bb3|1bb4|1bb5|1bb6|1bb7|1bb8|1bb9|1bbb|\
    1c02|1c03|1c04|1c06|1c07|1c09|1c20|1c21|1c22|1c23|1c30|1c31|1c35|1c60|1c61|1c62|1c81|1c82|1c83|1c8c|1c8d|1c8f|1c90|1c92|\
    1d01|1d10|1d12|1d13|1d52|1d56)
        ARCH="Pascal"
        BRANCH="580xx"
        ;;
    # Turing+ (RTX 20xx, GTX 16xx, RTX 30/40/50 series): mainline
    1e0[2-7]|1e2[0-9a-f]|1e3[0-9a-f]|1e8[0-9a-f]|1e9[0-9a-f]|1eb[0-9a-f]|1ec[0-9a-f]|1ed[0-9a-f]|1ef[0-9a-f]|\
    1f0[0-9a-f]|1f1[0-9a-f]|1f4[0-9a-f]|1f8[0-9a-f]|1f9[0-9a-f]|\
    2[0-9a-f][0-9a-f][0-9a-f])
        ARCH="Turing or newer"
        BRANCH="mainline"
        ;;
    # Maxwell (GTX 7xx late / 9xx)
    13[0-9a-f][0-9a-f]|17[0-9a-f][0-9a-f])
        ARCH="Maxwell"
        BRANCH="470xx"
        ;;
    # Kepler (GTX 6xx / 7xx early)
    10[0-9a-f][0-9a-f]|11[0-9a-f][0-9a-f])
        ARCH="Kepler"
        BRANCH="470xx"
        ;;
    *)
        ARCH="unknown"
        BRANCH="mainline"
        warn "Could not map device ID $device_id to architecture; defaulting to mainline branch."
        warn "If install fails with 'does not include the required GPU', see docs/troubleshooting.md §2"
        ;;
esac

ok "Architecture detected: $ARCH"
ok "RPM Fusion branch:     $BRANCH"

case "$BRANCH" in
    mainline) PKGS=(akmod-nvidia xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-cuda-libs nvidia-settings) ;;
    580xx)    PKGS=(akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda xorg-x11-drv-nvidia-580xx-cuda-libs nvidia-settings-580xx) ;;
    470xx)    PKGS=(akmod-nvidia-470xx xorg-x11-drv-nvidia-470xx-cuda xorg-x11-drv-nvidia-470xx-cuda-libs nvidia-settings-470xx) ;;
esac

# ---------------------------------------------------------------------------
# 3. Add RPM Fusion repos
# ---------------------------------------------------------------------------
hdr "Adding RPM Fusion repos"
if ! dnf repolist 2>/dev/null | grep -qi rpmfusion-nonfree; then
    sudo dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
    ok "RPM Fusion installed"
else
    ok "Already present"
fi

# ---------------------------------------------------------------------------
# 4. Install driver packages
# ---------------------------------------------------------------------------
hdr "Installing NVIDIA $BRANCH driver"
sudo dnf install -y --skip-unavailable "${PKGS[@]}" libva-utils vdpauinfo

# ---------------------------------------------------------------------------
# 5. Build kmod
# ---------------------------------------------------------------------------
hdr "Building kernel module (3-10 min)"
sudo akmods --force --rebuild

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
hdr "Verification"

if ls "/lib/modules/$(uname -r)/extra/nvidia"*/ &>/dev/null; then
    ok "kmod files installed"
else
    err "kmod files NOT in /lib/modules/$(uname -r)/extra/"
    err "Check /var/cache/akmods/nvidia-*/ for build logs"
    exit 1
fi

ver=$(modinfo -F version nvidia 2>/dev/null || true)
if [[ -n "$ver" ]]; then
    ok "Module reports version: $ver"
else
    warn "modinfo cannot read nvidia module (will load fresh after reboot)"
fi

# ---------------------------------------------------------------------------
# 7. Reboot
# ---------------------------------------------------------------------------
hdr "Done. Reboot required."
echo "Run:    sudo reboot"
echo "After reboot, verify with:"
echo "        nvidia-smi"
echo "        lspci -nnk -d 10de:$device_id | tail -3"
