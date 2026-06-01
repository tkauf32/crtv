# Pi Migration

This repo contains the current Python service runtime, but not a full deployment contract. The migration work is mostly about reconstructing system state on the new Raspberry Pi.

## What Is Required

The minimum app runtime in this repo is:

- `crtv_service.py` or `python3 -m crtv.app`
- `crtv/`
- `channels.json`
- `assets/static.mp4`
- a valid `.env` for the target Pi

Everything else should be treated as either legacy reference or optional tooling unless you confirm it is still in active use.

## Legacy vs Active

Active runtime:

- `crtv/`
- `crtv_service.py`
- `deploy/crtv.service`
- `channels.json`
- `assets/static.mp4`

Legacy or reference:

- `crt_player.sh`
- `plex-api/`
- `yt-api/`
- `tv_mpv_shell.sh`

Do not start migration by copying shell behavior forward. The current service runtime is the Python path.

## Migration Strategy

1. Audit the old Pi before changing anything.
2. Capture system configuration that is not stored in this repo.
3. Normalize this repo so the new Pi can be built from versioned files plus a small checklist.
4. Bring up the new Pi in stages: media paths, display, audio, GPIO, power.
5. Only after the Python service is stable, decide whether any legacy shell files are still needed.

## Old Pi Audit

On the old Pi, collect:

- `/boot/config.txt` or `/boot/firmware/config.txt`
- `/etc/fstab`
- `systemctl cat crtv.service`
- `systemctl status crtv.service`
- installed packages relevant to playback and hardware
- the real `.env` used by the repo
- `python3 -m crtv.app --once` output
- `journalctl -u crtv.service -b`

Commands to run on the old Pi:

```bash
uname -a
cat /etc/os-release
systemctl cat crtv.service
systemctl status crtv.service --no-pager
journalctl -u crtv.service -b --no-pager | tail -n 200
cat /boot/firmware/config.txt
cat /etc/fstab
python3 -m crtv.app --once
./scripts/audit-runtime.sh
```

Also save:

- `ls -la /home/tommy/crtv`
- `find /home/tommy/crtv -maxdepth 2 -type f | sort`
- `env | sort`

That will expose missing repo files, local media assumptions, and service overrides.

Recommended location in this repo:

- `system-files/old-pi/`

Example capture commands:

```bash
mkdir -p system-files/old-pi
cp .env system-files/old-pi/.env
cp /boot/firmware/config.txt system-files/old-pi/config.txt
cp /etc/fstab system-files/old-pi/fstab
systemctl cat crtv.service > system-files/old-pi/crtv.service.systemd.txt
systemctl status crtv.service --no-pager > system-files/old-pi/crtv.service.status.txt
journalctl -u crtv.service -b --no-pager | tail -n 200 > system-files/old-pi/crtv.service.journal.tail.txt
env | sort > system-files/old-pi/env.sorted.txt
find /home/tommy/crtv -maxdepth 3 -type f | sort > system-files/old-pi/files.txt
git ls-files > system-files/old-pi/git-ls-files.txt
bash scripts/audit-runtime.sh > system-files/old-pi/runtime-audit.txt
python3 -m crtv.app --once > system-files/old-pi/app-once.stdout.txt 2> system-files/old-pi/app-once.stderr.txt
```

## New Pi Build Order

### 1. Base OS

Use the same Raspberry Pi OS family if possible. If the old Pi was built on Raspberry Pi OS Lite plus Xorg, do the same first. Do not mix a Wayland-first desktop image into the migration unless you want to rework display assumptions.

### 2. Packages

Install and verify at least:

- `python3`
- `python3-gpiozero`
- `python3-smbus` or `python3-smbus2`
- `mpv`
- `alsa-utils`
- `netcat-openbsd`

Often useful during bring-up:

- `i2c-tools`
- `mesa-utils`
- `git`

The repo currently assumes `mpv`, `amixer`, and `nc` exist in `PATH`.

### 3. Repo and Env

Clone the repo onto the new Pi and create `.env` from `.env.example`.

Update at least:

- `DISPLAY`
- `XAUTHORITY`
- `CHANNELS_FILE`
- any PiSugar toggles
- any display power commands
- any composite-output-specific `mpv` settings

### 4. Media Paths

Current `channels.json` hardcodes paths like:

- `/mnt/usb/media/...`
- `/home/tommy/crtv/local-media/music/local-mixes`

These must exist on the new Pi or the service will boot into empty channels. Make sure the new mount points match exactly, or change `channels.json` to match the new layout.

### 5. Service

Install the systemd unit by copying `deploy/crtv.service`, then adjust:

- `User=`
- `WorkingDirectory=`
- `XAUTHORITY=`
- any display-related env

After that:

```bash
sudo systemctl daemon-reload
sudo systemctl enable crtv.service
sudo systemctl start crtv.service
sudo journalctl -u crtv.service -f
```

## Composite Output on Pi 2W

This is the most likely source of migration drift.

The current Python player defaults to:

- `MPV_VO=gpu`
- `MPV_GPU_CONTEXT=x11egl`
- `DISPLAY=:0`

Those defaults assume an X11-backed graphical session. Composite on a Pi 2W may still work with X11, but you should treat display mode as an explicit bring-up step:

1. Confirm whether the new Pi will run Xorg.
2. Confirm the exact `DISPLAY` and `XAUTHORITY` values under the service user.
3. Test `mpv` manually before involving GPIO or systemd.
4. If X11 GPU output is unstable on composite, switch to the simplest working `mpv` path first, then reintroduce CRT shader settings.

Start with a manual test like:

```bash
DISPLAY=:0 XAUTHORITY=/home/tommy/.Xauthority mpv --profile=crt-lottes --vo=gpu --gpu-context=x11egl --fullscreen assets/static.mp4
```

If that fails, the display stack needs to be fixed before app debugging is worth doing.

## Recommended Bring-Up Sequence

Validate the new Pi in this order:

1. `./scripts/audit-runtime.sh`
2. `python3 -m crtv.app --headless --once`
3. manual `mpv` launch with the target display settings
4. `python3 -m crtv.app --once`
5. `python3 -m crtv.app`
6. systemd service
7. GPIO knobs and standby button
8. ADS1115 volume knob
9. PiSugar hooks

This keeps hardware-specific failures from masking app boot failures.

## Missing Files Risk

The old Pi may contain untracked files not present in Git, especially:

- `.env`
- alternate `channels.json`
- local scripts called by env vars
- local media directories
- modified service files outside the repo

The simplest way to detect that is to compare:

```bash
find /home/tommy/crtv -maxdepth 3 -type f | sort
git status --ignored
git ls-files
```

If the old Pi has files that the repo does not, copy them into `system-files/old-pi/` and decide whether they should become versioned install assets or remain local-only references.

## First Cleanup Targets

To make future migrations simpler, the next improvements should be:

- add a real install script or Ansible task for packages and service install
- keep a production `.env` template in the repo
- move machine-specific paths out of `channels.json` where possible
- delete or archive legacy shell paths once you confirm they are unused
