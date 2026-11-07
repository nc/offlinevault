# OfflineVault

A macOS (Apple Silicon, macOS 14+) client for a subscription offline-knowledge service. It downloads content packs
from a Cloudflare-hosted update service, keeps a local library (Kiwix ZIM reference books, cached videos, captured
webpages), indexes everything with SQLite FTS5, and lets you chat with a local LLM that answers **from the library
with tappable citations**. After setup every core feature works in airplane mode.

```
Chat ──▶ RetrievalCoordinator ──▶ kiwix-serve search  (ZIM full text; field manuals boosted on safety questions)
   │                         ├──▶ FTS5 PDF pages       (document packs: FEMA, Army FMs, USDA … cited by page)
   │                         ├──▶ FTS5 page chunks     (captured webpages)
   │                         └──▶ FTS5 transcripts     (video subtitles, with timestamps)
   └──▶ llama-server (OpenAI-compatible, localhost) ──▶ streamed answer with [n] citations
```

Network is used only for (a) manifest checks and artefact downloads from the update service and (b) fetching the
videos and webpages the user adds themselves.

---

## ovsync: the catalogue without the app

[`ovsync/`](ovsync/README.md) is a GPL command-line tool for Linux, Windows and macOS that activates a licence
key, verifies the signed catalogue, and downloads it into a folder with a `library.xml` that `kiwix-serve` and
kiwix-desktop open directly. `pipx install ./ovsync`, then `ovsync activate OV-...` and `ovsync sync DIR`.

---

## Quick start (development, no Cloudflare account needed)

```bash
# 1. helper binaries → OfflineVault/Resources/bin (git-ignored). kiwix-tools has no arm64 build, see below.
scripts/fetch_binaries.sh --allow-rosetta

# 2. build the local fixture "update service" (original CC0 ZIM, small GGUF model, test video pack, page pack)
scripts/make_fixture_server.sh            # add --mock-model to skip the 400 MB model download

# 3. serve it (keep running). --version 2 later serves a changed manifest to demo an update;
#    manifests are signed with the dev key, --unsigned serves the plain file (the app refuses it on 8787).
scripts/make_fixture_server.sh --serve --version 1

# 4. generate the Xcode project and build / run
brew install xcodegen            # if needed
xcodegen generate
open OfflineVault.xcodeproj      # scheme "OfflineVault"; tick the --use-fixture-server argument, Run
# or from the terminal:
xcodebuild -project OfflineVault.xcodeproj -scheme OfflineVault -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/OfflineVault.app --args --use-fixture-server
```

First run: choose a library folder → (optionally) activate `OV-DEVC-2222-2222-2222` against the fixture server or import `fixture/dev-licence-core.json` → **Check base pack** →
**Download** → **Finish**. Then restart the fixture server with `--version 2` and use *Library › Check for Updates…*
(⇧⌘U) to apply the changed manifest: the September ZIM is replaced by the November one and a page pack is added.

### Tests

```bash
cd Core
swift test                                   # 47 unit tests, no network, no helpers needed (~1 s)

# end-to-end against the real helpers + fixture server (starts its own server on :8799):
OV_INTEGRATION=1 OFFLINEVAULT_BIN_DIR=$PWD/../OfflineVault/Resources/bin swift test --filter FixtureIntegrationTests
#   • first-run base pack → verify → install → changed manifest applies (replace + add + skip incompatible)
#   • kiwix-serve catalogue + full-text search + article text
#   • llama-server chat with retrieved sources → answer cites [n] → citation opens the article
#   • interrupted artefact download resumes from the .part file and passes checksum
#   • webpage capture renders offline (CSP, inlined assets, no scripts) and is searchable; refresh keeps old copy
OV_YOUTUBE_E2E=1 OV_INTEGRATION=1 OFFLINEVAULT_BIN_DIR=... swift test --filter testYouTubeIndexAndDownload   # hits YouTube
```

`OV_LIBRARY_DIR=/path` makes the integration test write into a persistent library you can then point the app at
(`defaults write com.offlinevault.app libraryPath -string /path; defaults write com.offlinevault.app setupCompleted -bool true`).

---

## Repository layout

```
Core/                         Swift package "OfflineVaultCore" — all logic, testable with `swift test`
  Sources/OfflineVaultCore/
    Config.swift              UPDATES_BASE_URL, licence service URL and public keys, ports, model ids
    LibraryLayout.swift       library folder layout, storage report, free-space guard
    Database/                 SQLite wrapper (system libsqlite3, FTS5), IndexDatabase schema
    Updates/                  Manifest + diff, Checksum, ResumableDownload (HTTP ranges), UpdateService (atomic install), Catalogue
    Entitlement/              Plan/Grant table, Ed25519 licence verification, Entitlements gate, EntitlementService, activation client
    Process/                  HelperBinaries locator, ManagedProcess (health check, restart), ProcessSupervisor (no orphans), ProcessRunner
    Reference/                ReferenceLibraryService protocol + KiwixServeService (OPDS + search XML parsers)
    LLM/                      LlamaServerService, OpenAI-compatible SSE client, Retrieval (3 retrievers + fusion), Prompting, ChatStore
    YouTube/                  YtDlpCommand builder, YtDlpInfo JSON model, progress parser, size estimator, SubtitleParser, YouTubeService
    Video/                    VideoLibraryService (catalogue, sidecars, transcript FTS, playback positions, thumbnails)
    Pages/                    HTMLTokenizer, HTMLText extraction/chunking, PageArchiver (single-file capture), PageService
    Downloads/                DownloadManager (queue, pause/resume/retry, concurrency)
    Settings/                 AppSettings (UserDefaults)
  Sources/licencetool/        CLI: keygen / sign / verify / canon / sign-envelope / fixtures
  Sources/catalogtool/        CLI: verify a signed catalogue from a file or through the origin
  Tests/OfflineVaultCoreTests/  unit tests + Fixtures/ (recorded yt-dlp JSON, sample page, VTT, manifests, licences)
OfflineVault/                 SwiftUI app target (AppModel, ChatController, Views/, WebView, Info.plist, entitlements)
  Resources/bin/              helper binaries (git-ignored; populated by scripts/fetch_binaries.sh)
scripts/                      fetch_binaries.sh, make_fixture_server.sh, fixture_server.py, dev-keys/ (fixture Field Guide comes from scripts/content/fieldguide.py)
fixture/                      dev-licence-*.json per plan (+ generated out/ and cache/, git-ignored)
project.yml                   xcodegen spec → OfflineVault.xcodeproj
```

The app target is thin: `AppModel` owns the services and helper processes, `ChatController` runs retrieval →
prompt → streaming, and each sidebar screen is one SwiftUI file. Everything the UI calls is in the Core package.

---

## Library layout

The user picks the folder at first run (internal drive or external SSD). A `.offlinevault-library` marker lets the
app recognise an existing library.

```
Library/
  zim/        Kiwix ZIM files
  videos/     <id>.mp4, <id>.json sidecar, <id>.<lang>.vtt subtitles, <id>.jpg thumbnail, .yt-dlp-archive.txt
  pages/      <id>.html self-contained capture, <id>.json metadata (id = sha256(url)[0:16])
  documents/  <name>.pdf|.epub|.txt + <name>.json sidecar (title, publisher, licence, role, subject); indexed per page/chapter
  maps/       <region>.pmtiles offline map regions (OpenStreetMap data via Protomaps)
  models/     GGUF files
  index/      library.sqlite (catalogue, FTS5 indexes, chat history), catalogue.json, licence.json, licence-activation.json
  staging/    *.part downloads + .state.json; extraction and parked-previous-file scratch; never served from
```

*Settings › Storage* shows usage per category, volume free space, installed artefacts (with uninstall) and a
staging clean-up. Downloads refuse to start when they would leave less than 2 GB free.

