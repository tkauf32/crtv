from __future__ import annotations

import argparse
import logging
import signal
import sys
import time
from pathlib import Path

from .config import load_config, load_vibes
from .controller import TvController
from .input import InputRouter
from .library import ContentLibrary
from .player import MpvPlayer
from .power import PowerManager


def configure_logging(log_file: Path) -> None:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[
            logging.FileHandler(log_file, encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="crtv service")
    parser.add_argument(
        "--headless",
        action="store_true",
        help="Run without GPIO input for development/debugging.",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Initialize playback and exit. Useful for smoke tests.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    repo_root = Path(__file__).resolve().parent.parent
    config = load_config(repo_root)
    configure_logging(config.log_file)
    vibes = load_vibes(config)
    if not vibes:
        raise RuntimeError(f"No playable vibes in {config.channels_file}")

    library = ContentLibrary(vibes=vibes, random_start=config.auto_random_start)
    player = MpvPlayer(config)
    power = PowerManager(config)
    controller = TvController(config, library, player, power)
    controller.start()
    logging.info("crtv service started: %s", controller.state.status_line)
    logging.info("battery integration: %s", power.battery_status())

    if not args.headless:
        InputRouter(config, controller)

    if args.once:
        return 0

    stop = False

    def handle_stop(signum: int, _frame: object) -> None:
        nonlocal stop
        stop = True
        logging.info("signal=%s stopping", signum)

    signal.signal(signal.SIGINT, handle_stop)
    signal.signal(signal.SIGTERM, handle_stop)

    while not stop:
        time.sleep(1.0)

    player.terminate()
    logging.info("crtv service stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
