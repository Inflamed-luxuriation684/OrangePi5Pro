# Ubuntu 26.04 on Orange Pi 5 Pro

A working recipe to build and run **Ubuntu 26.04 LTS (Resolute Raccoon)** on the Orange Pi 5 Pro (Rockchip RK3588S), using Armbian's build framework with the `vendor` (Rockchip BSP) kernel.

As of May 2026 there is no off-the-shelf 26.04 image for this board. [Joshua Riek's `ubuntu-rockchip`](https://github.com/Joshua-Riek/ubuntu-rockchip) was archived on 29 April 2026, [Armbian's downloads page for the 5 Pro](https://www.armbian.com/orange-pi-5-pro/) only ships Debian Trixie, and Orange Pi's official downloads top out at 24.04. So we build it ourselves.

## Why this is two builds, not one

Ubuntu 26.04 ships **`rust-coreutils` (uutils)** as the default coreutils. The uutils binaries use `rustix`, which crashes during startup with:

```
thread 'main' panicked at rustix/.../auxv.rs:269:
called `Result::unwrap()` on an `Err` value: ()
```

…whenever invoked from a `chroot` whose host kernel was built without `CONFIG_BINFMT_MISC`. Orange Pi's stock vendor kernel (`6.1.43-rockchip-rk3588`) has it disabled, with no loadable module on disk:

```
$ grep BINFMT_MISC /boot/config-$(uname -r)
# CONFIG_BINFMT_MISC is not set
```

So Armbian's normal qemu-shielding can't engage during the resolute rootfs assembly. The very first chroot operation (linking `armbian-archive-keyring.gpg` into `/usr/share/keyrings/`) panics inside `uutils` and the build dies.

Armbian's **`6.1.115-vendor-rk35xx`** kernel, by contrast, ships `CONFIG_BINFMT_MISC=m`. Once you boot from an Armbian image, `qemu-user-static` auto-routing works and the 26.04 build succeeds.

So the recipe is:

1. **Build Armbian Ubuntu 24.04 (noble)** on the stock Orange Pi vendor system. Noble uses GNU coreutils — no uutils, no panic. (~3-5 h on this hardware)
2. **Flash 24.04 to microSD, boot from it.** That kernel has the `binfmt_misc` support we need.
3. **Build Armbian Ubuntu 26.04 (resolute)** from the booted 24.04 system. (~4-6 h)
4. Flash 26.04 wherever you want it (microSD, USB SSD, eMMC).

## Prerequisites

- Orange Pi 5 Pro (16 GB RAM strongly recommended; 4/8 GB will work, slower)
- A microSD card or USB SSD ≥ 4 GB (≥ 16 GB recommended)
- ~50 GB free disk on the build host
- Stock Orange Pi vendor Ubuntu 22.04 image as starting point (other hosts work but the recipe assumes this)

## Step 1 — Build Armbian noble (24.04) on the stock OPi system

SSH to your Orange Pi 5 Pro running the stock OPi vendor Ubuntu 22.04, then:

```bash
sudo apt-get update
sudo apt-get install -y git docker.io
sudo usermod -aG docker "$USER"        # log out / back in OR run: newgrp docker
git clone https://github.com/mack42/OrangePi5Pro.git
cd OrangePi5Pro
./01-build-noble.sh
```

Output lands at:

```
~/armbian-build/framework/output/images/Armbian-*_Orangepi5pro_noble_vendor_*.img.xz
```

Plus a matching `.txt` build manifest and `.sha` checksum.

## Step 2 — Flash and boot the 24.04 image

Copy the `.img.xz` to your workstation and flash to a microSD.

**On Windows: use [balenaEtcher](https://etcher.balena.io/).** This is the only tool I've gotten to produce a bootable card from this `.img.xz` reliably. Drag the `.img.xz` in, pick the SD, write. Done.

**Avoid Rufus and Raspberry Pi Imager on Windows.** Rufus's ISO/DD detection silently mangles the GPT (the card boots but the kernel sees only the whole-disk device with no partitions). Raspberry Pi Imager wrote a card that wouldn't enumerate the rootfs at the initramfs stage. Both wasted real time during development.

**On Linux**, `dd` directly works fine (it reads `.xz` via pipe):
```bash
xz -dc Armbian-*_noble_*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Insert the microSD into the OPi and power-cycle. Don't touch eMMC — your stock 22.04 stays untouched as a fallback. The 5 Pro's u-boot prefers microSD over eMMC.

First boot prompts for a root password and then to create a regular user. If the very first boot stalls at `(initramfs)` saying it can't find the rootfs, power-cycle once — first-boot scripts can lose a race with SD enumeration on the very first attempt; the second boot is reliable.

## Step 3 — Build Armbian resolute (26.04) from the noble system

SSH into the booted 24.04 system, then:

```bash
sudo apt-get update
sudo apt-get install -y git docker.io qemu-user-static binfmt-support
sudo usermod -aG docker "$USER" && newgrp docker
git clone https://github.com/mack42/OrangePi5Pro.git
cd OrangePi5Pro
./02-build-resolute.sh
```

Output:

```
~/armbian-build/framework/output/images/Armbian-*_Orangepi5pro_resolute_vendor_*.img.xz
```

## Step 4 — Flash 26.04

Same flashing procedure as Step 2, just point at the resolute `.img.xz`.

If you want 26.04 on **eMMC** (replacing your stock OPi 22.04), boot the SD-card 26.04 image first, log in, then run Armbian's `armbian-install` to mirror to eMMC. Test boot from microSD before committing to eMMC — flashing eMMC is a one-way trip without serial recovery tools.

## Caveats

- The 5 Pro is **community-supported (CSC)** in Armbian — no active board maintainer. The `vendor` kernel has good hardware coverage (GPU/VPU/HDMI/Wi-Fi/BT) but expect occasional rough edges. Test the peripherals you care about before committing to eMMC.
- These recipes use `BUILD_MINIMAL=yes BUILD_DESKTOP=no`. To build a desktop image, swap to `BUILD_DESKTOP=yes BUILD_MINIMAL=no DESKTOP_ENVIRONMENT=xfce` (or `gnome`). Build is much longer and image much larger.
- Each system's Armbian build cache is independent. The first build on a fresh host pulls a ~2 GB Docker base image and clones a kernel tree (~1-2 GB). Subsequent builds reuse those.

## Troubleshooting

### `rust-coreutils ... auxv.rs:269 panicked` during keyring setup

You're trying to build 26.04 from a host without `CONFIG_BINFMT_MISC`. Don't — do Step 1 first. Confirm the kernel:

```bash
grep BINFMT_MISC "/boot/config-$(uname -r)"
```

`# CONFIG_BINFMT_MISC is not set` → boot the noble image first.

### First boot stalls at `(initramfs)` with "Cannot find UUID..."

Power-cycle once. First-boot resize sometimes loses a race with SD enumeration. If it persists across multiple boots:

1. Pull the microSD, mount on another machine, edit `/boot/armbianEnv.txt` and append `rootwait` and `rootdelay=10` to the `extraargs=` line.
2. Or re-flash with balenaEtcher (Windows) or `dd` (Linux). See Step 2 — Rufus and Pi Imager have both produced unbootable cards from this image during development.

### `pgrep -af compile.sh` returns nothing mid-build

The build died. The last ~100 lines of `~/armbian-build/build.log` say why. Common causes:
- Out-of-disk: the kernel build alone needs ~10 GB, image creation another ~10 GB.
- Docker daemon not reachable (re-check `systemctl status docker`).
- Network blip during apt fetch (just rerun the script — caches mostly survive).

### Kernel build is unbearably slow

Cortex-A76 at 2.35 GHz × 4 + A55 × 4 is roughly half a low-end x86 desktop. Allow 1.5-3 hours for the kernel alone. Run the build on an x86 host if you have one — same `compile.sh`, same flags; binfmt-misc + qemu-aarch64 are auto-routed there and the resolute build works in one shot (no stepping stone needed).

## What this repo is not

- A maintained distro. It's a build recipe; the binaries inherit Armbian's CSC support tier (none).
- A guarantee that every peripheral works.
- An in-place upgrade tool. Don't `do-release-upgrade` your stock Orange Pi system — it ends badly with vendor BSPs.
