# Samsung R429 Linux

Tweaks, fixes, and notes for running Linux on the Samsung R429 (and similar vintage Samsung laptops).

## Hardware

| Component | Detail |
|-----------|--------|
| Model | Samsung R429 |
| CPU | Intel Core i3 M 330 @ 2.13GHz |
| GPU | NVIDIA GeForce 310M (GT218M) |
| RAM | 4 GB |
| OS | Arch Linux (but distro-agnostic fixes) |

---

## Lid suspend fix

The ACPI lid switch on these laptops breaks the Linux `SW_LID` input protocol:

```
kernel: ACPI: button: The lid device is not compliant to SW_LID.
```

`systemd-logind` sees the lid event but can't act on it. The input layer never reports a valid `SW_LID` state change, so closing the lid does nothing.

### Fix

Two changes needed:

#### 1. Kernel parameter: `button.lid_init_state=open`

```bash
# Edit /etc/default/grub:
GRUB_CMDLINE_LINUX_DEFAULT="button.lid_init_state=open quiet"

# Regenerate grub config:
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

#### 2. Use `acpid` to catch the raw ACPI event

The ACPI event itself fires fine. It just never reaches the input layer. So we catch it directly:

```bash
# Install acpid
sudo pacman -S acpid    # Arch
sudo apt install acpid  # Debian/Ubuntu
sudo dnf install acpid  # Fedora
```

```bash
# Create the lid event handler
sudo tee /etc/acpi/events/lid << 'EOF'
event=button/lid.*
action=/etc/acpi/handlers/lid.sh
EOF
```

```bash
# Create the handler script
sudo mkdir -p /etc/acpi/handlers
sudo tee /etc/acpi/handlers/lid.sh << 'EOF'
#!/bin/bash
grep -q closed /proc/acpi/button/lid/LID0/state && /usr/bin/systemctl suspend
EOF
sudo chmod +x /etc/acpi/handlers/lid.sh
```

```bash
# Enable and start acpid
sudo systemctl enable --now acpid
```

### Verification

Close the lid and check:

```bash
journalctl -b | grep -E 'suspend|resume|PM:|acpid'
```

Expected output:

```
acpid: waiting for events
systemd-logind: suspend requested from client PID ... (systemctl)
systemd-logind: The system will suspend now!
PM: suspend entry (deep)
PM: Low-level resume complete
PM: suspend exit
```

---

## Performance tweaks

### 1. GPU reclocking (Nouveau)

The GeForce 310M boots at pstate 07 (405 MHz core / 810 MHz shader / 405 MHz memory).
The max pstate 0f (625 MHz / 1530 MHz / 790 MHz) is available but never used by default.

#### Live (no reboot)

```bash
echo "0f" | sudo tee /sys/kernel/debug/dri/0/pstate
```

#### Permanent (via modprobe)

```bash
sudo tee /etc/modprobe.d/nouveau-pstate.conf << 'EOF'
# Force nouveau to use the highest available GPU pstate
options nouveau config=NvClkMode=auto
EOF
```

The modprobe option doesn't reliably force the max pstate on all cards. If it doesn't stick, add a systemd service:

```bash
sudo tee /etc/systemd/system/nouveau-pstate.service << 'EOF'
[Unit]
Description=Force Nouveau GPU to max pstate
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0f > /sys/kernel/debug/dri/0/pstate'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now nouveau-pstate.service
```

### 2. CPU exploit mitigations

Disabling Spectre/Meltdown mitigations reclaims about 10-20% CPU performance on this
2010 Core i3 M 330. Only do this on a machine that doesn't run untrusted code.

```bash
# Add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub:
GRUB_CMDLINE_LINUX_DEFAULT="mitigations=off ..."

# Regenerate:
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

### 3. I/O scheduler (BFQ for HDD)

BFQ is designed for desktop responsiveness on mechanical disks.

```bash
sudo tee /etc/udev/rules.d/60-ioschedulers.rules << 'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF
```

To apply without rebooting:

```bash
echo bfq | sudo tee /sys/block/sda/queue/scheduler
```

### 4. ZRAM swappiness

With 4 GB RAM and a ZRAM swap device, bumping swappiness to 150 compresses
cold pages earlier instead of waiting until RAM is nearly full.

```bash
sudo tee /etc/sysctl.d/99-zram.conf << 'EOF'
vm.swappiness = 150
EOF
```

Apply immediately:

```bash
sudo sysctl vm.swappiness=150
```

### 5. Writeback aggregation

Increases the dirty writeback timeout from 5 to 60 seconds. That means fewer,
larger disk writes, which means less seeking on an HDD.

```bash
sudo tee /etc/sysctl.d/99-writeback.conf << 'EOF'
vm.dirty_writeback_centisecs = 6000
EOF
```

Apply immediately:

```bash
sudo sysctl vm.dirty_writeback_centisecs=6000
```

TLP may override this on restart. To reapply after TLP starts, add a systemd drop-in:

```bash
sudo mkdir -p /etc/systemd/system/tlp.service.d
sudo tee /etc/systemd/system/tlp.service.d/override.conf << 'EOF'
[Service]
ExecStartPost=/usr/bin/sysctl vm.dirty_writeback_centisecs=6000
EOF
sudo systemctl daemon-reload
sudo systemctl restart tlp.service
```

### 6. noatime mount

Stops the kernel from writing access timestamps on every file read. Saves
unnecessary HDD writes.

```bash
# Edit /etc/fstab, change relatime to noatime:
sudo sed -i 's/relatime/noatime/' /etc/fstab
```

Needs a reboot to take effect.

### 7. HDD Read-Ahead & Queue Depth Tuning

Limits read-ahead to 512 KB (preventing massive read amplification on bad sectors) and bumps BFQ queue depth to 256 requests for smoother head movement:

```bash
sudo tee /etc/udev/rules.d/60-hdd-queue.rules << 'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/read_ahead_kb}="512", ATTR{queue/nr_requests}="256"
EOF
```

### 8. Low Dirty Memory Thresholds

Prevents large 800 MB write stalls by forcing continuous background flushes at 3% dirty memory:

```bash
sudo tee /etc/sysctl.d/99-hdd-dirty-ratio.conf << 'EOF'
vm.dirty_background_ratio = 3
vm.dirty_ratio = 6
EOF
```

### 9. Ext4 Commit Interval

```bash
# Add commit=60 to the ext4 root entry only (vfat /boot does not support commit=60):
# UUID=... / ext4 rw,noatime,commit=60 0 1
```

### 10. Profile-Sync-Daemon (Browser in RAM)

Keeps browser profiles (Firefox/Chromium) in `tmpfs` RAM and syncs periodically, cutting daily disk reads/writes by ~80%:

```bash
sudo pacman -S profile-sync-daemon
systemctl --user enable --now psd.service
```

### 11. Nouveau Hardware Video Decoding Firmware

Extracts proprietary VP4 video engine firmware from NVIDIA 340.108 to enable H.264 / VC-1 / MPEG-2 hardware decoding under Nouveau:

```bash
mkdir -p /tmp/nouveau-fw-build && cd /tmp/nouveau-fw-build
wget https://raw.githubusercontent.com/envytools/firmware/master/extract_firmware.py
wget https://us.download.nvidia.com/XFree86/Linux-x86_64/340.108/NVIDIA-Linux-x86_64-340.108.run
sh NVIDIA-Linux-x86_64-340.108.run --extract-only
python3 extract_firmware.py
sudo mkdir -p /usr/lib/firmware/nouveau
sudo cp -a nv* vuc-* /usr/lib/firmware/nouveau/
sudo mkinitcpio -P
rm -rf /tmp/nouveau-fw-build
```

#### How to Revert:
```bash
sudo rm -rf /usr/lib/firmware/nouveau
sudo mkinitcpio -P
```

### 12. GPU Acceleration & Mesa GL Threading

Enables asynchronous OpenGL command submission and DRI3 hardware acceleration:

```bash
# Add mesa_glthread=true to /etc/environment
sudo tee -a /etc/environment << 'EOF'
mesa_glthread=true
EOF

# Configure DRI3 & TearFree in Xorg
sudo tee /etc/X11/xorg.conf.d/20-nouveau.conf << 'EOF'
Section "Device"
    Identifier "Nouveau GPU"
    Driver "nouveau"
    Option "DRI" "3"
    Option "TearFree" "true"
EndSection
EOF
```

### 13. Threaded IRQs & Nouveau Boost Parameters

Appends `threadirqs` (offloading hardware interrupts to priority-controlled threads to eliminate UI stutters under heavy disk load) and `nouveau.config=NvBoost=2,NvPmEnableGating=1` (requesting GPU boost clocks & hardware power gating):

