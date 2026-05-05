#!/usr/bin/env bash
# 03-setup.sh — post-boot setup helper for Ubuntu 26.04 on Orange Pi 5 Pro.
#
# Run this from inside the booted system after first login. Asks four
# questions and applies the answers:
#
#   1. Install KDE Plasma desktop now? (skipped if already installed)
#   2. Auto-start the UI on boot? (graphical.target vs multi-user.target)
#   3. Migrate root filesystem to NVMe? (calls armbian-install)
#   4. Put u-boot in SPI flash so the system boots without microSD?
#
# Re-runnable. Each section is independent — answer "no" to any prompt to skip
# that step.

set -euo pipefail

if [[ "$(id -u)" == "0" ]]; then
    echo "Run as a regular user; the script will sudo when it needs to." >&2
    exit 1
fi

ask() {
    # ask "Question?" default(y|n)  -> sets ANSWER to y or n
    local prompt="$1" default="${2:-n}" reply
    local hint
    if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    read -r -p "$prompt $hint " reply || true
    reply="${reply:-$default}"
    case "${reply,,}" in
        y|yes) ANSWER=y ;;
        *)     ANSWER=n ;;
    esac
}

echo "=== Orange Pi 5 Pro post-boot setup ==="
echo

# ------------------------------------------------------------------------
# 1. Install KDE Plasma
# ------------------------------------------------------------------------
if dpkg -l kubuntu-desktop 2>/dev/null | grep -q '^ii'; then
    echo "[1/4] KDE Plasma already installed — skipping."
else
    ask "[1/4] Install KDE Plasma desktop now?" n
    if [[ "$ANSWER" == "y" ]]; then
        echo ">>> Installing kubuntu-desktop + konsole (15-45 min)..."
        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            kubuntu-desktop konsole mesa-utils vulkan-tools
    fi
fi

# ------------------------------------------------------------------------
# 2. Default boot target (graphical UI vs CLI)
# ------------------------------------------------------------------------
current_target="$(systemctl get-default 2>/dev/null || echo unknown)"
echo
echo "[2/4] Current default boot target: $current_target"

if dpkg -l kubuntu-desktop 2>/dev/null | grep -q '^ii'; then
    if [[ "$current_target" == "graphical.target" ]]; then
        ask "      Auto-start the UI on boot? (currently yes)" y
    else
        ask "      Auto-start the UI on boot? (currently no)" n
    fi
    if [[ "$ANSWER" == "y" ]]; then
        sudo systemctl set-default graphical.target
        echo "      → Will boot to graphical login (SDDM) on next reboot."
    else
        sudo systemctl set-default multi-user.target
        echo "      → Will boot to text console on next reboot. Start GUI manually with 'startx'/'sudo systemctl start sddm'."
    fi
else
    echo "      → No desktop installed; skipping (system stays at text console)."
fi

# ------------------------------------------------------------------------
# 3. Migrate to NVMe
# ------------------------------------------------------------------------
echo
nvme_present="$(lsblk -dno NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/ {print $1}' | head -1)"
if [[ -z "$nvme_present" ]]; then
    echo "[3/4] No NVMe drive detected — skipping migration."
else
    echo "[3/4] NVMe detected: /dev/$nvme_present"
    ask "      Migrate root filesystem to NVMe? (uses armbian-install)" n
    if [[ "$ANSWER" == "y" ]]; then
        echo
        echo ">>> Pre-prompt for question 4 (SPI bootloader) before launching armbian-install."
        ask "[4/4] Also write u-boot to SPI flash so the board boots without an SD card?
      Choose YES for pure-NVMe operation. Choose NO to keep u-boot on SD" n
        spi_choice="$ANSWER"

        echo
        if [[ "$spi_choice" == "y" ]]; then
            echo ">>> When armbian-install opens, choose:"
            echo "      \"Boot from SPI - root on NVMe\""
        else
            echo ">>> When armbian-install opens, choose:"
            echo "      \"Boot from SD - root on NVMe\"   (or eMMC if you prefer)"
        fi
        echo
        read -r -p "      Press ENTER to launch armbian-install..." _
        sudo armbian-install
        echo
        echo "      Migration step complete. If armbian-install asked you to reboot, do so now."
    else
        echo "      → Skipping NVMe migration. Re-run this script later if you change your mind."
    fi
fi

echo
echo "=== Setup complete ==="
echo "If you changed the boot target or migrated to NVMe, reboot now: sudo reboot"
