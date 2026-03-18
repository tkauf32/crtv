#!/usr/bin/env python3

import json
import subprocess
import threading
import time
import uuid
from pathlib import Path
from gpiozero import Button

PIN_A = 17
PIN_B = 27
PIN_SW = 22

CRT_PLAYER = "/home/tommy/crtv/crt_player.sh"
CHANNELS_FILE = "/home/tommy/crtv/channels.json"
SWITCH_REQUEST_FILE = "/tmp/crt_player_switch.request"

MIN_CHANNEL = 1
MAX_CHANNEL = 1
current_channel = 0

BUTTON_BOUNCE = 0.05
DETENT_TRANSITIONS = 4
WORKER_POLL_SECONDS = 0.05
DETENT_COOLDOWN_SECONDS = 0.40

# Disable the encoder switch starting playback for now.
ENABLE_BUTTON_START = False

pin_a = Button(PIN_A, pull_up=True, bounce_time=0.001)
pin_b = Button(PIN_B, pull_up=True, bounce_time=0.001)
pin_sw = Button(PIN_SW, pull_up=True, bounce_time=BUTTON_BOUNCE)

accumulator = 0
last_ab = None
start_time = time.time()
last_detent_time = 0.0

state_lock = threading.Lock()
desired_channel = 0
active_channel = None
active_process = None
last_started_channel = None
active_channel_numbers = []

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


def load_active_channel_numbers():
    global active_channel_numbers, MIN_CHANNEL, MAX_CHANNEL

    with open(CHANNELS_FILE, "r", encoding="utf-8") as handle:
        payload = json.load(handle)

    channels = payload.get("channels", [])
    numbers = []

    for index, channel in enumerate(channels, start=1):
        if isinstance(channel, dict) and channel.get("disabled", False):
            continue
        if isinstance(channel, dict):
            number = channel.get("number", index)
        else:
            number = index
        if isinstance(number, int):
            numbers.append(number)

    numbers = sorted(set(numbers))
    if not numbers:
        raise RuntimeError("No active channels found in channels.json")

    active_channel_numbers = numbers
    MIN_CHANNEL = numbers[0]
    MAX_CHANNEL = numbers[-1]


def next_configured_channel(channel):
    for candidate in active_channel_numbers:
        if candidate > channel:
            return candidate
    return active_channel_numbers[0]


def prev_configured_channel(channel):
    for candidate in reversed(active_channel_numbers):
        if candidate < channel:
            return candidate
    return active_channel_numbers[-1]


def write_switch_request_token():
    token = f"encoder-{uuid.uuid4()}"
    Path(SWITCH_REQUEST_FILE).write_text(token, encoding="utf-8")


def build_switch_args(channel):
    return [CRT_PLAYER, "switch", "--channel", str(channel), "--no-recover"]


def request_channel(channel):
    global current_channel, desired_channel

    with state_lock:
        current_channel = channel
        desired_channel = channel

    write_switch_request_token()
    log(f"TARGET CHANNEL {channel}")


def next_channel():
    if current_channel < MIN_CHANNEL:
        request_channel(MIN_CHANNEL)
        return

    request_channel(next_configured_channel(current_channel))


def prev_channel():
    if current_channel < MIN_CHANNEL:
        request_channel(MAX_CHANNEL)
        return

    request_channel(prev_configured_channel(current_channel))


def switch_worker():
    global active_channel, active_process, last_started_channel

    while True:
        completed_channel = None
        completed_rc = None
        completed_desired = None
        start_channel = None
        start_args = None

        with state_lock:
            proc = active_process
            desired = desired_channel
            active = active_channel

        if proc is not None:
            rc = proc.poll()
            if rc is not None:
                completed_channel = active
                completed_rc = rc
                completed_desired = desired
                with state_lock:
                    active_process = None
                    active_channel = None

        with state_lock:
            proc = active_process
            desired = desired_channel

            if proc is None and desired >= MIN_CHANNEL and desired <= MAX_CHANNEL and desired != last_started_channel:
                start_channel = desired
                start_args = build_switch_args(desired)
                try:
                    active_process = subprocess.Popen(start_args)
                    active_channel = desired
                    last_started_channel = desired
                except Exception as exc:
                    print(f"{ts()}  Command error: {exc}")
                    active_process = None
                    active_channel = None

        if start_channel is not None and start_args is not None:
            print(f"{ts()}  RUN {' '.join(start_args)}")

        if completed_channel is not None:
            if completed_rc == 0:
                if completed_desired == completed_channel:
                    log(f"SWITCHED TO CHANNEL {completed_channel}")
                else:
                    print(f"{ts()}  STALE SWITCH COMPLETED {completed_channel} (desired {completed_desired})")
            elif completed_rc == 2:
                print(f"{ts()}  SUPERSEDED SWITCH TO {completed_channel}")
            else:
                if completed_desired == completed_channel:
                    print(f"{ts()}  Command failed with exit code {completed_rc}")
                    log(f"SWITCH FAILED TO {completed_channel}")
                else:
                    print(f"{ts()}  STALE SWITCH FAILED {completed_channel} rc={completed_rc} (desired {completed_desired})")

        time.sleep(WORKER_POLL_SECONDS)


def handle_button_press():
    if ENABLE_BUTTON_START:
        log("BUTTON PRESS -> START DISABLED IN CODE PATH")
    else:
        log("BUTTON PRESS IGNORED")


def handle_ab_change(source):
    global last_ab, accumulator, last_detent_time

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
        now = time.time()
        if now - last_detent_time < DETENT_COOLDOWN_SECONDS:
            log("DETENT CW IGNORED")
            return
        last_detent_time = now
        log("DETENT CW")
        next_channel()
    elif accumulator <= -DETENT_TRANSITIONS:
        accumulator = 0
        now = time.time()
        if now - last_detent_time < DETENT_COOLDOWN_SECONDS:
            log("DETENT CCW IGNORED")
            return
        last_detent_time = now
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

threading.Thread(target=switch_worker, daemon=True).start()
load_active_channel_numbers()

print("Encoder control started")
print(f"Pins: A={PIN_A}, B={PIN_B}, SW={PIN_SW}")
print(f"Player path: {CRT_PLAYER}")
print(f"Channels: {active_channel_numbers}")
print(f"Detent transitions: {DETENT_TRANSITIONS}")
print(f"Button start enabled: {ENABLE_BUTTON_START}")

last_ab = ab_value()
log("INITIAL")
request_channel(MIN_CHANNEL)

try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    print("\nExiting")
