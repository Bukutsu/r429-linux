#!/bin/bash
grep -q closed /proc/acpi/button/lid/LID0/state && /usr/bin/systemctl suspend
