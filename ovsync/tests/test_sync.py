import hashlib
import json
import struct
import uuid
from pathlib import Path
from xml.etree import ElementTree as ET

from ovsync.library import ZIM_MAGIC

from conftest import CORE_KEY, FIXTURE_OUT, manifest_payload, ovsync, sign

ZIM = "zim/fieldguide_en_2026-10.zim"
OLD_ZIM = "zim/fieldguide_en_2026-09.zim"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def header_uuid(path: Path) -> str:
    head = path.read_bytes()[:24]
    assert struct.unpack("<I", head[:4])[0] == ZIM_MAGIC
    return str(uuid.UUID(bytes=head[8:24]))


def books(folder: Path) -> dict[str, dict]:
    tree = ET.parse(folder / "library.xml")
    return {b.get("path"): b.attrib for b in tree.getroot().findall("book")}


def activated(server, config_dir):
    server.serve(version=2)
    result = ovsync("activate", CORE_KEY, origin=server.origin)
    assert result.returncode == 0, result.stderr


def test_sync_downloads_verifies_and_writes_library_xml(server, config_dir, tmp_path):
    activated(server, config_dir)
    folder = tmp_path / "vault"
    result = ovsync("sync", str(folder), origin=server.origin)
    assert result.returncode == 0, result.stderr
    expected = {a["path"]: a["sha256"] for a in manifest_payload(2)["artefacts"]}
    assert sha256(folder / ZIM) == expected[ZIM]
    assert not list(folder.rglob("*.part"))
    listed = books(folder)
    assert set(listed) == {ZIM}
    assert listed[ZIM]["id"] == header_uuid(folder / ZIM)
    assert listed[ZIM]["title"] == "Field Guide (fixture, Nov)"
    assert listed[ZIM]["language"] == "eng"
    assert "CC-BY-SA-4.0" in listed[ZIM]["tags"]
    assert (folder / "catalogue").is_dir()
    assert not (folder / "models").exists() and not (folder / "maps").exists()


def test_rerun_skips_complete_files(server, config_dir, tmp_path):
    activated(server, config_dir)
    folder = tmp_path / "vault"
    assert ovsync("sync", str(folder), origin=server.origin).returncode == 0
    before = (folder / ZIM).stat().st_mtime_ns
    result = ovsync("sync", str(folder), origin=server.origin)
    assert result.returncode == 0
    assert "0 downloaded" in result.stdout
    assert (folder / ZIM).stat().st_mtime_ns == before
    assert len(server.requests("/updates/" + ZIM)) == 1


def test_interrupted_download_resumes_from_the_part_file(server, config_dir, tmp_path):
    activated(server, config_dir)
    folder = tmp_path / "vault"
    part = folder / (ZIM + ".part")
    part.parent.mkdir(parents=True)
    part.write_bytes((FIXTURE_OUT / ZIM).read_bytes()[: 1 << 20])
    result = ovsync("sync", str(folder), origin=server.origin)
    assert result.returncode == 0, result.stderr
    assert sha256(folder / ZIM) == sha256(FIXTURE_OUT / ZIM)
    assert not part.exists()
    assert [status for _, _, status in server.requests("/updates/" + ZIM)] == ["206"]


def test_corrupt_part_file_is_discarded_and_fetched_again(server, config_dir, tmp_path):
    activated(server, config_dir)
    folder = tmp_path / "vault"
    part = folder / (ZIM + ".part")
    part.parent.mkdir(parents=True)
    part.write_bytes(b"\xff" * (1 << 20))
    result = ovsync("sync", str(folder), origin=server.origin)
    assert result.returncode == 0, result.stderr
    assert sha256(folder / ZIM) == sha256(FIXTURE_OUT / ZIM)
    assert [status for _, _, status in server.requests("/updates/" + ZIM)] == ["206", "200"]


def test_newer_edition_replaces_the_old_file(server, config_dir, tmp_path):
    server.serve(version=1)
    assert ovsync("activate", CORE_KEY, origin=server.origin).returncode == 0
    folder = tmp_path / "vault"
    assert ovsync("sync", str(folder), origin=server.origin).returncode == 0
    assert (folder / OLD_ZIM).exists() and set(books(folder)) == {OLD_ZIM}
    server.serve(version=2)
    result = ovsync("sync", str(folder), origin=server.origin)
    assert result.returncode == 0, result.stderr
    assert not (folder / OLD_ZIM).exists()
    assert (folder / ZIM).exists()
    assert set(books(folder)) == {ZIM}
    assert "rm   fieldguide_en_2026-09.zim" in result.stdout
    assert [p.name for p in (folder / "catalogue").iterdir()] == ["catalogue-2026.10.08.json"]


