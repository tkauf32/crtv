# About the environment / graphics
```
tommy@raspberrypi:~/crt/plex-api $ echo "=== session ==="
echo "XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
echo "DISPLAY=$DISPLAY"
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
echo
echo "=== processes ==="
ps -e | egrep -i 'Xorg|Xwayland|wayland|weston|wayfire|kwin_wayland|sway' | grep -v egrep || true
echo
echo "=== drm modules ==="
lsmod | egrep 'vc4|v3d|drm' | head -n 50
echo
echo "=== mesa ==="
glxinfo -B 2>/dev/null | egrep 'OpenGL vendor|OpenGL renderer|OpenGL version' || echo "glxinfo missing (install mesa-utils)"
echo
echo "=== vc4 overlay ==="
grep -R "dtoverlay=vc4" /boot/config.txt /boot/firmware/config.txt 2>/dev/null || echo "No vc4 overlay line found"
=== session ===
XDG_SESSION_TYPE=tty
DISPLAY=
WAYLAND_DISPLAY=

=== processes ===
    876 tty7     00:19:22 Xorg

=== drm modules ===
vc4                   401408  6
v3d                   184320  2
drm_display_helper     24576  1 vc4
gpu_sched              61440  1 v3d
cec                    53248  1 vc4
drm_dma_helper         24576  2 vc4
drm_shmem_helper       32768  1 v3d
drm_kms_helper        229376  3 drm_dma_helper,vc4,drm_shmem_helper
snd_soc_core          303104  2 vc4,snd_soc_hdmi_codec
drm                   675840  11 gpu_sched,drm_kms_helper,drm_dma_helper,v3d,vc4,drm_shmem_helper,drm_display_helper
drm_panel_orientation_quirks    28672  1 drm
backlight              24576  2 drm_kms_helper,drm

=== mesa ===
glxinfo missing (install mesa-utils)

=== vc4 overlay ===
/boot/firmware/config.txt:dtoverlay=vc4-kms-v3d
tommy@raspberrypi:~/crt/plex-api $ 
```

- Running on Raspberry Pi 4
- Display is out via hdmi
- Installed lite version of rpi os
- Installed gui for the above reason
- Using mpv because it is easy to run shaders over. 
- installed socat for channels feature
