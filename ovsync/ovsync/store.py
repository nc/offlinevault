from __future__ import annotations

import json
import os
import sys
import uuid
from dataclasses import dataclass, field
from pathlib import Path


def config_dir() -> Path:
    env = os.environ.get("OVSYNC_CONFIG_DIR")
    if env:
        return Path(env)
    if sys.platform == "win32":
        return Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming")) / "ovsync"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "ovsync"
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "ovsync"


@dataclass
class State:
    device_id: str
    key: str | None = None
    licence: dict | None = None
    newest_published_at: dict[str, str] = field(default_factory=dict)

    @classmethod
    def load(cls, directory: Path) -> "State":
        path = directory / "state.json"
        if not path.exists():
            state = cls(device_id=str(uuid.uuid4()))
            state.save(directory)
            return state
        obj = json.loads(path.read_text())
        return cls(device_id=obj["deviceId"], key=obj.get("key"), licence=obj.get("licence"),
                   newest_published_at=obj.get("newestPublishedAt") or {})

    def save(self, directory: Path) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        write_atomic(directory / "state.json", json.dumps(
            {"deviceId": self.device_id, "key": self.key, "licence": self.licence, "newestPublishedAt": self.newest_published_at}, indent=2) + "\n")


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)
