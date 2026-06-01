# System Files

This directory is for machine-specific files captured from a working Raspberry Pi so they can be reviewed, versioned, and reused during installation on another device.

## Layout

- `old-pi/`: files copied from the currently working source device
- `new-pi/`: notes or adjusted configs created while bringing up the replacement device

Suggested contents for `old-pi/`:

- `.env`
- `config.txt` from `/boot/firmware/config.txt`
- `fstab`
- rendered `systemd` unit output
- service logs
- runtime audit output
- file inventory

Do not copy large media libraries into this repo. Keep only configuration, diagnostics, and small scripts/templates.

## Recommended Flow

1. Pull the latest repo on the old Pi.
2. Copy the live machine files into `system-files/old-pi/`.
3. Commit and push those captured files.
4. Pull them onto the development machine and review what must become part of the install path.
5. Use the captured files directly or as templates for the new Pi.
