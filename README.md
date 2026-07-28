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

Reboot or reload nouveau for it to take effect.

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

### 6. noatime mount

Stops the kernel from writing access timestamps on every file read. Saves
unnecessary HDD writes.

```bash
# Edit /etc/fstab, change relatime to noatime:
sudo sed -i 's/relatime/noatime/' /etc/fstab
```

Needs a reboot to take effect.

---

## Overview

| Tweak | Impact | Live | Needs reboot |
|-------|--------|------|-------------|
| GPU reclocking (625 MHz) | UI snappiness, compositing | via pstate write | For permanent config |
| `mitigations=off` | CPU throughput +10-20% | no | yes |
| BFQ I/O scheduler | Desktop responsiveness | yes | Only for udev rule |
| swappiness=150 | Memory management | yes | no |
| writeback=60s | Fewer disk seeks | yes | no |
| noatime | Less disk writes | no | yes |

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
