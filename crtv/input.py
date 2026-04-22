from __future__ import annotations

import logging
import math
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

from .config import AppConfig
from .models import EncoderPins

try:
    from gpiozero import Button
except Exception:  # pragma: no cover - gpiozero is optional off-device
    Button = None  # type: ignore[assignment]

try:
    from smbus2 import SMBus
except Exception:  # pragma: no cover - optional on Pi images
    try:
        from smbus import SMBus  # type: ignore[no-redef]
    except Exception:  # pragma: no cover - optional off-device
        SMBus = None  # type: ignore[assignment]


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


@dataclass
class RotaryCallbacks:
    on_clockwise: Callable[[], None]
    on_counterclockwise: Callable[[], None]
    on_click: Callable[[], None]


class RotaryEncoder:
    TRANSITION_RESET_SECONDS = 0.05

    def __init__(
        self,
        name: str,
        pins: EncoderPins,
        config: AppConfig,
        callbacks: RotaryCallbacks,
    ):
        if Button is None:
            raise RuntimeError("gpiozero is required on the Raspberry Pi runtime")
        self.name = name
        self.callbacks = callbacks
        self.detent_transitions = config.detent_transitions
        self.detent_cooldown_seconds = config.detent_cooldown_seconds
        self.pin_a = Button(pins.a, pull_up=True, bounce_time=config.pin_bounce)
        self.pin_b = Button(pins.b, pull_up=True, bounce_time=config.pin_bounce)
        self.pin_sw = Button(pins.sw, pull_up=True, bounce_time=config.button_bounce)
        self.accumulator = 0
        self.last_ab = self._ab_value()
        self.detent_ab = self.last_ab
        self.last_detent_time = 0.0
        self.last_transition_time = 0.0

        self.pin_a.when_pressed = lambda: self._handle_ab_change()
        self.pin_a.when_released = lambda: self._handle_ab_change()
        self.pin_b.when_pressed = lambda: self._handle_ab_change()
        self.pin_b.when_released = lambda: self._handle_ab_change()
        self.pin_sw.when_pressed = self.callbacks.on_click

    def _logic_level(self, button: Button) -> int:
        return 0 if button.is_pressed else 1

    def _ab_value(self) -> int:
        return (self._logic_level(self.pin_a) << 1) | self._logic_level(self.pin_b)

    def _handle_ab_change(self) -> None:
        now = time.time()
        if now - self.last_transition_time > self.TRANSITION_RESET_SECONDS:
            self.accumulator = 0
        current_ab = self._ab_value()
        step = TRANSITIONS.get((self.last_ab, current_ab), 0)
        self.last_ab = current_ab
        self.last_transition_time = now
        if step == 0:
            self.accumulator = 0
            return

        self.accumulator += step
        if current_ab != self.detent_ab or abs(self.accumulator) < self.detent_transitions:
            return

        if now - self.last_detent_time < self.detent_cooldown_seconds:
            self.accumulator = 0
            return

        direction = 1 if self.accumulator > 0 else -1
        self.accumulator = 0
        self.last_detent_time = now
        if direction > 0:
            self.callbacks.on_clockwise()
        else:
            self.callbacks.on_counterclockwise()


class InputRouter:
    def __init__(self, config: AppConfig, controller: "TvController"):
        from .controller import TvController

        self.left = RotaryEncoder(
            name="top",
            pins=config.top_encoder,
            config=config,
            callbacks=RotaryCallbacks(
                on_clockwise=controller.on_left_clockwise,
                on_counterclockwise=controller.on_left_counterclockwise,
                on_click=controller.on_left_click,
            ),
        )
        self.right = RotaryEncoder(
            name="bottom",
            pins=config.bottom_encoder,
            config=config,
            callbacks=RotaryCallbacks(
                on_clockwise=controller.on_right_clockwise,
                on_counterclockwise=controller.on_right_counterclockwise,
                on_click=controller.on_right_click,
            ),
        )
        self.standby_button = None
        if config.standby_button_enabled:
            self.standby_button = StandbyButton(config, controller)
        self.volume_knob = None
        if config.ads1115_enabled:
            self.volume_knob = Ads1115VolumeKnob(config, controller)


