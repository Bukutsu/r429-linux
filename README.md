# Samsung R429 Linux Setup

Fixes and performance tweaks for running Linux on the Samsung R429 (and similar 2010-era Samsung laptops).

## Hardware

| Component | Specification |
|-----------|---------------|
| Model | Samsung R429 / NP-R429 |
| CPU | Intel Core i3 M 330 (2.13 GHz) |
| GPU | NVIDIA GeForce 310M (GT218M) |
| RAM | 4 GB DDR3 |
| Storage | 320 GB Mechanical HDD |
| OS | Arch Linux |

---

## Lid Suspend Fix

The ACPI lid switch on this motherboard does not update Linux `SW_LID` input events properly:

```
kernel: ACPI: button: The lid device is not compliant to SW_LID.
```

Because `systemd-logind` relies on `SW_LID`, closing the lid fails to trigger suspend.

### Solution

#### 1. Set kernel parameter `button.lid_init_state=open`

Add `button.lid_init_state=open` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then update GRUB:

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

#### 2. Catch ACPI events with `acpid`

```bash
sudo pacman -S acpid
```

Create `/etc/acpi/events/lid`:

```ini
event=button/lid.*
action=/etc/acpi/handlers/lid.sh
```

Create `/etc/acpi/handlers/lid.sh`:

```bash
#!/bin/bash
grep -q closed /proc/acpi/button/lid/LID0/state && /usr/bin/systemctl suspend
```

Make it executable and start `acpid`:

```bash
sudo chmod +x /etc/acpi/handlers/lid.sh
sudo systemctl enable --now acpid
```

---

## PS/2 Keyboard Resume Fix

After resuming from ACPI sleep, the built-in keyboard can stop responding due to a register state loss on the motherboard's PS/2 controller.

Add `i8042.reset=1 i8042.nomux=1` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then update GRUB:

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

---

## Performance & Disk Optimizations

### 1. GPU Reclocking (Nouveau)

The GeForce 310M defaults to low power state 07 (405 MHz core). Setting state 0f increases clocks to 625 MHz core / 1530 MHz shader / 790 MHz memory.

Create `/etc/systemd/system/nouveau-pstate.service`:

```ini
[Unit]
Description=Set Nouveau GPU to max pstate
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0f > /sys/kernel/debug/dri/0/pstate'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Enable the service:

```bash
sudo systemctl enable --now nouveau-pstate.service
```

### 2. Disable CPU Security Mitigations

Reclaims 10-20% CPU performance on older dual-core processors.

Add `mitigations=off` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then update GRUB.

### 3. I/O Scheduler & HDD Queue Tuning

For mechanical hard drives, BFQ scheduling and smaller read-ahead values prevent micro-stutters during heavy disk reads.

Create `/etc/udev/rules.d/60-hdd-queue.rules`:

```udev
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq", ATTR{queue/read_ahead_kb}="512", ATTR{queue/nr_requests}="256"
```

### 4. Memory & Dirty Page Ratios

With 4 GB RAM and ZRAM enabled, early swappiness and low writeback thresholds keep the UI responsive while writing dirty pages in small batches.

`/etc/sysctl.d/99-zram.conf`:

```ini
vm.swappiness = 150
```

`/etc/sysctl.d/99-hdd-dirty-ratio.conf`:

```ini
vm.dirty_background_ratio = 3
vm.dirty_ratio = 6
```

`/etc/sysctl.d/99-writeback.conf`:

```ini
vm.dirty_writeback_centisecs = 6000
```

### 5. Ext4 Mount & Commit Settings

Edit `/etc/fstab` to add `noatime` and `commit=60` for the root partition:

```
UUID=... / ext4 rw,noatime,commit=60 0 1
```

*(Note: `commit=60` applies to ext4 only. Do not add `commit` options to VFAT `/boot`).*

### 6. Profile-Sync-Daemon (Browser Cache in RAM)

Symlinks browser profiles to `tmpfs` RAM and syncs periodically, cutting disk writes:

```bash
sudo pacman -S profile-sync-daemon
systemctl --user enable --now psd.service
```

### 7. Threaded Interrupts & Mesa Acceleration

Add `threadirqs nouveau.config=NvBoost=2,NvPmEnableGating=1` to GRUB command line.

Enable Mesa GL threading in `/etc/environment`:

```bash
mesa_glthread=true
```

Configure DRI3 in `/etc/X11/xorg.conf.d/20-nouveau.conf`:

```conf
Section "Device"
    Identifier "Nouveau GPU"
    Driver "nouveau"
    Option "DRI" "3"
    Option "TearFree" "true"
EndSection
```

### 8. Nouveau VP4 Video Decoding Firmware

Extracts video engine firmware from NVIDIA 340.108 drivers to enable hardware H.264 decoding support under Nouveau:

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

Revert anytime by removing `/usr/lib/firmware/nouveau` and running `sudo mkinitcpio -P`.

---

## Boot Speed Optimization

- **Disable wait-online & bluetooth:** `sudo systemctl disable NetworkManager-wait-online.service bluetooth.service`
- **Skip initramfs fsck:** Remove `fsck` from `HOOKS` in `/etc/mkinitcpio.conf` and run `sudo mkinitcpio -P`.
- **Volatile Journal:** Set `Storage=volatile` in `/etc/systemd/journald.conf.d/00-journal-limit.conf`.

---

## LightDM Tokyo Night Theme

Copy the GTK theme system-wide and configure `/etc/lightdm/lightdm-gtk-greeter.conf`:

```ini
[greeter]
theme-name = TokyoNight
icon-theme-name = Papirus-Dark
background = #16161e
user-background = false
font-name = Sans 10
position = 50%,center 50%,center
indicators = ~clock;~spacer;~session;~power
clock-format = %a, %b %d  %H:%M
```
