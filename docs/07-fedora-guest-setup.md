# 07 Â· Fedora guest setup

[â† GPU passthrough](06-gpu-passthrough.md) Â· [Verification â†’](08-verification.md)

The card is in the VM. Now we replace nouveau with the proprietary NVIDIA
driver, plus a few quality-of-life setup steps (SSH persistence,
autologin) if not already done in [chapter 05](05-vm-creation.md).

The fully automated script for this chapter is
[`scripts/guide/06-guest-install-nvidia.sh`](../scripts/guide/06-guest-install-nvidia.sh).

## 7.1 Picking the right NVIDIA driver branch

**This is the single most-likely thing to get wrong.** NVIDIA drops
support for older GPU architectures from new driver branches periodically.
If you install the wrong branch, the module builds, loads, **and then
refuses to bind to your GPU**:

```
NVRM: The NVIDIA GPU 48e0:00:00.0 (PCI ID: 10de:1b06)
NVRM: nvidia.ko because it does not include the required GPU
```

For each GPU architecture, the right RPM Fusion branch is:

| GPU arch | Examples | Recommended package |
|---|---|---|
| **Pascal** | GTX 1050/1060/1070/1080 (Ti) | **`akmod-nvidia-580xx`** |
| Maxwell | GTX 970/980 (Ti) | `akmod-nvidia-470xx` |
| Kepler | GTX 660/680/780 | `akmod-nvidia-470xx` (last supported) |
| Turing+ | RTX 20-series and newer | `akmod-nvidia` (mainline 595+) |

The GTX 1080 Ti this guide is built around is Pascal, so we use the
`580xx` legacy branch.

To check your GPU's architecture: <https://en.wikipedia.org/wiki/List_of_Nvidia_graphics_processing_units>.

## 7.2 SSH + autologin (if not already done)

If you skipped these in chapter 05, do them now:

```bash
# Persist sshd
sudo systemctl enable --now sshd
systemctl is-enabled sshd     # should print: enabled

# Add an SSH key from your Windows host (replace with your actual public key)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'ssh-ed25519 AAAA... win-host->fedora-vm' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Enable GDM autologin
sudo tee /etc/gdm/custom.conf >/dev/null <<EOF
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=aseem

[security]

[xdmcp]

[chooser]

[debug]
EOF
```

## 7.3 RPM Fusion

Fedora's stock repos don't include NVIDIA's proprietary driver. RPM Fusion
is the standard third-party repository that packages it.

```bash
# Add both Free and Nonfree RPM Fusion repos
sudo dnf install -y \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Confirm the NVIDIA repo is present
dnf repolist | grep -i rpmfusion-nonfree
# Expect:
#   rpmfusion-nonfree                 RPM Fusion for Fedora 44 - Nonfree
#   rpmfusion-nonfree-nvidia-driver   RPM Fusion for Fedora 44 - Nonfree - NVIDIA Driver
#   rpmfusion-nonfree-updates         RPM Fusion for Fedora 44 - Nonfree - Updates
```

## 7.4 Install the NVIDIA driver (Pascal: 580xx branch)

For the GTX 1080 Ti and other Pascal cards:

```bash
sudo dnf install -y --skip-unavailable \
    akmod-nvidia-580xx \
    xorg-x11-drv-nvidia-580xx-cuda \
    xorg-x11-drv-nvidia-580xx-cuda-libs \
    nvidia-settings-580xx \
    libva-utils \
    vdpauinfo
```

- `akmod-nvidia-580xx` â€” the kernel module source + akmod (auto-rebuilds
  on kernel updates)
- `xorg-x11-drv-nvidia-580xx-cuda` â€” the CUDA runtime
- `xorg-x11-drv-nvidia-580xx-cuda-libs` â€” CUDA libraries
- `nvidia-settings-580xx` â€” the GUI control panel (X-based)

For non-Pascal GPUs, substitute the appropriate branch (e.g.
`akmod-nvidia-470xx`, or just `akmod-nvidia` for Turing+).

## 7.5 Build the kernel module immediately

The akmod package rebuilds the kernel module asynchronously â€” by default
it waits for a systemd timer or your next boot. Force it now so you can
see any build failure right away:

```bash
sudo akmods --force --rebuild
```

This takes 3-10 minutes depending on CPU. When it finishes you should
see:

```
Checking kmods exist for 7.0.12-201.fc44.x86_64 [  OK  ]
Building and installing nvidia-580xx-kmod [  OK  ]
```

