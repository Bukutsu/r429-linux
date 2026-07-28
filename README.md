# Samsung R429 Lid Suspend Fix

If your Samsung R429 (or similar vintage Samsung laptop) won't suspend when you close the lid on Linux, it's a known ACPI firmware bug. Here's the fix.

## The problem

The ACPI lid switch on these laptops doesn't comply with the Linux `SW_LID` input protocol:

```
kernel: ACPI: button: The lid device is not compliant to SW_LID.
```

This means `systemd-logind` detects the lid event but can't act on it — the input subsystem never delivers a valid `SW_LID` state change, so lid close does nothing and the laptop never suspends.

## The fix

Two changes needed:

### 1. Kernel parameter: `button.lid_init_state=open`

This tells the kernel to initialize the lid state as "open" at boot, avoiding a related initialization quirk.

```bash
# Edit /etc/default/grub and add to GRUB_CMDLINE_LINUX_DEFAULT:
GRUB_CMDLINE_LINUX_DEFAULT="button.lid_init_state=open quiet"

# Regenerate grub config:
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

### 2. Use `acpid` instead of the broken SW_LID input layer

Since the ACPI event itself **is** generated correctly (it just doesn't reach the input layer as a valid `SW_LID` event), we bypass the problem by catching the ACPI event directly with `acpid`.

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

## Optional: passwordless sudo for suspend

If the user running `acpid` needs to call `systemctl suspend` without a password prompt (acpid runs as root, so this shouldn't be necessary, but good to have):

```bash
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/wheel-nopasswd
```

## Verification

Close the lid and check:

```bash
journalctl -b | grep -E 'suspend|resume|PM:|acpid'
```

You should see:

```
acpid: waiting for events
systemd-logind: suspend requested from client PID ... (systemctl)
systemd-logind: The system will suspend now!
PM: suspend entry (deep)
PM: Low-level resume complete
PM: suspend exit
```

## Hardware tested

| Component | Detail |
|-----------|--------|
| Model | Samsung R429 (or similar) |
| CPU | Intel Core i3 M 330 @ 2.13GHz |
| GPU | NVIDIA GeForce 310M (GT218M, nouveau driver) |
| RAM | 4 GB |
| Kernel | 7.1.5-arch1-1 (also tested on other distros) |