---

## Update service (Cloudflare R2) and the updater

The service is a static HTTPS host. Put the files in an R2 bucket behind a custom domain (public bucket or a Worker
that proxies `GET`/`HEAD` with `Range` support — R2 supports range requests natively, which the resumable
downloader relies on). Nothing else is required server-side.

```
<base>/manifest.json
<base>/catalogue/catalogue-2026.10.08.json    (artefact of kind "catalogue", installed as index/catalogue.json)
<base>/zim/wikipedia_en_medicine_2026-09.zim  (kind "zim")
<base>/models/Qwen3-4B-Q4_K_M.gguf            (kind "model")
<base>/packs/<name>.tar.gz                    (kinds "video-pack" / "page-pack" / "document-pack": tar/zip extracted into videos/, pages/ or documents/)
```

`Config.UPDATES_BASE_URL` is the worker's `/updates/` route (`https://offlinevault.dev/updates/`),
which streams the R2 bucket with Range support. Change it there, or override without rebuilding via the
`OFFLINEVAULT_UPDATES_URL` environment variable, the `updatesBaseURL` user default (*Settings › General › Service URL
override*), or `--use-fixture-server` (→ `http://127.0.0.1:8787/`, which the app treats as the official service).

### Signed manifest and the trust badge

`manifest.json` is served as a signed envelope, the same wire shape as a licence file:

```json
{ "format": "offlinevault-manifest/1", "keyId": "content-2026-10",
  "payload": "<base64 of the manifest JSON exactly as the publisher wrote it>", "signature": "<base64 Ed25519>" }
```

The client verifies the payload bytes under `Config.cataloguePublicKeys` (a separate table from the licence keys, so
the content key can never mint a licence) and only then runs `Manifest.parse` on them; nothing is re-encoded, so
there is no canonical-bytes contract for manifests. `ManifestVerifier.open` is the whole policy:

| source | body | signature | result |
|---|---|---|---|
| OfflineVault service | envelope | trusted key | **Verified OfflineVault catalogue** |
| OfflineVault service | envelope | untrusted key, bad signature or base64 | error, naming the key when it is unknown ("update OfflineVault") |
| OfflineVault service | plain JSON | none | error "Unsigned catalogue from the OfflineVault service" |
| self-hosted URL | envelope | trusted key | **Verified OfflineVault catalogue** · via host (a mirror) |
| self-hosted URL | envelope | invalid | error; a signed-looking file is never silently downgraded |
| self-hosted URL | plain JSON | none | **Unverified source** · host; bring-your-own content stays ungated |

`UpdateSource` and the plan gate are unchanged: gating is by host, trust is by signature. The updates sheet header
and the Library footer render the same `CatalogueBadge`. A verified manifest older than the newest one this Mac has
accepted (`AppSettings.lastVerifiedPublishedAt`) is rejected as a replay, so an operator rollback is republished
with a fresh `publishedAt`. DEBUG builds also trust the committed dev key (`scripts/dev-keys`, key id `dev-2026`),
which signs the fixture manifests; release builds trust only `content-2026-10`.

```bash
swift run catalogtool verify --file publish/manifest.json --expect publish/manifest.plain.json      # before upload
swift run catalogtool verify --base https://offlinevault.dev/updates/ --range-probe  # after upload
swift run catalogtool verify --base http://127.0.0.1:8787/                                           # the fixture
```

`verify` opens the envelope with the app's own keyring (`--pubkey ID=FILE` adds one), parses with `Manifest.parse`,
HEADs every artefact for `Content-Length` and `X-OfflineVault-SHA256`, and with `--range-probe` fetches the first and
last MiB. It exits non-zero on any mismatch or when the catalogue is not verified.

### `manifest.json` schema

```json
{
  "version": "2026.10.08",
  "publishedAt": "2026-10-08T12:00:00Z",
  "catalogueVersion": "2",
  "artefacts": [
    {
      "id": "zim-wikipedia-medicine-2026-10",
      "kind": "zim",                          // zim | video-pack | model | page-pack | document-pack | map | catalogue
      "path": "zim/wikipedia_en_medicine_2026-10.zim",
      "sizeBytes": 2097152000,
      "sha256": "…64 hex chars…",
      "minAppVersion": "1.0.0",               // semver; artefacts above the app version are listed but skipped
      "replaces": ["zim-wikipedia-medicine-2026-09"],  // optional, newest first: installing removes the first of these that is installed
      "title": "Wikipedia – Medicine (Oct 2026)",        // optional, shown in the update screen
      "summary": "Monthly refresh.",                      // optional
      "tier": "full"                                      // optional: free | core (default) | full | complete
    },
    {
      "id": "zim-ifixit-2025-12", "kind": "zim", "path": "zim/ifixit_en_all_2025-12.zim",   // path is only the local file name here
      "sizeBytes": 3570695757, "sha256": "…the sha256 Kiwix publishes…", "minAppVersion": "1.0.0", "tier": "free",
      "external": {                           // optional: the bytes live on Kiwix's servers, never on OfflineVault's
        "url": "https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim",
        "shaSource": "kiwix-meta4", "licence": "CC BY-NC-SA 3.0", "attribution": "iFixit contributors; ZIM by Kiwix"
      }
    }
  ]
}
```

- `version`, `publishedAt` (ISO-8601), `artefacts[]`, `catalogueVersion` are required. `id`s must be unique;
  `sha256` is lower/upper-case hex of the whole file; `path` is relative to the base URL (no `..`, no leading `/`).
- **Diffing** (`ManifestDiff.compute`, unit-tested): an artefact is downloaded when its `id` is not installed or its
  checksum differs; `replaces` lists every retired edition (the publisher writes the lock history, so a client that
  skipped a month still has its old edition removed). Installed artefacts missing from the manifest are reported as
  orphans but never deleted automatically.
- **ZIMs are full-file replacements** — no binary deltas. Publish the new file under a new `id` with `replaces`.
- **External artefacts** (`external` present; spec source kind `kiwix_external`) are books whose licence forbids
  OfflineVault redistributing them (iFixit, MedlinePlus). The app downloads them from `external.url` with the same
  resumable downloader, checks the sha256 the publisher copied from Kiwix's `.meta4`, and shows them with a "From
  Kiwix" tag instead of the Verified badge; a checksum failure is reported as a Kiwix download problem. The
  signature covers the block, so a changed URL is refused with the catalogue. `ovsync` lists them the same way and
  fetches them only with `--include external`.
- **Tiers.** `tier` groups artefacts in the setup and update screens: *Core* (medical and survival references,
  top articles, manuals; fits an internal drive; preselected), *Full text* (every Wikipedia article as text, ~49 GB),
  *Complete* (Wikipedia with images, ~119 GB; external SSD). Larger tiers are opt-in checkboxes.
- **Catalogue artefact** (`catalogue.json`): `{ "catalogueVersion", "entries": [ { "artefactId", "title",
  "description", "language", "licence", "attribution", "articleCount", "fileName", "role", "tier", "publisher",
  "sourceURL" } ] }` — human-readable metadata shown in the Library tab. `role` is `procedural` (field manuals,
  first aid, how-to), `encyclopaedic` or `reference`; the Library tab groups books by it and retrieval boosts
  procedural books on safety-critical questions (and guarantees one a top-two slot).

### Updater behaviour

1. `GET manifest.json` (no cache) → parse/validate → diff against `installed_artefacts` in SQLite.
2. Update screen: what's new (reason: new / changed / replaces), sizes, total, free space, incompatible items.
3. Download into `staging/<id>-<file>.part` with `Range: bytes=N-` resumption. The `.part` file size is the source of
   truth for the resume offset; a `.state.json` sidecar keeps the ETag so a changed server file restarts cleanly
   (`ResumeDecision` handles 206/200/416/404). Pausing cancels the task and keeps the partial file; relaunching
   the app resumes it.