Verify the module exists and reports the right version:

```bash
ls /lib/modules/$(uname -r)/extra/nvidia*/
# Expect: nvidia.ko.xz nvidia-drm.ko.xz nvidia-modeset.ko.xz nvidia-uvm.ko.xz nvidia-peermem.ko.xz

modinfo -F version nvidia
# Expect: 580.159.04 (or whatever the current 580.x release is)
```

If `modinfo -F version nvidia` says **"Module nvidia not found"**, the
build failed silently. Check `/var/cache/akmods/nvidia-*/build.log` for
the error.

## 7.6 Reboot

The RPM Fusion package already wrote:

- `/etc/modprobe.d/nvidia-installer-disable-nouveau.conf` to blacklist nouveau
- Updated the kernel cmdline via grubby to add `rd.driver.blacklist=nouveau modprobe.blacklist=nouveau`
- Regenerated the initramfs

So a simple reboot will displace nouveau and load nvidia:

```bash
sudo reboot
```

## 7.7 First boot with nvidia driver â€” verify

After the reboot, SSH back in and run:

```bash
nvidia-smi
```

Expected output:

```
NVIDIA-SMI 580.159.04             Driver Version: 580.159.04     CUDA Version: 13.0
+---------------------------------------+-----------------------+----------------------+
| GPU  Name             Persistence-M   | Bus-Id          Disp.A| Volatile Uncorr. ECC |
| Fan  Temp  Perf       Pwr:Usage/Cap   |          Memory-Usage | GPU-Util  Compute M. |
|=======================================+=======================+======================|
|   0  NVIDIA GeForce GTX 1080 Ti  Off  | 000048E0:00:00.0  Off |                  N/A |
|  0%   53C    P5    13W /  280W        |     3MiB / 11264MiB   |      0%      Default |
+---------------------------------------+-----------------------+----------------------+
```

Confirm the right driver is bound:

```bash
lspci -nnk -d 10de:1b06 | tail -3
# Expect:
#         Subsystem: ...
#         Kernel driver in use: nvidia       â† THIS
#         Kernel modules: nouveau, nvidia_drm, nvidia
```

Confirm nouveau is unloaded:

```bash
lsmod | grep -iE 'nvidia|nouveau'
# Expect: only nvidia* lines, no nouveau lines
```

If any of those checks fail, head to [troubleshooting](troubleshooting.md).

## 7.8 Common gotchas

### `nvidia-smi: command not found`

Either the install partially failed or `xorg-x11-drv-nvidia-580xx-cuda`
wasn't picked up. Re-run:

```bash
sudo dnf install -y --skip-unavailable xorg-x11-drv-nvidia-580xx-cuda
which nvidia-smi
# Expect: /usr/bin/nvidia-smi
```

### nouveau loads instead of nvidia

Either the blacklist file didn't get installed or the initramfs wasn't
regenerated. Force both:

```bash
# Confirm blacklist file exists
ls /usr/lib/modprobe.d/ /etc/modprobe.d/ 2>/dev/null | grep -i nouveau
# Expect at least: nvidia-installer-disable-nouveau.conf

# Regenerate initramfs explicitly
sudo dracut --force --regenerate-all

# Confirm kernel cmdline
cat /proc/cmdline
# Should include: rd.driver.blacklist=nouveau ... modprobe.blacklist=nouveau

sudo reboot
```

### `probe with driver nvidia failed with error -1`

The driver loaded but rejected your specific GPU. This is the
"wrong driver branch" problem from Â§7.1. Remove the current branch and
install the right one for your architecture:

```bash
# Example: you accidentally installed mainline (595.x) on a Pascal card
sudo dnf remove -y 'akmod-nvidia' 'xorg-x11-drv-nvidia*' 'kmod-nvidia*' 'nvidia-settings'
sudo dnf install -y akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda \
                    xorg-x11-drv-nvidia-580xx-cuda-libs nvidia-settings-580xx
sudo akmods --force --rebuild
sudo reboot
```

### Module builds but won't load due to signature enforcement

This means you forgot to disable Secure Boot on the VM (see
[Â§5.3](05-vm-creation.md#53-create-the-vm)):

```powershell
Stop-VM -Name Fedora -Force
Set-VMFirmware -VMName Fedora -EnableSecureBoot Off
Start-VM -Name Fedora
```

Reboot the VM and try again.

[â† GPU passthrough](06-gpu-passthrough.md) Â· [Verification â†’](08-verification.md)
