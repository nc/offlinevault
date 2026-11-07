import json

from conftest import CORE_KEY, manifest_payload, ovsync, sign

HOUSEHOLD_KEY = "OV-DEVH-2222-2222-2222"
FULL_SEATS_KEY = "OV-DEVS-2222-2222-2222"


def test_activate_then_deactivate_round_trip(server, config_dir):
    server.serve()
    before = ovsync("status")
    assert "Licence: none" in before.stdout
    device_id = next(line.split()[-1] for line in before.stdout.splitlines() if line.startswith("Device id"))

    result = ovsync("activate", "ov devc 2222 2222 2222", origin=server.origin)
    assert result.returncode == 0, result.stderr
    assert "Core plan for Core Subscriber" in result.stdout and "1 of 2 in use" in result.stdout
    state = json.loads((config_dir / "state.json").read_text())
    assert state["key"] == CORE_KEY and state["deviceId"] == device_id
    assert state["licence"]["format"] == "offlinevault-licence/2"
    assert "Core plan" in ovsync("status").stdout

    result = ovsync("deactivate", origin=server.origin)
    assert result.returncode == 0 and "0 of 2" in result.stdout
    after = ovsync("status")
    assert "Licence: none" in after.stdout and device_id in after.stdout
    assert server.requests("/api/licence/") == [("POST", "/api/licence/activate", "200"), ("POST", "/api/licence/deactivate", "200")]


def test_bad_keys_exit_2(server, config_dir):
    server.serve()
    assert ovsync("activate", "OV-1111-0000-OOOO-IIII", origin=server.origin).returncode == 2
    unknown = ovsync("activate", "OV-ZZZZ-2222-2222-2222", origin=server.origin)
    assert unknown.returncode == 2 and "not recognised" in unknown.stderr
    full = ovsync("activate", FULL_SEATS_KEY, origin=server.origin)
    assert full.returncode == 2 and "seats are in use" in full.stderr and "Kitchen Mac mini" in full.stderr
    assert "Licence: none" in ovsync("status").stdout


def test_tampered_stored_licence_counts_as_none(server, config_dir):
    server.serve()
    assert ovsync("activate", CORE_KEY, origin=server.origin).returncode == 0
    path = config_dir / "state.json"
    state = json.loads(path.read_text())
    state["licence"]["payload"] = state["licence"]["payload"][:-4] + "AAAA"
    path.write_text(json.dumps(state))
    assert ovsync("status").returncode == 2
    assert ovsync("list", origin=server.origin).stdout.splitlines()[1].startswith("Licence: none")


def test_core_key_cannot_sync_a_higher_tier(server, config_dir, tmp_path):
    server.serve()
    assert ovsync("activate", CORE_KEY, origin=server.origin).returncode == 0
    folder = tmp_path / "vault"
    for args in (["--tier", "full"], ["--only", "zim-fieldguide-full"]):
        result = ovsync("sync", str(folder), *args, origin=server.origin)
        assert result.returncode == 2, result.stdout
        assert "'zim-fieldguide-full' is in tier 'full'" in result.stderr
    assert not folder.exists()
    assert ovsync("activate", HOUSEHOLD_KEY, origin=server.origin).returncode == 0
    result = ovsync("sync", str(folder), "--tier", "full", origin=server.origin)
    assert result.returncode == 0, result.stderr


def test_no_key_syncs_free_content_only(server, config_dir, tmp_path, dev_private_key):
    payload = manifest_payload(2)
    for a in payload["artefacts"]:
        if a["id"] == "zim-fieldguide-2026-10":
            a["tier"] = "free"
    server.serve(manifest=sign(json.dumps(payload).encode(), dev_private_key))
    folder = tmp_path / "vault"
    result = ovsync("sync", str(folder), "--tier", "free", origin=server.origin)
    assert result.returncode == 0, result.stderr
    assert (folder / "zim" / "fieldguide_en_2026-10.zim").exists()
    result = ovsync("sync", str(folder), origin=server.origin)
    assert result.returncode == 2 and "your licence covers free" in result.stderr
    assert "* zim-fieldguide-2026-10" in ovsync("list", origin=server.origin).stdout


def test_without_any_free_content_a_key_is_needed(server, config_dir, tmp_path):
    server.serve()
    result = ovsync("sync", str(tmp_path / "vault"), origin=server.origin)
    assert result.returncode == 2 and "ovsync activate" in result.stderr
