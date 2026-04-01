# PiSugar Command Reference for Raspberry Pi

> Status: compiled from current official PiSugar docs and wiki. I cannot verify which commands work on your exact hardware until you run them on your Raspberry Pi.
>
> Goal: keep a practical command list for PiSugar power features such as low-battery shutdown, software power-off, RTC wake, and power-state queries.

## 1) First: identify whether you have PiSugar 3

Enable I2C first:

```bash
sudo raspi-config
# Interfacing Options -> I2C -> Yes
```

Install I2C tools:
```bash
sudo apt-get install i2c-tools
```

Check I2C devices:

```bash
i2cdetect -y 1
```

Official detection commands:

### PiSugar 3
```bash
i2cdetect -y 1
i2cdump -y 1 0x57
i2cdump -y 1 0x68
```

### PiSugar 2
```bash
i2cdetect -y 1
i2cdump -y 1 0x32
i2cdump -y 1 0x75
```

Once the PiSugar service is installed, the easiest model check is:

```bash
echo "get model" | nc -q 0 127.0.0.1 8423
```

## 2) Install PiSugar Power Manager

```bash
wget https://cdn.pisugar.com/release/pisugar-power-manager.sh
bash pisugar-power-manager.sh -c release
```

If prompted and your board is PiSugar 3 or PiSugar 3 Plus, select:

```text
PiSugar3
```

Web UI after install:

```text
http://<your-raspberry-pi-ip>:8421
```

## 3) Service management

```bash
sudo systemctl daemon-reload
sudo systemctl status pisugar-server
sudo systemctl start pisugar-server
sudo systemctl stop pisugar-server
sudo systemctl enable pisugar-server
sudo systemctl disable pisugar-server
```

## 4) How to talk to PiSugar from the shell

### TCP method

```bash
echo "get battery" | nc -q 0 127.0.0.1 8423
```

### Unix socket method

```bash
nc -U /tmp/pisugar-server.sock
```

Then type commands interactively, for example:

```text
get battery
get model
get rtc_time
```

## 5) Most useful read commands

### Basic status

```bash
echo "get model" | nc -q 0 127.0.0.1 8423
echo "get firmware_version" | nc -q 0 127.0.0.1 8423
echo "get battery" | nc -q 0 127.0.0.1 8423
echo "get battery_v" | nc -q 0 127.0.0.1 8423
echo "get temperature" | nc -q 0 127.0.0.1 8423
```

### External power / charging related

```bash
echo "get battery_power_plugged" | nc -q 0 127.0.0.1 8423
echo "get battery_allow_charging" | nc -q 0 127.0.0.1 8423
echo "get battery_output_enabled" | nc -q 0 127.0.0.1 8423
echo "get battery_charging_range" | nc -q 0 127.0.0.1 8423
```

Notes:
- `battery_power_plugged` is the most useful query for whether USB/external power is present on newer models.
- The docs note that on newer models you should prefer `battery_power_plugged` and `battery_allow_charging` rather than relying on `get battery_charging` alone.

### RTC / alarm / wake related

```bash
echo "get rtc_time" | nc -q 0 127.0.0.1 8423
echo "get rtc_alarm_enabled" | nc -q 0 127.0.0.1 8423
echo "get rtc_alarm_time" | nc -q 0 127.0.0.1 8423
echo "get alarm_repeat" | nc -q 0 127.0.0.1 8423
```

### Button / shutdown related

```bash
echo "get button_enable" | nc -q 0 127.0.0.1 8423
echo "get button_shell" | nc -q 0 127.0.0.1 8423
echo "get safe_shutdown_level" | nc -q 0 127.0.0.1 8423
echo "get safe_shutdown_delay" | nc -q 0 127.0.0.1 8423
echo "get anti_mistouch" | nc -q 0 127.0.0.1 8423
echo "get soft_poweroff" | nc -q 0 127.0.0.1 8423
echo "get soft_poweroff_shell" | nc -q 0 127.0.0.1 8423
```

## 6) Most useful write commands

## Low-battery safe shutdown

Set shutdown threshold to 3%:

```bash
echo "set_safe_shutdown_level 3" | nc -q 0 127.0.0.1 8423
```

Set delay to 30 seconds:

```bash
echo "set_safe_shutdown_delay 30" | nc -q 0 127.0.0.1 8423
```

Read back values:

```bash
echo "get safe_shutdown_level" | nc -q 0 127.0.0.1 8423
echo "get safe_shutdown_delay" | nc -q 0 127.0.0.1 8423
```

## Configure button behavior

Enable long-press action:

```bash
echo "set_button_enable long 1" | nc -q 0 127.0.0.1 8423
```

Attach a shutdown shell command to long press:

```bash
echo "set_button_shell long sudo shutdown now" | nc -q 0 127.0.0.1 8423
```

Examples for other button types:

```bash
echo "set_button_enable single 1" | nc -q 0 127.0.0.1 8423
echo "set_button_enable double 1" | nc -q 0 127.0.0.1 8423
```

## Enable software-triggered poweroff behavior

```bash
echo "set_soft_poweroff true" | nc -q 0 127.0.0.1 8423
```

Set the shell that runs during software poweroff:

```bash
echo "set_soft_poweroff_shell sudo shutdown now" | nc -q 0 127.0.0.1 8423
```

Read back values:

```bash
echo "get soft_poweroff" | nc -q 0 127.0.0.1 8423
echo "get soft_poweroff_shell" | nc -q 0 127.0.0.1 8423
```

## RTC time sync and scheduled wake

Sync Raspberry Pi system time to the PiSugar RTC:

```bash
echo "rtc_pi2rtc" | nc -q 0 127.0.0.1 8423
```

Sync RTC back to the Raspberry Pi system clock:

```bash
echo "rtc_rtc2pi" | nc -q 0 127.0.0.1 8423
```

Set an RTC wake alarm:

```bash
echo "rtc_alarm_set 2026-04-01T07:30:00-05:00 127" | nc -q 0 127.0.0.1 8423
```

Disable the RTC alarm:

```bash
echo "rtc_alarm_disable" | nc -q 0 127.0.0.1 8423
```

Repeat mask note:
- `127` means `1111111`, which the docs describe as all weekdays enabled.

## Charging / power control

Allow charging:

```bash
echo "set_allow_charging true" | nc -q 0 127.0.0.1 8423
```

Disallow charging:

```bash
echo "set_allow_charging false" | nc -q 0 127.0.0.1 8423
```

Enable battery output:

```bash
echo "set_battery_output true" | nc -q 0 127.0.0.1 8423
```

Disable battery output:

```bash
echo "set_battery_output false" | nc -q 0 127.0.0.1 8423
```

Set charging range (example: restart at 70%, stop at 80%):

```bash
echo "set_battery_charging_range 70 80" | nc -q 0 127.0.0.1 8423
```

## PiSugar 3-specific or especially relevant features

### Anti-mistouch switch behavior

```bash
echo "set_anti_mistouch true" | nc -q 0 127.0.0.1 8423
echo "get anti_mistouch" | nc -q 0 127.0.0.1 8423
```

### Hardware battery protection / input protection

```bash
echo "set_input_protect true" | nc -q 0 127.0.0.1 8423
echo "get input_protect" | nc -q 0 127.0.0.1 8423
```

### RTC calibration (PiSugar 3)

```bash
echo "rtc_adjust_ppm 0" | nc -q 0 127.0.0.1 8423
echo "get rtc_adjust_ppm" | nc -q 0 127.0.0.1 8423
```

Docs say allowed range is:

```text
-500.0 to 500.0
```

## 7) Practical feature map

### Low power / low battery shutdown
Use these:

```bash
set_safe_shutdown_level
set_safe_shutdown_delay
get safe_shutdown_level
get safe_shutdown_delay
```

### Safe software shutdown when button is pressed
Use these:

```bash
set_button_enable long 1
set_button_shell long sudo shutdown now
```

### RTC-based power on / wake up
Use these:

```bash
rtc_pi2rtc
rtc_alarm_set <ISO8601 time> <repeat-mask>
rtc_alarm_disable
get rtc_alarm_time
get rtc_alarm_enabled
```

### Detect USB/external power presence
Use this:

```bash
get battery_power_plugged
```

### Turn charging on/off
Use this:

```bash
set_allow_charging true|false
```

### Battery protection / lifespan-oriented charging
Use these:

```bash
set_battery_charging_range <restart%> <stop%>
set_input_protect true|false
```

## 8) Important caution on command naming

The PiSugar docs show example commands like:

```text
safe_shutdown_level 3
safe_shutdown_delay 30
```

But the command table documents the setter forms as:

```text
set_safe_shutdown_level [number]
set_safe_shutdown_delay [number]
```

For documentation and scripting, I recommend using the explicit setter forms below because they are the formally documented command names:

```bash
set_safe_shutdown_level 3
set_safe_shutdown_delay 30
```

## 9) Useful files and ports

Config file:

```text
/etc/pisugar-server/config.json
```

Default interfaces:

```text
Unix socket: /tmp/pisugar-server.sock
TCP:         0.0.0.0:8423
WebSocket:   0.0.0.0:8422
HTTP/WebUI:  0.0.0.0:8421
```

## 10) Firmware update for PiSugar 3

```bash
curl https://cdn.pisugar.com/release/PiSugarUpdate.sh | sudo bash
```

Official docs note that if flashing mode does not start, you can try pressing the reset button on the PiSugar 3 PCB.

## 11) Minimal test sequence I would run on your Pi

```bash
sudo systemctl status pisugar-server
echo "get model" | nc -q 0 127.0.0.1 8423
echo "get battery" | nc -q 0 127.0.0.1 8423
echo "get battery_power_plugged" | nc -q 0 127.0.0.1 8423
echo "get rtc_time" | nc -q 0 127.0.0.1 8423
echo "get safe_shutdown_level" | nc -q 0 127.0.0.1 8423
echo "get soft_poweroff" | nc -q 0 127.0.0.1 8423
```

If those work, your next useful config actions are probably:

```bash
echo "set_safe_shutdown_level 3" | nc -q 0 127.0.0.1 8423
echo "set_safe_shutdown_delay 30" | nc -q 0 127.0.0.1 8423
echo "set_button_enable long 1" | nc -q 0 127.0.0.1 8423
echo "set_button_shell long sudo shutdown now" | nc -q 0 127.0.0.1 8423
```

---

## Sources used

- PiSugar Power Manager docs
- PiSugar 3 Series docs
- PiSugar GitHub/wiki
