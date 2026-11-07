import subprocess
from pathlib import Path

from ovpub.builders import zimit as zb


def test_zimit_command_uses_iso639_1_for_the_browser_and_iso639_3_for_the_zim(monkeypatch, tmp_path):
    """browsertrix exits fatally (code 17) on --lang eng; the ZIM metadata still wants eng."""
    seen = {}

    def fake_run(cmd, check):
        seen["cmd"] = cmd
        out_dir = Path(cmd[cmd.index("-v") + 1].split(":")[0])
        (out_dir / cmd[cmd.index("--zim-file") + 1]).write_bytes(b"zim")

    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.setattr(zb.shutil, "which", lambda name: "/usr/bin/docker")
    entry = type("E", (), {})()
    entry.source = zb.ZimitSource(seeds=("https://example.com/",), name="probe_en", scope="https://example.com/")
    entry.title = "Probe"; entry.description = "Probe"; entry.licence = next(iter(zb.LICENCES))
    cand = type("C", (), {"entry": entry, "edition": None})()
    monkeypatch.setattr(zb, "crawl_month", lambda c: "2026-10")
    ctx = type("X", (), {"content": tmp_path, "log": lambda self, m: None})()
    out = zb.ZimitBuilder().build(cand, ctx)
    cmd = seen["cmd"]
    assert out.name == "probe_en_2026-10.zim"
    assert cmd[cmd.index("--lang") + 1] == "en"
    assert cmd[cmd.index("--zim-lang") + 1] == "eng"
    assert cmd[cmd.index("--scopeType") + 1] == "prefix" and "--include" not in cmd
    assert cmd[cmd.index("--pageLimit") + 1] == str(zb.PAGE_LIMIT)