```bash
# Add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub:
GRUB_CMDLINE_LINUX_DEFAULT="mitigations=off button.lid_init_state=open threadirqs nouveau.config=NvBoost=2,NvPmEnableGating=1 loglevel=3 quiet"

# Regenerate:
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

### 14. Boot Optimization & Volatile Journal

Removes network/bluetooth wait delays, removes initramfs `fsck` disk scans, and limits systemd journal size to prevent log flushing stalls on the mechanical HDD:

```bash
# Disable network online wait and unused bluetooth services at boot
sudo systemctl disable NetworkManager-wait-online.service
sudo systemctl disable bluetooth.service

# Remove fsck from initramfs HOOKS in /etc/mkinitcpio.conf and rebuild
# HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems)
sudo mkinitcpio -P

# Limit systemd journal disk writes
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/00-journal-limit.conf << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=50M
SystemMaxUse=50M
EOF
sudo systemctl restart systemd-journald
```

### 15. PS/2 Keyboard Resume Fix (`i8042.reset=1 i8042.nomux=1`)

Fixes the Samsung R-series hardware bug where the PS/2 keyboard fails to re-initialize after resuming from ACPI suspend:

```bash
# Add i8042.reset=1 i8042.nomux=1 to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub:
GRUB_CMDLINE_LINUX_DEFAULT="mitigations=off button.lid_init_state=open i8042.reset=1 i8042.nomux=1 threadirqs nouveau.config=NvBoost=2,NvPmEnableGating=1 loglevel=3 quiet"

# Regenerate:
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

## LightDM Tokyo Night Rice

To style the LightDM login screen with the Tokyo Night color palette and Papirus-Dark icons:

```bash
# 1. Install lightdm-gtk-greeter
sudo pacman -S lightdm-gtk-greeter

# 2. Copy TokyoNight theme system-wide
sudo cp -r ~/.local/share/themes/TokyoNight /usr/share/themes/

# 3. Configure /etc/lightdm/lightdm.conf [Seat:*] section
# greeter-session=lightdm-gtk-greeter

# 4. Configure /etc/lightdm/lightdm-gtk-greeter.conf
sudo tee /etc/lightdm/lightdm-gtk-greeter.conf << 'EOF'
[greeter]
theme-name = TokyoNight
icon-theme-name = Papirus-Dark
background = #16161e
user-background = false
font-name = Sans 10
position = 50%,center 50%,center
indicators = ~clock;~spacer;~session;~power
clock-format = %a, %b %d  %H:%M
EOF
```

---

## Overview

| Tweak | Impact | Live | Needs reboot |
|-------|--------|------|-------------|
| GPU reclocking (625 MHz) | UI snappiness, compositing | systemd service (on boot) | no |
| `mitigations=off` | CPU throughput +10-20% | no | yes |
| BFQ I/O scheduler | Desktop responsiveness | udev rule | no |
| swappiness=150 | Memory management | sysctl.d | no |
| writeback=60s | Fewer disk seeks | TLP override (systemd drop-in) | no |
| noatime | Less disk writes | fstab | yes |
| Keyboard resume fix | PS/2 controller reset on lid open | GRUB cmdline | yes |
| Boot optimization | Graphical target in 21.8s | systemd/journald | yes |

---

## Config files

Reference files in this repo mirror the installed locations:

| Repo path | Installed to |
|-----------|-------------|
| `etc/acpi/events/lid` | `/etc/acpi/events/lid` |
| `etc/acpi/handlers/lid.sh` | `/etc/acpi/handlers/lid.sh` |
| `etc/systemd/logind.conf.d/lid-suspend.conf` | `/etc/systemd/logind.conf.d/lid-suspend.conf` |
| `etc/modprobe.d/nouveau-pstate.conf` | `/etc/modprobe.d/nouveau-pstate.conf` |
| `etc/sysctl.d/99-zram.conf` | `/etc/sysctl.d/99-zram.conf` |
| `etc/sysctl.d/99-writeback.conf` | `/etc/sysctl.d/99-writeback.conf` |
| `etc/udev/rules.d/60-ioschedulers.rules` | `/etc/udev/rules.d/60-ioschedulers.rules` |
| `etc/systemd/system/nouveau-pstate.service` | `/etc/systemd/system/nouveau-pstate.service` |
| `etc/systemd/system/tlp.service.d/override.conf` | `/etc/systemd/system/tlp.service.d/override.conf` |