4. SHA-256 verified streaming over the complete file, with progress (a 119 GB ZIM takes minutes). Mismatch →
   partial discarded, user-readable error with recovery.
5. Install atomically per artefact: the previous same-named file is parked in `staging/`, the new file is
   `rename`d into place, then the parked file and the replaced artefact are removed and the index updated in one
   transaction. Packs are extracted in `staging/` first and moved entry-by-entry. A failure anywhere before the
   final move leaves the old library untouched and working.
6. Side effects: ZIM → kiwix-serve restarts with the new file set; model → offered in Settings › Models; packs →
   `videos/` / `pages/` rescanned and indexed.

### Plans, licences and activation (works offline after one activation)

Four plans: **Core** (Core tier, the default 4B model, 2 Macs), **Household** (every tier, the larger models, Wi-Fi
sharing, 6 Macs), **Vault Drive** (one year at Household level, 2 Macs) and **Founder** (Household for three years,
then Core for life, 6 Macs). `Plan` in `Core/Entitlement/Licence.swift` names them; `Grant.forLevel` is the one
table that turns a level (free, core, household) into storage tiers and model artefact ids. `website/plans.json`
holds the money and seats; `GateTests.testPlanTableMatchesWebsite` keeps the two lists equal.

**Product rule (deliberate):** a lapsed or missing plan only pauses *downloads from OfflineVault's service*. The
library, chat, videos, pages and maps keep working forever, and a plan that carried Wi-Fi sharing keeps it after it
lapses. Content from a self-hosted server or Kiwix mirror needs no plan; the Server URL field that points the app at
one lives in Settings › Updates in DEBUG builds only, because self-hosting is a developer path for now.
`GateTests.testNoLicenceReadsInContentServingCode` fails the build if `Reference/`, `Database/`, `Share/`,
`Documents/` or `ChatController` ever consult the licence.

How it flows: the buyer pays on the website, the receipt page shows a key `OV-XXXX-XXXX-XXXX-XXXX` and an
`offlinevault://activate?key=` link. The app validates the key, asks the user to confirm (any web page can open that
URL), then POSTs the key and a per-Mac id to `/api/licence/activate`
(`LicenceActivationClient`), stores the signed file in `index/licence.json` and the key in
`index/licence-activation.json` (`EntitlementService`, the only writer of both), and refreshes silently when the
licence is within 14 days of expiry. Seats are counted on the server; Settings › Licence shows the roster with
Remove per Mac and Deactivate This Mac. A `.json` licence file dropped on the window still works with no internet.
`Entitlements.resolve(status:source:now:)` is the single gate: `applyUpdates`, the updates sheet, Setup, the model
offer and the sharing toggle all ask `denial(for:)` and show the `Denial`'s own copy.

```bash
cd Core
swift run licencetool keygen --out /secure/keys                       # add the printed key to Config.licencePublicKeys
swift run licencetool sign --key /secure/keys/licence-private.key --key-id prod-2026-10 \
    --subscriber "Jane Doe" --plan household --out jane.json           # --days / --expires / --never, --seats, --household-until
swift run licencetool verify --pubkey prod-2026-10=/secure/keys/licence-public.key jane.json
swift run licencetool canon payload.json                              # canonical payload bytes, for the worker's byte-diff
swift run licencetool sign-envelope --format offlinevault-manifest/1 --key scripts/dev-keys/licence-private.key \
    --key-id dev-2026 --payload fixture/out/manifest.v1.json --out fixture/out/manifest.v1.signed.json   # what make_fixture_server.sh runs
swift run licencetool fixtures --out ..                               # regenerates every test fixture and fixture/dev-licence-*.json
```

File format v2: `{ "format": "offlinevault-licence/2", "keyId": "prod-2026-10", "payload": "<base64 canonical JSON>",
"signature": "<base64 Ed25519>" }`, payload `{ licenceId, subscriber, plan, seats, issuedAt, expiresAt?, householdUntil? }`
with keys sorted, no whitespace, nulls omitted, dates `YYYY-MM-DDTHH:mm:ssZ` and no slash escaping, so the Worker's
`JSON.stringify` of a sorted object signs the same bytes. v1 files (`tier: "standard"`) still verify as one seat of
Core. `Config.licencePublicKeys` trusts the production key; DEBUG builds also trust the committed **development**
key in `scripts/dev-keys/` (never ship it), which signs the test fixtures and `fixture/dev-licence-*.json`.

The fixture server answers `POST /api/licence/activate` with those dev files: keys `OV-DEVC-…` (core), `OV-DEVH-…`
(household), `OV-DEVD-…` (drive), `OV-DEVF-…` (founder), `OV-DEVX-…` (expired), `OV-DEVS-…` (409, seats taken),
anything else 404. Launch with `--use-fixture-server` or set `OFFLINEVAULT_LICENCE_URL` to exercise the real client.
Non-goals in this version, stated so nobody mistakes them for guarantees: the plan gate is client-side (the bucket
stays unauthenticated, so a determined user can fetch artefacts without a plan; signed artefact URLs are the
follow-up that closes this), no local seat enforcement, no key recovery by email, and the content-source override is
DEBUG-only until self-hosting is a supported path.

---

## Local LLM chat with cited answers

- `llama-server` (llama.cpp) runs as a managed subprocess: `-m <gguf> --host 127.0.0.1 --port 8766 -c 8192|16384
  -ngl 99 --jinja --no-webui --parallel 1 --reasoning-format deepseek`. Health = `GET /health`. Startup timeout 180 s.
- Default model **Qwen3-4B-Instruct-2507 Q4_K_M** (artefact id `model-qwen3-4b-q4_k_m`, ~2.5 GB) delivered by
  the update service. The `-2507` instruct build follows instructions better than the original Qwen3-4B and needs no
  thinking mode. **Do not judge answer quality on the fixture's 0.6B model** — it deflects ("see a professional") and
  parrots sources; it exists only so the pipeline can be demoed quickly. `scripts/make_fixture_server.sh --full-model`
  publishes the real default instead (2.5 GB download, cached in `fixture/cache`).
  On Macs with ≥ 16 GB RAM, *Settings › Models* offers **Qwen3-8B Q4_K_M** (`model-qwen3-8b-q4_k_m`) when the
  manifest publishes it. Thinking mode is disabled via `chat_template_kwargs.enable_thinking=false`; any
  `<think>` blocks that still appear are filtered out of the stream.
- **Search library toggle** (composer, off by default, remembered): off → the model answers from its own knowledge
  with a plain conversational prompt and every answer is marked "Library search was off — unverified"; on → each
  question runs retrieval and the answer is grounded and cited. The header states which mode is active.
- Chat UI: streaming, persisted conversations (SQLite), Stop (⌘.), Regenerate, ⌘↩ to send, model name + health in
  the header, and a persistent safety note ("follow the cited source text, not the model's summary"), highlighted
  when the topic is safety-critical.

### Model guidance for this product

Preppers ask about injuries, water, power and shelter while off-grid, so the model must give concrete steps rather
than deflecting. Both system prompts (`Prompting.productContext`) state that the user may have no professionals,
emergency services or internet available, require step-by-step guidance first and allow only one closing line on
professional care. Tested on the broken-ankle question: Qwen3-0.6B deflects regardless of prompt; Qwen3-4B-Instruct-2507
gives immobilise / ice / elevate / warning-signs / when-to-move guidance. Candidates by RAM:

| RAM | Model | Notes |
|---|---|---|
| 8 GB | Qwen3-4B-Instruct-2507 Q4_K_M (2.5 GB) | default; good instruction following, modest refusals |
| 16 GB+ | Qwen3-8B Q4_K_M (5 GB) | more thorough; offered in Settings › Models when published |
| 32 GB+ | **Muse Glimmer 30B** (Meta, Apache-2.0, ~16.8 GB Q4_K_M) + DFlash drafter (1.6 GB) | strongest reasoning; 3–5× slower than the 4B; offered as a Complete-tier download in Settings › AI Model. `ModelProfile` sets its template argument `reasoning_strength=low` (its reasoning cannot be switched off), warmer sampling (temp 0.7, top_p 0.95, top_k 64), a 16k context on 32 GB / 32k on 64 GB, and passes the drafter with `-md … --spec-type draft-dflash` when present. A memory guard refuses to load any model that would leave less than 6 GB free. |
| 16 GB+ | Llama 3.1 8B Instruct / Ministral 8B Q4_K_M | alternatives if Qwen's safety tuning proves too conservative; any GGUF chat model works with llama-server |

### Retrieval (RAG)

With *Search library* on, three retrievers run in parallel on every message (greetings and small talk, i.e.
messages with no content words, skip retrieval and get a short conversational prompt instead):

| Retriever | Backend | Passage |
|---|---|---|
| `ReferenceRetriever` | kiwix-serve `/search?format=xml` over all installed books. libzim ANDs query terms, so a long question is issued as the full term set **plus** single-term and 2-term queries, fused by reciprocal rank. Top hits are expanded by fetching the article and picking the paragraph window with the most query terms. | ZIM article |
| `DocumentRetriever` | FTS5 (`doc_chunks_fts`) over ~900-char chunks of PDF text extracted per page with PDFKit; procedural boost on safety questions | PDF page (cited as "document, page N"; opens that page) |
| `PageRetriever` | FTS5 (`page_chunks_fts`, BM25, title ×3) over ~900-char chunks of extracted page text, any-term matching | page chunk |
| `VideoRetriever` | FTS5 over transcript windows (~20 s, keeps start time) and titles/descriptions | transcript window `@ t` |

`RetrievalCoordinator.merge` min-max normalises scores per retriever, de-duplicates by source, caps the prompt at
~6 000 characters and labels passages `[1]…[n]`. `Prompting.systemPrompt` instructs the model to answer only from the
SOURCES block for factual claims, cite inline, say "Not covered by your library" / "Unverified:" otherwise, and to
state plainly when nothing relevant was found. Citations are parsed with `Prompting.citedLabels` and rendered as chips;
tapping opens the ZIM article in the Library viewer, the page in the Pages viewer, or the video at the transcript
timestamp. Sources are stored with each assistant message, so chips keep working after a relaunch.

---

## Reference library (Kiwix)

**kiwix-tools publishes no macOS arm64 build** (3.8.2 ships `macos-x86_64` only; verified against
`download.kiwix.org/release/kiwix-tools/`). Chosen fallback: bundle the official x86_64 `kiwix-serve` and run it
under **Rosetta 2** via `/usr/bin/arch -x86_64` (detected automatically from the Mach-O header; see
`HelperBinary.launchCommand`). `fetch_binaries.sh` fails loudly unless `--allow-rosetta` is passed. All ZIM access is
behind the `ReferenceLibraryService` protocol (`start/stop/books/search/articleText/articleURL`), so an arm64
libkiwix build or a libzim-based in-process engine can replace `KiwixServeService` without touching the UI.

kiwix-serve runs with `--address=127.0.0.1 --port=8765 --blockexternal --nodatealiases <zims…>`; the book list
comes from its OPDS feed (`/catalog/v2/entries`; the URL book name is taken from the `/content/<name>` link, not
`<name>`), search from `/search?pattern&books.name&format=xml`, and articles render in a `WKWebView` that refuses
any navigation outside `http://127.0.0.1:8765/`. Attribution (Wikipedia CC BY-SA 4.0 etc.) is in *Settings › About
& Legal*.

---

## YouTube indexer and downloader

**Design rule:** OfflineVault ships an indexer and downloader, never redistributed video. The user's own Mac fetches
media from the sources the user adds, for a personal offline cache. This is stated in the Sources screen and here.

- **Sources**: a video, playlist or channel URL. Channel URLs are normalised to their `/videos` tab. Indexing runs
  `yt-dlp --flat-playlist --dump-single-json --skip-download …` and stores entries (title, id, channel, duration,
  upload date, description, thumbnail URL) in SQLite — no media. Nested channel tabs are flattened.
- **Browse & choose**: a table with duration, upload date and an **estimated size at the chosen quality**
  (360p/480p/720p, default 480p). Estimates use exact `filesize`/`tbr` when a probe has formats, otherwise a bitrate
  table (`VideoQuality.estimatedKbps`). Tick videos or *Select all new*; batches above the configurable threshold
  (*Settings › General*) ask for confirmation showing total size and free space.
- **Download** (`YtDlpCommand.downloadArguments`): `--format "bv*[height<=H][vcodec^=avc1]+ba[ext=m4a]/…"
  --merge-output-format mp4 --write-subs --write-auto-subs --sub-langs en.*,en --convert-subs vtt --write-thumbnail
  --convert-thumbnails jpg --write-info-json --download-archive videos/.yt-dlp-archive.txt --continue --newline
  --progress-template "download:OVPROGRESS …" --paths <videos> --output "%(id)s.%(ext)s" --ffmpeg-location <bin>`.
  The download archive guarantees re-indexing never re-downloads or duplicates. After yt-dlp exits, the app parses
  the `.info.json`, writes a compact `<id>.json` sidecar, generates a thumbnail with ffmpeg if none was saved, and
  indexes the subtitle text into `transcript_fts` (20-second windows with start times) so videos are searchable by
  what was said and citable by the LLM.
- **Download manager**: queue with per-item progress/speed, pause (kills yt-dlp; `--continue` resumes), retry,
  remove; one yt-dlp job and two artefact downloads at a time.

---

## What the prepper community asked for (built)

Research across r/preppers, r/Survival, r/Kiwix, r/DataHoarder and r/LocalLLaMA (Oct 2026) drove these features:

| Community ask | What OfflineVault does |
|---|---|
| "My PDFs are a mess, no real search" | **Import a folder** (⇧⌘I): every PDF, EPUB, text file, video (+ .vtt/.srt) and saved HTML under a folder is copied in, indexed per page/chapter, **tagged by subject** (medical, water, food, power, comms…) and **de-duplicated by content hash**. Documents tab filters by subject; counts show "what's where". |
| "Kiwix doesn't have maps" | **Maps tab**: PMTiles regions rendered fully offline by MapLibre inside WKWebView, tiles read from disk over a custom URL scheme with Range support. Regions arrive as `map` artefacts or you extract any bbox with the bundled `pmtiles` CLI (`pmtiles extract <planet> out.pmtiles --bbox=… --maxzoom=…`, Settings › Maps shows the command). |
| "First 24 hours of a fire / flood / grid-down" | **Scenarios tab**: nine CC0 checklists (grid down, no safe water, wildfire, hurricane, earthquake, severe bleeding, hypothermia, nuclear, go-bag). Tick items, **Verify in library** runs retrieval and shows the cited sources, **Print / Save PDF** for the binder. |
| "AI will confidently lead you to death" | **Honesty rules**: plant/mushroom identification, medication dosing and chemical mixing are never answered from the model's memory. With library search off, or on with no matching source, the app replies with a fixed refusal that explains why and what to add. Every grounded answer still cites book + page. |
| "Two is one, one is none" / flash decays | **Settings › Backup**: clone the library to another drive with hash verification; re-verify an existing backup; reminder when the last backup is older than six months. Anything can be printed or saved as PDF. |
| "Any phone, any tablet, multiple people at once" | **Settings › Share**: a read-only local-network web page (`http://<mac>:8780/`) listing books, manuals, pages and videos with search; videos stream with range requests; kiwix-serve binds to the LAN while sharing. Off by default. |
| "Is this dump pre-LLM?" / stale dumps | **Freshness badges** on every book from the ZIM's own date, with a green "pre-LLM" marker for snapshots before Nov 2022; manifest and catalogue show publish dates. |
| Medical, repair and morale content | Content spec adds WikiMed, MDWiki, WikEM, US military medicine, Ready.gov, CD3WD, Low-tech Magazine, Stack Exchange (Sustainable Living, Outdoors, Gardening, DIY, Ham), Project Gutenberg subject subsets incl. Fiction for morale, CIA World Factbook. |
| EPUB hoards | **EPUB** support (unzip → OPF → spine → chapters), indexed per chapter with a plain reader; text/markdown files too. |