class StandbyButton:
    POLL_SECONDS = 0.05

    def __init__(self, config: AppConfig, controller: "TvController"):
        self.config = config
        if Button is None:
            raise RuntimeError("gpiozero is required on the Raspberry Pi runtime")
        self.button = Button(
            config.standby_button_pin,
            pull_up=True,
            bounce_time=config.button_bounce,
        )
        logging.info(
            "standby button initialized: gpio=%s pressed=%s",
            config.standby_button_pin,
            self.button.is_pressed,
        )
        self._last_pressed = bool(self.button.is_pressed)
        self._pressed_at = time.monotonic() if self._last_pressed else 0.0
        self._long_press_handled = False
        self._thread = threading.Thread(
            target=self._poll,
            args=(controller,),
            name="standby-button",
            daemon=True,
        )
        self._thread.start()

    @staticmethod
    def _handle_release() -> None:
        logging.info("standby button released")

    def _poll(self, controller: "TvController") -> None:
        while True:
            pressed = bool(self.button.is_pressed)
            if pressed != self._last_pressed:
                self._last_pressed = pressed
                if pressed:
                    logging.info("standby button pressed")
                    self._pressed_at = time.monotonic()
                    self._long_press_handled = False
                else:
                    if not self._long_press_handled:
                        controller.on_standby_button()
                    self._handle_release()
            elif (
                pressed
                and not self._long_press_handled
                and time.monotonic() - self._pressed_at >= self.config.standby_button_hold_seconds
            ):
                logging.info("standby button long press")
                controller.on_standby_button_hold()
                self._long_press_handled = True
            time.sleep(self.POLL_SECONDS)


