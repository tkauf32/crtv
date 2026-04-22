from __future__ import annotations

from pathlib import Path

from .models import Channel, MediaItem, Vibe

MEDIA_EXTENSIONS = {
    ".mp4",
    ".m4v",
    ".mkv",
    ".avi",
    ".mov",
    ".webm",
    ".mpg",
    ".mpeg",
}


class ContentLibrary:
    def __init__(self, vibes: list[Vibe], random_start: bool = False):
        self._vibes = vibes
        self._random_start = random_start

    @property
    def vibes(self) -> list[Vibe]:
        return self._vibes

    def channel_items(self, vibe_index: int, channel_index: int) -> list[MediaItem]:
        channel = self._vibes[vibe_index].channels[channel_index]
        return self._collect_channel_items(channel)

    def clip_count(self, vibe_index: int, channel_index: int) -> int:
        return len(self.channel_items(vibe_index, channel_index))

    def vibe_count(self) -> int:
        return len(self._vibes)

    def channel_count(self, vibe_index: int) -> int:
        return len(self._vibes[vibe_index].channels)

    def _collect_channel_items(self, channel: Channel) -> list[MediaItem]:
        items: list[MediaItem] = []
        seen: set[str] = set()
        for source in channel.paths:
            if source.startswith(("http://", "https://", "file://")):
                if source not in seen:
                    items.append(MediaItem(path=source))
                    seen.add(source)
                continue

            path = Path(source)
            if path.is_file():
                resolved = str(path)
                if resolved not in seen:
                    items.append(MediaItem(path=resolved))
                    seen.add(resolved)
                continue

            if not path.is_dir():
                continue

            for child in sorted(path.rglob("*")):
                if not child.is_file() or child.suffix.lower() not in MEDIA_EXTENSIONS:
                    continue
                resolved = str(child.resolve())
                if resolved in seen:
                    continue
                items.append(MediaItem(path=resolved))
                seen.add(resolved)
        return items