Explicitly not shipped on licence grounds: wikiHow (withdrawn by publisher), *Where There Is No Doctor* in digital form (Hesperian permission required), iFixit/Khan Academy only with a non-commercial licence review, Survivor Library (220 GB, outdated/dangerous recipes), torrent "Ark" aggregates.

## Documents (PDF manuals)

The best preparedness material is PDF: FEMA's *Are You Ready?*, Army field manuals (FM 4-25.11 First Aid,
FM 3-05.70 Survival, FM 21-10 Field Hygiene), the USDA *Complete Guide to Home Canning*, CDC/EPA water guidance.
`DocumentService` imports PDFs (user import or `document-pack` artefacts), extracts text per page with PDFKit (no
third-party dependency), repairs hyphenation and line breaks, chunks it into `doc_chunks_fts` with the page number,
and the Documents tab renders them in a `PDFView`. Chat citations to documents open the exact page. Sidecar
`<name>.json` files carry title, publisher, licence, role and source URL.

## Publishing real content (`scripts/content/`)

Three documents, one owner each. `catalogue-spec.json` is **intent**: every entry the service may publish, with
its tier (`core` < `full` < `complete`), kind, role, licence and attribution, and a `source` that says where the
bytes come from (`kiwix`, `url`, `archive`, `documents`, `zimit`, `map_extract`, `built`). R2 holds the **bytes**
under content-immutable keys. `catalogue.lock.json` holds the **facts** confirmed in R2 per entry (resolved URL,
size, sha, artefact id and path, the previous ids as `history`, builder inputs) and is committed after every
publish so a run is reproducible and `replaces` comes from the lock rather than from id prefixes.

Keys name an **edition**. Mirror entries (`kiwix`, `url`, `archive`) keep the upstream file name, so a key that
turns up in R2 with different bytes is a hard failure (upstream republished under one name). Everything else is
dated by the publishing month with a Kiwix-style letter when that month is published again with different bytes:
`zim/fieldguide_en_2026-10.zim`, then `zim/fieldguide_en_2026-10b.zim`; `packs/docs-us-military-manuals_2026-10.tar.gz`;
`maps/world-full_2026-10.pmtiles`. The artefact id is `<entry>-<edition>` and the id it supersedes goes onto the
lock's `history`, so `replaces` carries the lineage and a client removes the old file.

```bash
scripts/content/.venv/bin/python scripts/content/publish.py doctor            # tools, keys, disk, origin
scripts/content/.venv/bin/python scripts/content/publish.py plan --tier core  # resolve every source, print the per-tier table, write nothing
scripts/content/.venv/bin/python scripts/content/publish.py publish --tier core
scripts/content/.venv/bin/python scripts/content/publish.py verify           # catalogtool verify --base <origin>/updates/ --range-probe
```

