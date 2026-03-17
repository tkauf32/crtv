#!/usr/bin/env python3

import subprocess
import time
from gpiozero import Button

PIN_A = 17
PIN_B = 27
PIN_SW = 22

CRT_PLAYER = "/home/tommy/crtv/crt_player.sh"

MIN_CHANNEL = 1
MAX_CHANNEL = 10
current_channel = 1

BUTTON_BOUNCE = 0.05
COMMAND_COOLDOWN_SECONDS = 0.15
DETENT_TRANSITIONS = 4

# Disable the encoder switch starting playback for now.
ENABLE_BUTTON_START = False

pin_a = Button(PIN_A, pull_up=True, bounce_time=0.001)
pin_b = Button(PIN_B, pull_up=True, bounce_time=0.001)
pin_sw = Button(PIN_SW, pull_up=True, bounce_time=BUTTON_BOUNCE)

last_command_time = 0.0
accumulator = 0
last_ab = None
start_time = time.time()

TRANSITIONS = {
    (0, 1): +1,
    (1, 3): +1,
    (3, 2): +1,
    (2, 0): +1,
    (1, 0): -1,
    (3, 1): -1,
    (2, 3): -1,
    (0, 2): -1,
}


def ts():
    return f"{time.time() - start_time:8.3f}s"


def logic_level(btn):
    return 0 if btn.is_pressed else 1


def ab_bits():
    a = logic_level(pin_a)
    b = logic_level(pin_b)
    return a, b


def ab_value():
    a, b = ab_bits()
    return (a << 1) | b


def log(msg):
    a, b = ab_bits()
    print(f"{ts()}  {msg:<34} A={a} B={b} ch={current_channel} acc={accumulator}")


def run_cmd(args):
    try:
        print(f"{ts()}  RUN {' '.join(args)}")
        result = subprocess.run(args, check=True)
        return result.returncode == 0
    except subprocess.CalledProcessError as e:
        print(f"{ts()}  Command failed with exit code {e.returncode}")
        return False
    except Exception as e:
        print(f"{ts()}  Command error: {e}")
        return False


def switch_channel(channel):
    global current_channel, last_command_time

    now = time.time()
    if now - last_command_time < COMMAND_COOLDOWN_SECONDS:
        log("CHANNEL SWITCH COOLDOWN")
        return

    ok = run_cmd([CRT_PLAYER, "switch", "--channel", str(channel)])
    if ok:
        current_channel = channel
        last_command_time = now
        log(f"SWITCHED TO CHANNEL {channel}")
    else:
        log(f"SWITCH FAILED TO {channel}")


def next_channel():
    new_channel = current_channel + 1
    if new_channel > MAX_CHANNEL:
        new_channel = MIN_CHANNEL
    switch_channel(new_channel)


def prev_channel():
    new_channel = current_channel - 1
    if new_channel < MIN_CHANNEL:
        new_channel = MAX_CHANNEL
    switch_channel(new_channel)


def handle_button_press():
    if ENABLE_BUTTON_START:
        log("BUTTON PRESS -> START DISABLED IN CODE PATH")
    else:
        log("BUTTON PRESS IGNORED")


def handle_ab_change(source):
    global last_ab, accumulator

    current_ab = ab_value()

    if last_ab is None:
        last_ab = current_ab
        log(f"{source} INIT")
        return

    step = TRANSITIONS.get((last_ab, current_ab), 0)

    if step == 0:
        last_ab = current_ab
        return

    accumulator += step
    last_ab = current_ab

    if accumulator >= DETENT_TRANSITIONS:
        accumulator = 0
        log("DETENT CW")
        next_channel()
    elif accumulator <= -DETENT_TRANSITIONS:
        accumulator = 0
        log("DETENT CCW")
        prev_channel()


def on_a_pressed():
    handle_ab_change("A LOW")


def on_a_released():
    handle_ab_change("A HIGH")


def on_b_pressed():
    handle_ab_change("B LOW")


def on_b_released():
    handle_ab_change("B HIGH")


pin_a.when_pressed = on_a_pressed
pin_a.when_released = on_a_released
pin_b.when_pressed = on_b_pressed
pin_b.when_released = on_b_released
pin_sw.when_pressed = handle_button_press

print("Encoder control started")
print(f"Pins: A={PIN_A}, B={PIN_B}, SW={PIN_SW}")
print(f"Player path: {CRT_PLAYER}")
print(f"Channels: {MIN_CHANNEL}..{MAX_CHANNEL}")
print(f"Detent transitions: {DETENT_TRANSITIONS}")
print(f"Button start enabled: {ENABLE_BUTTON_START}")

last_ab = ab_value()
log("INITIAL")

try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    print("\nExiting")
