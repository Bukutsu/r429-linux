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

The ACPI lid switch on these laptops doesn't comply with the Linux `SW_LID` input protocol:

```
kernel: ACPI: button: The lid device is not compliant to SW_LID.
```

`systemd-logind` detects the lid event but can't act on it — the input subsystem never delivers a valid `SW_LID` state change, so lid close does nothing.

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

Since the ACPI event itself is generated correctly (it just doesn't reach the input layer), we bypass the problem:

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

## Config files

Reference files in this repo mirror the installed locations:

| Repo path | Installed to |
|-----------|-------------|
| `etc/acpi/events/lid` | `/etc/acpi/events/lid` |
| `etc/acpi/handlers/lid.sh` | `/etc/acpi/handlers/lid.sh` |
| `etc/systemd/logind.conf.d/lid-suspend.conf` | `/etc/systemd/logind.conf.d/lid-suspend.conf` |