def test_only_and_include_select_artefacts(server, config_dir, tmp_path):
    activated(server, config_dir)
    folder = tmp_path / "vault"
    result = ovsync("sync", str(folder), "--only", "map-firenze", origin=server.origin)
    assert result.returncode == 0, result.stderr
    assert (folder / "maps" / "firenze.pmtiles").exists() and not (folder / ZIM).exists()
    result = ovsync("sync", str(folder), "--only", "nope", origin=server.origin)
    assert result.returncode == 1 and "not in the catalogue: nope" in result.stderr
    result = ovsync("sync", str(folder), "--include", "maps", origin=server.origin)
    assert result.returncode == 0, result.stderr
    assert (folder / "maps" / "world-overview.pmtiles").exists() and (folder / ZIM).exists()


def test_verify_reports_a_corrupted_file(server, config_dir, tmp_path):
    activated(server, config_dir)
    folder = tmp_path / "vault"
    assert ovsync("sync", str(folder), origin=server.origin).returncode == 0
    assert ovsync("verify", str(folder)).returncode == 0
    with open(folder / ZIM, "r+b") as f:
        f.seek(100)
        f.write(b"\x00\x01")
    result = ovsync("verify", str(folder))
    assert result.returncode == 3
    assert "BAD      zim-fieldguide-2026-10" in result.stdout
    repair = ovsync("sync", str(folder), origin=server.origin)
    assert repair.returncode == 0 and "get  zim-fieldguide-2026-10" in repair.stdout
    assert ovsync("verify", str(folder)).returncode == 0
    assert sha256(folder / ZIM) == sha256(FIXTURE_OUT / ZIM)


def test_network_failure_exits_4_and_keeps_nothing_half_written(config_dir, tmp_path):
    result = ovsync("sync", str(tmp_path / "vault"), origin="http://127.0.0.1:9")
    assert result.returncode == 4
    assert "connection failed" in result.stderr
    assert not (tmp_path / "vault").exists()


def with_external_book(server, dev_private_key) -> bytes:
    """Manifest v2 plus a book served by "Kiwix": this server, under a path the catalogue never uses."""
    payload = manifest_payload(2)
    old = next(a for a in manifest_payload(1)["artefacts"] if a["id"] == "zim-fieldguide-2026-09")
    payload["artefacts"].append({
        "id": "zim-kiwix-fixture", "kind": "zim", "path": "zim/kiwix-fixture_en.zim", "sizeBytes": old["sizeBytes"], "sha256": old["sha256"],
        "minAppVersion": "1.0.0", "tier": "free", "title": "Fixture book from Kiwix",
        "external": {"url": f"{server.origin}/updates/{old['path']}", "shaSource": "kiwix-meta4", "licence": "CC BY-NC-SA 3.0", "attribution": "fixtures; ZIM by Kiwix"}})
    return sign(json.dumps(payload).encode(), dev_private_key)


def test_external_books_are_listed_as_from_kiwix_and_synced_only_on_request(server, config_dir, tmp_path, dev_private_key):
    server.serve(manifest=with_external_book(server, dev_private_key))
    assert ovsync("activate", CORE_KEY, origin=server.origin).returncode == 0
    listing = ovsync("list", origin=server.origin)
    assert listing.returncode == 0, listing.stderr
    row = next(l for l in listing.stdout.splitlines() if "zim-kiwix-fixture" in l)
    assert "[from Kiwix, not verified by OfflineVault]" in row and "--include external" in listing.stdout
    assert "from Kiwix" not in next(l for l in listing.stdout.splitlines() if "zim-fieldguide-2026-10" in l)

    folder = tmp_path / "vault"
    result = ovsync("sync", str(folder), origin=server.origin)
    assert result.returncode == 0, result.stderr
    assert not (folder / "zim/kiwix-fixture_en.zim").exists() and "zim-kiwix-fixture" not in result.stdout
    result = ovsync("sync", str(folder), "--include", "external", origin=server.origin)
    assert result.returncode == 0, result.stderr
    assert "get  zim-kiwix-fixture" in result.stdout and "from Kiwix" in result.stdout
    assert sha256(folder / "zim/kiwix-fixture_en.zim") == sha256(FIXTURE_OUT / OLD_ZIM)
    assert [p for _, p, _ in server.requests("/updates/" + OLD_ZIM)] == ["/updates/" + OLD_ZIM], "the bytes came from the external URL, not the catalogue path"
    listed = books(folder)
    assert listed["zim/kiwix-fixture_en.zim"]["publisher"] == "Kiwix" and listed[ZIM]["publisher"] == "OfflineVault"
    assert ovsync("verify", str(folder)).returncode == 0
    assert ovsync("sync", str(folder), "--include", "nope", origin=server.origin).returncode == 1
