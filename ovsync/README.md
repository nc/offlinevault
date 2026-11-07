# ovsync

A command-line tool that downloads the signed OfflineVault catalogue into a folder that Kiwix can serve. It runs on
Linux, Windows and macOS and needs no OfflineVault app. The folder it writes works with `kiwix-serve`,
`kiwix-desktop` and the Kiwix apps on a phone pointed at a shared drive.

## Install

Python 3.10 or newer and [pipx](https://pipx.pypa.io). From a checkout of this repository:

```
pipx install ./ovsync
```

`pip install ./ovsync` also works inside a virtual environment. The only dependencies are `requests` and
`cryptography`.

## Commands

| Command | What it does | Exit codes |
|---|---|---|
| `ovsync activate OV-XXXX-XXXX-XXXX-XXXX` | Registers this computer against your key, stores the signed licence, prints the plan, seats and expiry. | 0, 2 (key not recognised, seats full, plan ended), 3 (licence not trusted), 4 |
| `ovsync deactivate` | Frees this computer's seat and forgets the key. | 0, 4 |
| `ovsync status` | Shows the stored licence, the tiers it covers and the device id. | 0, 2 (stored licence no longer verifies) |
| `ovsync list [--tier TIER]` | Verifies the catalogue and lists every artefact by tier with its size. A `*` marks the ones your licence covers. | 0, 3, 4 |
| `ovsync sync DIR [--tier TIER] [--only ID ...] [--include models,maps,external]` | Downloads into `DIR` and writes `DIR/library.xml`. | 0, 2, 3, 4 |
| `ovsync verify DIR` | Rehashes every downloaded file and forgets any that fail, so the next `sync` fetches them again. | 0, 3 |

Exit code 0 is success, 1 a usage error, 2 a licence problem, 3 a verification failure, 4 a network failure. Every
error is one line on stderr starting with `ovsync:`.

`sync` downloads ZIM files by default. `--include models` adds the GGUF language models and `--include maps` the
PMTiles maps; `--include models,maps` adds both. `--include external` adds the books the catalogue offers from
Kiwix's own servers (iFixit, MedlinePlus): their licences do not let OfflineVault redistribute them, so `list` marks
them "from Kiwix, not verified by OfflineVault", the bytes come from download.kiwix.org, and ovsync checks them
against the sha256 Kiwix publishes, which the signed catalogue repeats. `--only` names artefact ids from
`ovsync list` and ignores `--tier` and `--include`. `--tier` is the highest tier to download and defaults to `core`; the tiers, cheapest first, are
`free`, `core`, `full` and `complete`.

`sync` is safe to interrupt and rerun. A file in progress is `name.part`; the next run resumes it with an HTTP
Range request, verifies the whole file, and only then renames it into place. A rerun skips every complete file,
removes an edition the catalogue says is replaced, and rewrites `library.xml`. To repeat the download of one file,
delete it and rerun `sync`.

A key is needed for every tier above `free`. Without one, `ovsync sync DIR --tier free` downloads whatever the
catalogue marks free.

## Serve the folder with Kiwix

```
ovsync activate OV-XXXX-XXXX-XXXX-XXXX
ovsync sync ~/offlinevault
kiwix-serve --port 8080 --library ~/offlinevault/library.xml
```

Open `http://localhost:8080/`. In kiwix-desktop, choose File, Open library, and pick `library.xml`. Paths in
`library.xml` are relative, so the whole folder can move to a USB drive or a NAS and the library file still works.

To refresh later, run `ovsync sync ~/offlinevault` again. Only new or changed files download.

## Windows

Install Python from python.org or the Microsoft Store with "Add python to PATH" ticked, then in PowerShell:

```
py -m pip install --user pipx
py -m pipx ensurepath
pipx install .\ovsync
```

Run the last line from the repository checkout. Open a new PowerShell window so `ovsync` is on the path. Folder
arguments take Windows paths:

```
ovsync sync D:\offlinevault
kiwix-serve.exe --port 8080 --library D:\offlinevault\library.xml
```

The licence and device id are stored under `%APPDATA%\ovsync\state.json`. On Linux it is
`~/.config/ovsync/state.json` and on macOS `~/Library/Application Support/ovsync/state.json`. Set
`OVSYNC_CONFIG_DIR` to put it elsewhere.

## What "verified" means

`manifest.json` is a signed envelope. OfflineVault signs the catalogue bytes with an Ed25519 key whose public half
is embedded in ovsync under the key id `content-2026-10`. `list` and `sync` accept a catalogue only when its
signature verifies under that key, and refuse one with an older publish date than the newest already accepted from
the same origin, so a replayed old catalogue cannot roll a folder back. Every artefact then carries a SHA-256 in
that signed catalogue, and a download is kept only when its hash matches. `ovsync verify` recomputes the hashes.
The licence the issuer returns is signed the same way with a separate key (`prod-2026-10`), so a stored licence
that was altered counts as no licence.

ovsync sends no telemetry. The only requests it makes are to fetch the catalogue and artefacts and, for
`activate` and `deactivate`, to the licence API.

## Mirrors and development

`--origin URL` points every command at another service with the same layout: the catalogue under `/updates/` and
the licence API under `/api/licence/`. `OVSYNC_ORIGIN` sets the default. A mirror signed with another key is
trusted by adding it to `OVSYNC_CATALOGUE_KEYS` as `id=base64`, comma separated; `OVSYNC_LICENCE_KEYS` does the
same for licences.

The repository's fixture server (`scripts/fixture_server.py`) serves a catalogue signed with the committed dev key.
The tests under `tests/` start it on a free port with a root laid out like production and run every command
against it:

```
scripts/make_fixture_server.sh --mock-model      # once, builds fixture/out
pip install -e ovsync
python -m pytest ovsync/tests                   # OV_FIXTURE_OUT=/path/to/fixture/out if it lives elsewhere
```

## Licence

ovsync is free software under the GNU General Public License, version 3 or later. See `LICENSE` at the root of the
repository. The content it downloads carries its own licences, listed per entry in the catalogue file under
`DIR/catalogue/` and in the `tags` attribute of each book in `library.xml`.