`publish` locks `content/.publish.lock`, resolves each entry (Kiwix from the category listing with the sha from the
`.meta4`, OPDS as fallback; HuggingFace LFS oid; archive.org metadata; the newest Protomaps daily build), decides on
the main thread which files stream (anything larger than free disk minus 40 GB, or `stream: true`), then converges
two entries at a time, smallest first: present in R2 with the expected sha, done; otherwise fetch (resumable
`curl -C -`, `content/.hashcache.json` keyed by size and mtime, local copies over 4 GB evicted after a verified
upload) or stream (`curl` into the worker's multipart route, which hashes as it sends; a source with no upstream
checksum, such as the Protomaps planet, goes up without one and the lock records the sha and size the store saw,
checked against the upstream `Content-Length`) or build. A sha that disagrees with the `.meta4` or LFS value fails
the entry and leaves nothing in R2. The lock is rewritten after every entry, so a crash loses no verified work and
the next run only does what is left. The manifest is derived from the whole
lock (a `--tier core` run keeps last month's full and complete artefacts live), compared with the live one through
the origin and skipped when nothing a client can see changed; otherwise the catalogue goes up at
`catalogue/catalogue-<version>.json`, then the signed archive `manifests/manifest-<version>.json`, then
`manifest.json` last. Every run writes `scripts/content/reports/<command>-<version>.json` (git-ignored except
`latest.json`).

Uploads go through the worker's `/admin/r2/` route with the bearer secret in `~/.offlinevault-keys/upload-secret`
(parts of 90 MB, four in parallel, aborted on failure). No S3 keys and no `aws` CLI. The signing seed is
`~/.offlinevault-keys/content/licence-private.key`, key id `content-2026-10`; the manifest is served as
`{"format":"offlinevault-manifest/1","keyId","payload","signature"}` where `payload` is the exact JSON bytes the
publisher wrote and `signature` is Ed25519 over them. `rollback --to VERSION` re-signs an archived manifest with a
fresh `publishedAt` (the client's replay guard rejects older ones). `prune --older-than 60 --yes` deletes objects no
live, archived-recent or locked manifest names; it never runs unattended. `--store fake --out DIR` runs the whole
pipeline against an on-disk stand-in that pretends R2 already holds every passthrough artefact at its upstream sha,
so a complete signed manifest and catalogue can be produced and inspected without moving a byte.

The **licence gate** is `ovpub/spec.py`: a paid tier may carry CC0-1.0, PD, PD-USGov, CC-BY-4.0, CC-BY-SA-2.0/3.0/4.0,
GFDL-1.3, OGL-3.0, ODbL-1.0 or Apache-2.0 and nothing else; BY, BY-SA, OGL and ODbL entries must name their authors;
ids must be unique and prefix-free; an id cannot sit in both `entries` and `excluded`; a document without a verified
URL fails the parse. `excluded` keeps each rejection next to the data (iFixit, Low-tech Magazine, CD3WD, the four
zimgit collections, MedlinePlus) with its reason. `migrate_spec.py` is the rerunnable edit that produced the current
file from the 2026-10 audit (`--check` compares).

**Builders** make the bytes for entries without an upstream file: `documents` packs the PDFs it fetches (curl, then
`browser_fetch.swift`, a hidden WKWebView, for agency sites that refuse scripts; `%PDF` is verified) into a
deterministic tar.gz with one JSON sidecar per document; `zimit` crawls a public-domain site with Docker
(`ghcr.io/openzim/zimit`, hours per site); `map_extract` cuts a PMTiles region from the Protomaps planet build with
the bundled `pmtiles` CLI (`maxzoom: 15` means the whole planet, streamed); `built: fieldguide` is the Field Guide
below. Builders record their inputs in the lock (document URLs and shas, the Protomaps build date, the crawl or
build month, the guide digest) and are skipped when the inputs are unchanged and the locked object is still in R2.
When the inputs changed, the entry is built locally first and the edition is chosen from what R2 holds. The
month's key is taken when it is free or already holds the same bytes, otherwise the next letter. A run that died
between the upload and the lock write finds its object on the next run and records it without rebuilding.

The monthly run is `scripts/launchd/com.offlinevault.publish.plist` (`publish --tier complete` on the 20th at 02:00,
log in `~/Library/Logs/offlinevault/`). It never pushes: review `catalogue.lock.json` and `reports/latest.json`,
then commit. Tests: `cd scripts/content && .venv/bin/python -m pytest tests` (spec gate, resolver on a saved listing
and `.meta4`, lock and manifest derivation, `WorkerStore` against an in-process fake of the admin route, converge
against `FakeStore`, the CLI end to end, the signer cross-checked by `licencetool verify`, the Field Guide).

## The Field Guide (`scripts/content/fieldguide/`)

`fieldguide_en_<YYYY-MM>.zim` is OfflineVault's own book: short procedures followed by the public sources they were
adapted from. Editors change data, not code: `sections.yaml` (16 sections in order, plus the smoke queries
`validate` must answer) and one `articles/<section>/<slug>.yaml` per article with `title`, `summary`, `procedure`
(a Markdown subset: `###`, numbered and bulleted lists, bold, `>` warnings), `sources` and `related`. A source is
either `mediawiki` (`site`, `title`, optional `sections` to keep, `images`) or `pdf` (`document`, a document id from
`catalogue-spec.json`, so title, URL and licence have one home, and physical `pages`). `fieldguide.py find-pages
--document <id> "<regex>"` prints the pages a heading sits on; the ranges in the first 20 articles were verified that
way, not from memory.

The builder fetches Parsoid HTML (`/api/rest_v1/page/html/<title>`, polite User-Agent, cached under
`content/cache/fieldguide/`), keeps the named `<h2>` sections, strips navboxes, infoboxes, references, hatnotes and
every attribute, keeps links only to other Field Guide articles, demotes headings one level, and keeps a Commons
image only when its `LicenseShortName` is public domain, CC0, CC BY or CC BY-SA (fetched at 800 px, credited in the
caption). PDF pages go through pypdf into paragraphs, lists and headings, with the PDF embedded once at
`P/<document>.pdf` and linked by page. MediaWiki revision ids and image shas are pinned in `articles.lock.json`
(`--refresh` moves them). The ZIM has `Name=fieldguide_en`, a full-text index, the 48x48 app icon, index and section
pages and `FRONT_ARTICLE` hints on articles only. `validate` opens it the way the app does: metadata, main entry,
index, every internal link, each smoke query in the top 3, and zimcheck in Docker when present.

```bash
scripts/content/.venv/bin/python scripts/content/fieldguide.py lint
scripts/content/.venv/bin/python scripts/content/fieldguide.py build --date 2026-10-01        # content/zim/fieldguide_en_2026-10.zim
scripts/content/.venv/bin/python scripts/content/fieldguide.py build --offline --articles boil-bleach-filter bleeding-control ... --out fixture/out/zim/fieldguide_en_2026-09.zim
```

`--offline` builds from the committed `snapshots/` (ten articles) and embeds no PDF, which is how the fixture
server gets its two editions from the same code path. The first 20 articles cover water (7), first aid (5), food
(2), shelter (2), fire (2), evacuation and communications; the remaining sections of the plan in the 2026-10 audit
arrive as data pull requests.

## User-added webpages

Capture pipeline (`PageArchiver`, vendored, no third-party dependency — same idea as SingleFile/monolith):

1. Fetch the HTML (Safari-like UA, charset from headers/meta).
2. Tokenise with the built-in forgiving `HTMLTokenizer` (streams tokens, never builds a DOM).
3. Drop `<script>`, `<noscript>`, `<iframe>`, `<object>`, `<embed>`, `<template>`, `<base>`, `on*=` handlers,
   `javascript:` URLs, `ping`, form actions, meta refresh, and `<link>` hints (preload/prefetch/dns-prefetch/…).
4. Inline `<link rel=stylesheet>` as `<style>` (with nested `url()` and one level of `@import` resolved to data
   URIs), `<img src>`/`poster`/icons as data URIs, drop `srcset`, absolutise `<a href>`. Per-asset 8 MB, 40 MB total.
5. Inject `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; style-src
   'unsafe-inline' data:; font-src data:; media-src data: blob:; …">` plus `offlinevault-source` / `offlinevault-captured`
   meta tags, and write `pages/<id>.html` + `<id>.json`.
6. Extract readable text (`HTMLText.extract`: prefers `<article>`/`<main>`, skips nav/aside/footer/forms), chunk
   it (~900 chars) and index into `page_chunks_fts`.

Rendering uses `WKWebView.loadFileURL` with JavaScript disabled, a compiled `WKContentRuleList` that blocks every
`http(s)://` and `ws://` request, and a navigation delegate that cancels non-`file:` navigations — three independent
layers, so a saved page renders identically with the Mac offline. *Refresh from source* re-captures when online and
keeps the previous capture (recording the error) if it fails.

---

## Video library and player

Grid/list of downloaded videos with thumbnails, title, channel, duration and size; search spans titles,
descriptions and transcripts; filter by source. The player is AVKit (`VideoPlayer`) with resume position per video
(saved every ~5 s and on close), playback speed 0.75–2×, a subtitle overlay driven by the saved `.vtt`, and a
clickable transcript sidebar. Opening a video from a chat citation seeks to the cited timestamp.

---

## Mac-app polish (from the UX review)

- **Native chrome**: window toolbars (`.toolbar`), `.searchable` fields with 250 ms debounce, `.navigationSubtitle` counts, sidebar badges, grouped sidebar (Knowledge / Manage), View / Edit / Help menus, a custom About window, keyboard-shortcuts sheet (Help menu), app icon (`scripts/icon/make_icon.swift`).
- **State survives navigation**: every screen's selection, search, open article and scroll live in `ScreenStates.swift` objects owned by `AppModel`; the video player keeps its position (paused) when you leave; scenario tick-marks persist in SQLite.
- **⌘K Search Everything**: one results list fused across books, PDF pages, saved pages and transcripts.
- **Chat**: library grounding is the default; the composer sends on Return (Shift-Return for a newline); answers end with **source cards** (icon, title, page/time, excerpt); safety-critical answers get an orange rule; `CitationVerifier` relabels `[n]` when a sentence's words clearly came from another passage (unit-tested); conversations can be renamed and filtered; streaming only re-renders the last message and never fights your scrolling.
- **Reference reader**: back/forward, find in article, text size, print (⌘P), copy link, dark-mode treatment of light ZIM pages.
- **Drag and drop** everywhere: PDFs/EPUBs/videos/HTML onto the window or Documents, a folder → Import sheet, a `.pmtiles` → Maps, a license file → Setup or Settings, a link from Safari → Saved Pages. Quick Look (Space) on documents and videos.
- **Safety rails**: every destructive action confirms with size; user files go to the Trash (undoable in Finder); errors are queued banners with an action, never swallowed.
- **Setup**: default location `~/OfflineVault Library` (or “OfflineVault Library” inside a chosen folder, so nothing is littered), license step explains where the file comes from and accepts drops, downloads continue after "Start Using OfflineVault", notifications and a Dock badge when they finish.
- **Maps**: "Download a Region" form runs the bundled `pmtiles` extract with live log; import is async.
- **Share**: Bonjour address and a QR code to scan.
- **Performance**: storage totals and `quick_check` off the main thread; download progress coalesced to 5 updates/s; screens observe `libraryGeneration` instead of every model change.
- **Release hygiene**: developer controls and script hints compile only under `#if DEBUG`; user-facing jargon removed; Sparkle wired for app updates (set `SUFeedURL`/`SUPublicEDKey` in `project.yml`, keys via `scripts/sparkle_keys.sh`; inactive while the feed is the placeholder); US spelling in UI strings.

## Built for the day the internet is down

Robustness work driven by an audit of what actually fails offline:

| Failure mode | What happens now |
|---|---|
| One corrupt ZIM (bit rot, truncated download) | kiwix-serve exits if *any* file fails to load, which used to take every book down. Each ZIM is now structurally validated (`ZimValidator`: magic, pointer offsets, checksum block) before start, and if kiwix-serve still rejects a file its name is parsed from the log, the file is excluded and the server restarts with the rest. The Library tab lists damaged books with a re-download action. |
| Library drive unplugged | The app shows "Waiting for your library drive" with the path, keeps helpers stopped, and reopens the library automatically on `NSWorkspace.didMountNotification`. A library on a network share triggers a warning (SQLite WAL is unsafe there and the share will not exist in an outage). |
| Index corruption after power loss | `PRAGMA quick_check` at every open; **Settings › Maintenance › Rebuild index** regenerates every derived table from files and sidecars while keeping conversations, settings and playback positions. |
| Silent bit rot in installed files | **Verify all files** re-hashes every book, model and map against the checksum recorded at install and lists what to re-download or restore. |
| Rosetta 2 missing on a fresh Apple Silicon Mac | Detected at launch and in the drill; one-click `softwareupdate --install-rosetta` with an admin prompt, with the explicit note that macOS can only fetch it from the internet. |
| 8 GB Macs under memory pressure | `DispatchSource` memory-pressure monitor unloads llama-server at critical pressure with a notice; "Load the AI model only when Chat is opened" defaults on for ≤ 8 GB; context size already scales with RAM. |
| Wrong system clock on an offline Mac | Clock-sanity check against the build date and licence issue date; a lapsed-looking licence never blocks the library anyway. |
| "Does it really work offline?" | **Readiness** (⌘0, ⇧⌘R): the offline drill checks network state, bundled helpers, Rosetta, library volume, index integrity, every book (validated and searched), documents/videos/maps on disk, the AI answering a library question with a citation, backup age, licence, clock, free space and memory. Every amber/red line has a fix button; the report can be saved. |
| Support | **Export diagnostics**: versions, helper output, last drill, index state — no personal content. |

## Helper processes

Every helper is lifecycle-managed by `ManagedProcess` / `ProcessSupervisor`:

- started on demand, health-checked over localhost before use, restarted after a crash with back-off (max 3 per
  minute, then a user-visible "Restart" action), terminated with SIGTERM→SIGKILL on quit (`applicationWillTerminate`,
  SIGTERM/SIGINT/SIGHUP handlers and `atexit`);
- PIDs and executable paths are persisted to `~/Library/Application Support/OfflineVault/helper-pids.json`; at launch
  `reapOrphans()` kills helpers left behind by a previous crash after verifying the executable path matches;
- one-shot tools (yt-dlp, ffmpeg) run through `ProcessRunner` with streamed output and cooperative cancellation.

Errors are user-readable `UserFacingError`s (title, message, recovery action) surfaced in a banner, the Downloads
list or the chat message itself — never silent, never a crash.

---

## Binary provenance (`scripts/fetch_binaries.sh`)

| Binary | Version | Source | SHA-256 (archive) | Arch |
|---|---|---|---|---|
| llama-server (+dylibs) | llama.cpp **b11552** | github.com/ggml-org/llama.cpp releases `llama-b11552-bin-macos-arm64.tar.gz` | `f4b33fe4…b48c07` | arm64 |
| yt-dlp | **2026.08.19** | github.com/yt-dlp/yt-dlp releases `yt-dlp_macos` (matches upstream `SHA2-256SUMS`) | `0f192b7e…f7202` | universal (x86_64+arm64) |
| ffmpeg | **9.0.2** static | ffmpeg.martin-riedl.de pinned build `1789931890_9.0.2/macos/arm64` (matches its `.sha256`) | `c8ed4c4e…92d924` | arm64 |
| kiwix-serve | kiwix-tools **3.8.2** | Apple Silicon: built from source by `scripts/build_kiwix_serve.sh` (kiwix-build `e7343a16`, `macos_arm64_static`, libkiwix 14.3.0, libzim 9.8.2; sources checksummed by kiwix-build). Intel or `--allow-rosetta`: download.kiwix.org/release/kiwix-tools `kiwix-tools_macos-x86_64-3.8.2.tar.gz` | built: see `VERSIONS.txt`; download: `ae341280…47f247` | **arm64 static** (x86_64 under Rosetta 2 only with `--allow-rosetta`) |

Full hashes are in the script and written to `Resources/bin/VERSIONS.txt`. The script verifies every checksum,
fails loudly on mismatch, and on Apple Silicon builds kiwix-serve from source unless `--allow-rosetta` asks for the x86_64 download. llama-server needs its
`libllama*/libggml*/libmtmd*` dylibs next to it (`@loader_path` rpath); the app also sets `DYLD_LIBRARY_PATH`.

Why these sources: the official ffmpeg.org download page links to evermeet.cx (x86_64 only) for macOS; Martin
Riedl's builds are the arm64 static builds it recommends and publish per-build checksums. yt-dlp's `yt-dlp_macos`
is the project's official standalone macOS binary.

---

## Offline maps

The Maps tab is one whole-world map, not a list of regions. A **world overview** PMTiles (zoom 0–5, 14 MB in
the fixture; zoom 0–7, 180 MB recommended for the Core tier) gives countries, cities, roads and labels everywhere;
any downloaded regions are layered on top with street detail inside their bounds. Tools: **Locate Me**
(CoreLocation; macOS positions by Wi-Fi, so the last fix is remembered and a **Home** point can be saved for use
with no internet), a **go-to** field that accepts decimal or degrees-minutes-seconds in any common notation,
click-to-read coordinates with a marker and copy, a crosshair readout of the map centre, scale bar, and a
**Map Data** menu for installed regions, "Download a Region" (bundled `pmtiles extract` with live log) and
imports. Dropping a `.pmtiles` on the window installs it.

**Full-detail world map.** Settings › General › World map (and Map Data) can download the entire planet at street
level: the Protomaps daily build is one 130 GB PMTiles file with `Accept-Ranges`, so it goes through the resumable
downloader into `maps/world-full.pmtiles` (no checksum is published; completeness is checked by size) and shows in
Downloads with pause/resume. The free-space guard refuses it on a nearly full drive. The content spec publishes the
same file as the Complete-tier artefact `map-world-full` for subscribers.

`scripts/fetch_web_assets.sh` bundles MapLibre GL JS 4.7.1, pmtiles.js 3.2.1, @protomaps/basemaps 5.7.2, Noto Sans
glyphs and Protomaps sprites into `Resources/web/` (pinned, checksummed, git-ignored), plus the `pmtiles` CLI into
`Resources/bin/`. `map.html` is served to a WKWebView over `ovweb://`; map files over `ovtiles://` with HTTP Range
semantics (`TilesSchemeHandler`), so pmtiles.js reads tiles straight from disk and the content-rule list blocks
every network request. The page picks the official basemaps style for schema-v4 tiles and a compact built-in style
for older v3 extracts (the fixture ships Protomaps' 6.6 MB Florence sample). Regions: `map` artefacts from the
service, `Maps › Import .pmtiles…`, or a `map_extract` entry in `catalogue-spec.json` (the publisher runs `pmtiles extract`
against the Protomaps daily planet build; from the shell: `pmtiles extract https://build.protomaps.com/<date>.pmtiles out.pmtiles --bbox=<w,s,e,n> --maxzoom=14`), which pulls
only the tiles inside the box (a county at street level is ~100–400 MB, a US
state 2–6 GB). Headless check: `mapcheck` loads the page through the same handlers and reports 16 layers / 1,400+
rendered features for the sample.

## Signing, entitlements, distribution

Direct distribution, **no App Sandbox** (we spawn helpers and read user-chosen volumes). `project.yml` sets
`ENABLE_HARDENED_RUNTIME = YES`; the app's only entitlement is `com.apple.security.app-sandbox = false`
(`OfflineVault/OfflineVault.entitlements`). The app needs no hardened-runtime exceptions because helpers are separate
processes; two helpers carry their own (see Releasing). `Info.plist` enables `NSAllowsLocalNetworking` for the loopback helpers.

Local builds use ad-hoc signing (`CODE_SIGN_IDENTITY = -`); Xcode omits the runtime flag on ad-hoc *Debug* builds.
Releases go through `scripts/release.sh` (see Releasing), which re-signs the helpers and the app with hardened runtime
and notarises when a Developer ID is present. Do not `codesign --deep` an Xcode *Debug* build: its
debug-support dylib ends up with a different team id and dyld refuses to load it.

---

## Licensing notes

- **Wikipedia / Wikimedia content**: CC BY-SA 4.0, authors are the Wikipedia contributors; other ZIMs carry their own
  licence (shown per book from the catalogue). ZIM files come from the Kiwix / openZIM projects. The in-app
  *About & Legal* screen carries the attribution.
- **Kiwix** (kiwix-tools, libkiwix, libzim): GPL-3.0. **llama.cpp**: MIT. **yt-dlp**: Unlicense. **FFmpeg** (Riedl
  build): GPL. **Qwen3 models**: Apache-2.0 (Alibaba Cloud). **SQLite**: public domain. Bundling GPL binaries as
  separate executables invoked over localhost/pipes is the arrangement used; ship their licence texts with the app.
- **US-government documents** are public domain under 17 USC §105 (works of federal employees). Contractor-authored
  material and licensed images on the same sites are not automatically public domain; the spec lists only agency
  publications. Internet Archive copies are used as a mirror of the same public-domain works. *Where There Is No
  Doctor* (Hesperian) is excellent but CC BY-NC-SA, so it is not in the default spec for a paid product.
- **Fixture content** (generated video, pages): original CC0 text written for testing; not medical advice. The fixture
  Field Guide is ten articles of the real one built from committed snapshots (`fieldguide.py build --offline`). The fixture model is Qwen3-0.6B (Apache-2.0) from HuggingFace; `--mock-model` avoids any download.
- **Videos and webpages** the user adds are never redistributed by the app or the service.

---

## Known limitations

- **kiwix-tools publishes no arm64 macOS build.** Releases bundle an arm64 kiwix-serve built from source
  (`scripts/build_kiwix_serve.sh`); a bundle made with `--allow-rosetta` carries the x86_64 binary instead and
  needs Rosetta 2 (`softwareupdate --install-rosetta`), which the app detects and explains.
- **YouTube changes often.** Recent yt-dlp versions may want a JavaScript runtime (deno) for some YouTube formats
  and YouTube sometimes demands sign-in ("bot check"); such failures surface as readable errors with a retry. Update
  yt-dlp by bumping the pin + checksum in `fetch_binaries.sh`.
- Size estimates for indexed-but-not-probed videos are bitrate heuristics (±30 %); exact numbers appear once a video
  is probed.
- The page archiver is a tokenizer, not a browser: pages that build their content with JavaScript capture only what
  is in the HTML. Fonts referenced from CSS are inlined; `<video>`/`<audio>` sources are not downloaded.
- The 0.6B fixture model answers simply and sometimes repeats itself; it exists so the full flow can be demoed
  without a 2.5 GB download. Qwen3-4B/8B are the real targets.
- The chat context window is 8k tokens on 8 GB machines (16k otherwise); very long conversations are trimmed to the
  last 6 turns.
- Subtitles in the player are drawn by the app from the `.vtt` (AVKit cannot sideload external subtitle files);
  styling is basic.
- There is no automatic migration of a library between volumes — choose a new folder and re-download, or move the
  folder and point Settings › General at it.

---

## Releasing

`scripts/release.sh` turns the checkout into a public download plus a Sparkle feed, and `scripts/upload_release.py`
puts both on the content origin. One run of the script is one release.

```sh
scripts/release.sh                          # version and build from project.yml (MARKETING_VERSION, CURRENT_PROJECT_VERSION)
scripts/release.sh --version 1.0.1 --build 2
scripts/release.sh --skip-upload            # build, sign, package and verify only
scripts/content/.venv/bin/python scripts/upload_release.py build/release/appcast/{OfflineVault-1.0.0.dmg,appcast.xml,latest.json}
                                            # publish what --skip-upload built, once you have tried the DMG
```

What it does, in order: `xcodegen generate`; `xcodebuild archive` in Release (the configuration that drops the
development signing key); re-signs every Mach-O inside-out with hardened runtime (helper dylibs and executables
in `Resources/bin`, Sparkle's XPC services, `Autoupdate` and `Updater.app`, the framework, then the app);
`codesign --verify --deep --strict` and `spctl --assess`; checks `Info.plist` and `strings` the binary for the
dev key and the placeholder feed; launches every helper from inside the signed bundle; notarizes and staples when
it can; builds `OfflineVault-<version>.dmg` with an Applications symlink; runs Sparkle's `generate_appcast`;
writes `latest.json`; uploads. Output: `build/release/appcast/{OfflineVault-<version>.dmg,appcast.xml,latest.json}`.

Published keys, all under `/updates/app/` on `https://offlinevault.dev`:

| Key | Mutable | Purpose |
|---|---|---|
| `OfflineVault-<version>.dmg` | no (same bytes may be re-put; different bytes need a new `--version` and `--build`) | the download |
| `appcast.xml` | yes | the Sparkle feed baked into the app (`SUFeedURL`) |
| `latest.json` | yes | `{version, build, dmg, sha256, sizeBytes, publishedAt, minimumSystemVersion, signed, notarized}`; the website's `/download` 302s to its `dmg` |

Prerequisites:

- Helpers fetched (`scripts/fetch_binaries.sh --allow-rosetta`, `scripts/fetch_web_assets.sh`) and the app built
  once so SwiftPM has Sparkle's tools under `build/DerivedData`.
- The Sparkle private key in the login Keychain of the release machine (`scripts/sparkle_keys.sh` generates the
  pair and prints the public key, which is `SUPublicEDKey` in `project.yml`). The script refuses to run when the
  Keychain key and `project.yml` disagree; every update the app accepts must be signed by that one key.
- The publisher venv (`scripts/content/.venv`) and the upload bearer token at `~/.offlinevault-keys/upload-secret`.
- For a build Gatekeeper accepts without a right-click: a **Developer ID Application** certificate in the keychain
  (Apple Developer Program) and a notarytool profile named `offlinevault`:
  `xcrun notarytool store-credentials offlinevault --apple-id <id> --team-id <team> --password <app-specific password>`.
  The script detects both and then signs with Developer ID, timestamps, notarizes the app and the DMG and staples
  them, with no script change. Without them it falls back to **ad-hoc** signing and prints a warning: the app runs,
  but a downloaded copy is quarantined and macOS refuses it with "Apple could not verify OfflineVault is free of
  malware" (Done or Move to Bin, no Open). The user then opens **System Settings > Privacy & Security**, finds
  "OfflineVault was blocked" and clicks **Open Anyway**, or runs
  `xattr -d com.apple.quarantine /Applications/OfflineVault.app` and opens it again.

Entitlements. `scripts/entitlements/yt-dlp.plist` opts yt-dlp out of library validation
(`com.apple.security.cs.disable-library-validation`) under every identity: it unpacks and dlopens a Python framework
signed by the yt-dlp project, which hardened runtime rejects from any other signer. In the ad-hoc fallback the script
adds the same exception to the app and to llama-server, because an ad-hoc signature has no team ID and library
validation then refuses the ad-hoc Sparkle.framework and llama-server's own dylibs; a Developer ID build keeps
validation on for both. ffmpeg, pmtiles and kiwix-serve run with hardened runtime and no exceptions. The script
proves all five helpers launch from the signed bundle on every release.