class Ads1115VolumeKnob:
    CONVERSION_REGISTER = 0x00
    CONFIG_REGISTER = 0x01
    CONFIG_AIN3_SINGLE = 0x7000
    CONFIG_PGA_4_096V = 0x0200
    CONFIG_MODE_SINGLE = 0x0100
    CONFIG_DR_128SPS = 0x0080
    CONFIG_COMP_DISABLE = 0x0003
    CONFIG_START = 0x8000

    def __init__(self, config: AppConfig, controller: "TvController"):
        self.config = config
        self.controller = controller
        self._last_pct: int | None = None
        self._raw_min = config.ads1115_raw_min
        self._raw_max = config.ads1115_raw_max
        self._last_reported_raw: int | None = None
        self._last_debug_log_at = 0.0
        self._thread = threading.Thread(target=self._run, name="ads1115-volume", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        if SMBus is None:
            logging.warning("ads1115 volume disabled: smbus module not available")
            return

        try:
            bus = SMBus(self.config.ads1115_bus)
        except OSError as exc:
            logging.warning(
                "ads1115 volume disabled: failed to open i2c bus %s (%s)",
                self.config.ads1115_bus,
                exc,
            )
            return

        logging.info(
            "ads1115 volume enabled: bus=%s addr=0x%02x channel=A%s",
            self.config.ads1115_bus,
            self.config.ads1115_address,
            self.config.ads1115_channel,
        )
        try:
            while True:
                try:
                    raw_value = self._read_single_ended(bus)
                except OSError as exc:
                    logging.warning("ads1115 read failed: %s", exc)
                    time.sleep(max(1.0, self.config.ads1115_poll_seconds))
                    continue
                self._update_raw_bounds(raw_value)
                volume_pct = self._map_volume_pct(raw_value)
                self._maybe_log_debug(raw_value, volume_pct)
                if volume_pct is not None and self._should_apply(volume_pct):
                    self.controller.set_volume_pct(volume_pct)
                    self._last_pct = volume_pct
                    logging.info("ads1115 volume set to %s%% raw=%s", volume_pct, raw_value)
                time.sleep(self.config.ads1115_poll_seconds)
        finally:
            close = getattr(bus, "close", None)
            if callable(close):
                close()

    def _read_single_ended(self, bus: SMBus) -> int:
        mux_bits = {
            0: 0x4000,
            1: 0x5000,
            2: 0x6000,
            3: self.CONFIG_AIN3_SINGLE,
        }.get(self.config.ads1115_channel, self.CONFIG_AIN3_SINGLE)
        config_word = (
            self.CONFIG_START
            | mux_bits
            | self.CONFIG_PGA_4_096V
            | self.CONFIG_MODE_SINGLE
            | self.CONFIG_DR_128SPS
            | self.CONFIG_COMP_DISABLE
        )
        bus.write_i2c_block_data(
            self.config.ads1115_address,
            self.CONFIG_REGISTER,
            [(config_word >> 8) & 0xFF, config_word & 0xFF],
        )
        time.sleep(0.01)
        data = bus.read_i2c_block_data(
            self.config.ads1115_address,
            self.CONVERSION_REGISTER,
            2,
        )
        raw_value = (data[0] << 8) | data[1]
        if raw_value & 0x8000:
            raw_value -= 0x10000
        return max(0, raw_value)

    def _should_apply(self, volume_pct: int) -> bool:
        if self._last_pct is None:
            return True
        return abs(volume_pct - self._last_pct) >= self.config.ads1115_deadband_pct

    def _maybe_log_debug(self, raw_value: int, volume_pct: int | None) -> None:
        now = time.monotonic()
        if self._last_reported_raw is None or abs(raw_value - self._last_reported_raw) >= 128:
            logging.info(
                "ads1115 sample raw=%s pct=%s range=%s..%s",
                raw_value,
                volume_pct,
                self._raw_min,
                self._raw_max,
            )
            self._last_reported_raw = raw_value
            self._last_debug_log_at = now
            return
        if now - self._last_debug_log_at >= 5.0:
            logging.info(
                "ads1115 sample raw=%s pct=%s range=%s..%s",
                raw_value,
                volume_pct,
                self._raw_min,
                self._raw_max,
            )
            self._last_debug_log_at = now

    def _update_raw_bounds(self, raw_value: int) -> None:
        if self.config.ads1115_raw_min is None:
            if self._raw_min is None or raw_value < self._raw_min:
                self._raw_min = raw_value
        if self.config.ads1115_raw_max is None:
            if self._raw_max is None or raw_value > self._raw_max:
                self._raw_max = raw_value

    def _map_volume_pct(self, raw_value: int) -> int | None:
        if self.config.ads1115_inverted:
            if raw_value >= self.config.ads1115_zero_raw_threshold:
                return 0
        elif raw_value <= self.config.ads1115_zero_raw_threshold:
            return 0
        if self._raw_min is None or self._raw_max is None:
            return None
        span = self._raw_max - self._raw_min
        if span < self.config.ads1115_min_span:
            return None
        normalized = (raw_value - self._raw_min) / span
        normalized = max(0.0, min(1.0, normalized))
        volume_pct = round(self._apply_log_curve(normalized) * 100)
        if self.config.ads1115_inverted:
            volume_pct = 100 - volume_pct
        volume_pct = max(0, min(100, volume_pct))
        if volume_pct <= self.config.ads1115_zero_threshold_pct:
            return 0
        return volume_pct

    def _apply_log_curve(self, normalized: float) -> float:
        if normalized <= 0.0:
            return 0.0
        if normalized >= 1.0:
            return 1.0
        floor_gain = math.pow(10.0, self.config.ads1115_log_floor_db / 20.0)
        curved = floor_gain * math.pow(1.0 / floor_gain, normalized)
        return (curved - floor_gain) / (1.0 - floor_gain)
