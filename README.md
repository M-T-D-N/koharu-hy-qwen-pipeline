# Koharu Hy-MT2 + Qwen pipeline

An independent, experimental Japanese-to-Korean manga translation pipeline for [Koharu](https://github.com/mayocream/koharu). This repository is not an official Koharu project and is not an upstream contribution request.

The repository contains:

- a patch pinned to Koharu commit `a81c5829ea99a45e04580ff97fd6affa81b2db34` that adds a loopback-only headless Web UI, HTTP API, and MCP endpoint;
- an OpenAI-compatible translation sidecar that runs a pinned Hy-MT2 first pass, unloads it, starts an externally managed Qwen reviewer, permits one targeted repair pass, queues nonblocking low-confidence output for review, and fails closed only on unusable output;
- process wrappers that record and later verify exact process identity before stopping or restarting Koharu or the sidecar.

It does not contain model weights, manga pages, OCR corpora, generated translations, private evaluation output, or a Qwen runtime. A private 512-page / 6,525-region pilot informed development, but none of that source material or detailed output is published here.

## Architecture and boundaries

```text
Koharu pipeline
  -> loopback OpenAI-compatible sidecar
  -> pinned Hy-MT2-7B first translation (CUDA only)
  -> Hy-MT2 process exits and releases VRAM
  -> shared Qwen lease is acquired, then the exact external Qwen is reused or started
  -> sparse review, then at most one targeted repair
  -> deterministic validation and Koharu typography update
  -> the shared Qwen remains externally owned and reusable after the lease is released
```

The sidecar binds to loopback by default. It refuses CPU fallback for Hy-MT2, serializes GPU jobs, and publishes a sibling `foreground-request.json` before waiting for the configured cross-process Qwen lease. Cooperating background workers can yield between requests; the wait is cancellable and bounded to 600 seconds by default, after which `QWEN_BUSY` is returned without disturbing the current owner. A lease left by a crashed process is removed only after its PID and recorded creation time prove that owner is no longer active. Qwen may be off when the services start. After acquiring the lease, the lifecycle recovers or starts it as needed and must report an exactly owned Qwen with the configured model and at least 131,072 tokens of context. The sidecar never stops this externally owned shared runtime; it releases only its lease so later pages and other workers can reuse Qwen. Qwen review runs with reasoning disabled. Empty translations, unresolved placeholders, and invalid statuses fail closed. Nonempty low-confidence output and Japanese residue continue through Koharu but remain explicit review items; the launcher then requires a translated candidate, a manual correction, or preservation of the original pixels before export.

## Requirements

- Windows 11 and PowerShell 7
- Python 3.13
- Rust toolchain and the build dependencies required by Koharu
- a CUDA-capable NVIDIA GPU; the development configuration used a 32 GB RTX 5090
- a CUDA-enabled PyTorch build compatible with the local driver
- `curl.exe`
- an external OpenAI-compatible Qwen server and a lifecycle script described below

The code defaults to Qwen model ID `dirk-qwen3.8-27b-q5` at `http://127.0.0.1:8000/v1`. Both values are configurable. Model weights and their licenses remain the operator's responsibility.

## Windows GUI launcher

After preparing Koharu, Python, Hy-MT2, and the Qwen lifecycle script as described below, double-click:

```text
Launch-Koharu-GUI.cmd
```

The launcher discovers a standard PowerShell 7 installation or `pwsh.exe` on `PATH`. For a portable/shared PowerShell runtime, set `KOHARU_PWSH_EXECUTABLE` or put that machine-specific assignment in ignored `config/local-runtime.cmd`; no Codex-specific runtime path is assumed by the public launcher.

The Korean-language launcher provides native file and folder pickers. Open **고급 실행 설정** once and choose the local Python executable, patched `koharu.exe`, Hy-MT2 model folder, and Qwen lifecycle script. Then use the numbered buttons:

1. **설정 검사** validates the local runtime paths.
2. **서비스 시작** starts the loopback sidecar and headless Koharu, then verifies that every family required by `config/translation-policy.json` is present in Koharu's live font catalog.
3. **프로젝트 가져오기** creates an empty project and imports the selected file or folder. If that project already contains pages, it is reopened without importing duplicates. This does not start translation.
4. **전체 번역 실행** starts the GPU pipeline only after an explicit confirmation. The launcher submits one page-sized full-pipeline job at a time, preventing Koharu stages from different pages from overlapping with the 128k Qwen reviewer on limited VRAM. Progress and successful-page checkpoints are aggregated across the whole project, so a later run can resume the verified prefix without resubmitting it. Cancellation is pinned to that logical run and its current page job, remains effective between pages, and never enters an automatic translation retry loop. Status polling tolerates only three consecutive transient failures and never submits a replacement page while recovering.
5. **문제 번역 검토** groups the pending work instead of exposing every audit row: exact live-matched metadata-only items can be approved together and are hidden from the exception grid; uncertain sound effects can be restored to their original page pixels together; and dialogue/narration is retried translation-only at most once per distinct page. Effect decisions on a page that still needs prose retry are deferred until after that retry so a later page job cannot recreate an effect layer that the operator removed. Remaining exceptions still show the Japanese source, Hy-MT2 draft, Qwen-reviewed translation, and a manual edit box. Accepting a translated decision applies the audited font role while preserving the layer's other typography. **원본 그림 유지** removes that region's translated layer and only its polygon-bounded cleanup. Infrastructure/setup failures do not consume the one retry, semantic failures do, and retries never loop automatically.

Shared Qwen startup is verified with a bounded five-check window and requires two consecutive exact-model readiness responses. A transient first probe therefore does not fail a page, while an unstable worker still stops deterministically without an automatic restart loop.
6. **내보내기** writes PNG or PSD results only after a successful full-project job. When the operator deliberately skips step 5 and presses export, one confirmation accepts every verified, currently applied, nonblocking translation as OK without regenerating it, then continues to export. Empty/unusable translations or missing live layers cannot be concealed by that shortcut. Export stages the complete page set before publishing and refuses an existing or nonempty destination, so a failed or repeated export cannot overwrite results.

**Web UI 열기** opens Koharu's detailed editor, **상태 새로고침** reports the active project and jobs, and **안전 종료** uses the repository's exact recorded process identities. Closing the launcher window does not silently stop a running service.

The progress bar reports the current button operation and, during translation, combines completed pages with the sidecar's current-page stage. The button just executed is blue and the next recommended button is green; persisted full-project completion is still recognized after a service restart. Path, runtime, port, format, and project controls are locked while a backend action is active, and cancellation uses the immutable settings snapshot from that action rather than any later UI value.

`config/translation-policy.json` is the single lettering policy used by both the sidecar and review UI. It maps audited logical font IDs to exact Koharu family names; in particular, the English `HS Yuji` role maps to Koharu's `HS유지체`, and the unavailable `Nanum Brush Script` choice is explicitly mapped to the installed `Nanum Pen` family. Every mapped family is checked while Koharu is idle during start or sidecar restart, so a missing font fails before translation instead of silently falling back. The sidecar deliberately does not call the font catalog from inside Koharu's synchronous translation callback, which would create a circular wait.

Machine-specific choices are saved to ignored `config/local.launcher.json`; they are not committed. During startup, the launcher backs up the user's Koharu config byte-for-byte, writes the Hy-MT2→Qwen session profile only long enough for headless Koharu to initialize, and immediately restores and verifies the original bytes. It refuses to switch profiles if another Koharu process is already running.

## Prepare Koharu

Clone the exact upstream revision into the repository-local `vendor/koharu` directory and apply the pinned patch:

```powershell
git clone https://github.com/mayocream/koharu.git vendor/koharu
git -C vendor/koharu checkout a81c5829ea99a45e04580ff97fd6affa81b2db34
pwsh -File .\scripts\apply-koharu-patch.ps1 -KoharuCheckout .\vendor\koharu
cargo build --manifest-path .\vendor\koharu\Cargo.toml -p koharu
```

The application script rejects a different commit, a dirty checkout, or a patch that does not pass `git apply --check`.

## Prepare Python and Hy-MT2

Create a repository-owned virtual environment. Install a CUDA PyTorch build using the command appropriate for the local driver, then install the remaining pinned packages:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
# Install a compatible CUDA build of PyTorch here.
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe .\scripts\download-model.py hy-mt2-7b
```

`download-model.py` downloads only the revision recorded in `config/model-lock.json` and writes a local SHA-256 manifest. It refuses any pre-existing destination, assembles and verifies a private sibling staging directory, and atomically renames that complete directory into place. The model directory is ignored by Git.

## Qwen lifecycle contract

The `-QwenLifecycleScript` argument is mandatory and machine-specific. Its script must support:

- `-Operation status -Summary`, returning JSON whose `qwen.state` and `comfyui` fields describe the current shared-runtime state. ComfyUI must be off before startup; Qwen coexistence is controlled by the lease below;
- `-Operation start-qwen`, returning exact `status`, `model`, and `context` plus `started_by_request: true` only when this call started the Qwen process; an already-ready exact process must return `started_by_request: false`;
- `-Operation stop-qwen`, available to the external operator for exact owned-process shutdown. The sidecar does not call it; it owns only the per-request lease, not the shared Qwen lifetime.

The launcher also requires a shared Qwen coordination directory and passes its `qwen-use.lock` path to the sidecar. Every translation request publishes foreground priority, acquires the lease before touching Qwen, and releases it after exact owned-process cleanup. Set `KOHARU_QWEN_LEASE_WAIT_SECONDS` on the sidecar only when a different finite wait is required.

The lifecycle implementation is deliberately not bundled because Qwen runtimes, launch commands, model locations, and GPU sharing policy differ by machine.

The sidecar bounds and observes the `start-qwen` lifecycle wrapper but does not place its externally owned Qwen child in the translation request's disposable Windows Job Object. Closing a page request therefore cannot kill a reusable Qwen server that the lifecycle started.

## Configure and run

When using the command-line scripts directly, configure Koharu's OpenAI-compatible provider to use model `koharu-hy-qwen-v1` and base URL `http://127.0.0.1:4020/v1`. The GUI launcher applies this profile temporarily and restores the user's original preferences after headless Koharu initializes.

Start both the sidecar and patched Koharu:

```powershell
pwsh -File .\scripts\start.ps1 `
  -QwenLifecycleScript C:\path\to\your\Invoke-QwenLifecycle.ps1 `
  -HyModelDirectory C:\path\to\hy-mt2-7b `
  -QwenLeasePath C:\path\to\shared-coordination\qwen-use.lock
```

Then open `http://127.0.0.1:4010/`. The JSON API is rooted at `/api/v1`, and the MCP JSON-RPC endpoint is `/mcp`.

Stop only the processes recorded by this repository:

```powershell
pwsh -File .\scripts\stop.ps1
```

`stop.ps1` validates each recorded executable path, start time, parent PID, creation time, and complete command line before touching a PID. If identity has changed, it retains state and refuses the stop.

`restart-sidecar.ps1` applies the same exact-identity checks without restarting Koharu. It records the stopped transition before replacement and, if startup fails, stops only newly recorded exact sidecar identities and persists a recovery status instead of leaving an apparently healthy stale record.

## Verification

Run the portable checks:

```powershell
.\.venv\Scripts\python.exe -m unittest discover -v
.\.venv\Scripts\python.exe -m py_compile service\server.py service\test_server.py scripts\download-model.py scripts\hy-translate-request.py
pwsh -NoProfile -File .\scripts\tests\launcher-core.tests.ps1

$scripts = Get-ChildItem .\scripts -Recurse -Include *.ps1,*.psm1
foreach ($script in $scripts) {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw ($errors | Out-String) }
}
```

For the patched Koharu checkout:

```powershell
cargo test --manifest-path .\vendor\koharu\Cargo.toml -p koharu-app api::tests
cargo test --manifest-path .\vendor\koharu\Cargo.toml -p koharu-pipeline onomatopoeia_becomes_a_sound_effect_text_layer
cargo test --manifest-path .\vendor\koharu\Cargo.toml -p koharu-translator serializes_optional_koharu_region_metadata
cargo build --manifest-path .\vendor\koharu\Cargo.toml -p koharu
```

The CI workflow runs the portable Python tests, Python compilation, and PowerShell parser checks. Full Koharu builds and GPU/model tests remain local because they require platform-specific native and model inputs.

## Limitations

- The patch is intentionally pinned to one Koharu commit; it is not claimed to apply to later revisions.
- The pipeline currently targets Japanese-to-Korean text and a fixed lettering-role policy.
- End-to-end operation requires an operator-supplied Qwen lifecycle implementation and model.
- Automated and live functional validation do not replace manual source review or an independent security audit.

## AI development disclosure

Most downstream modifications were generated and revised by OpenAI Codex from user-provided requirements and iterative acceptance requests. The repository owner did not manually review the source code. Validation is based on automated tests and live functional testing in the owner's Windows/Codex environment. No independent third-party code or security audit has been performed.

**In short:** AI-generated, user-tested, not manually code-reviewed.

## Upstream attribution and license

The Koharu patch is based on Koharu by mayocream and contributors at the exact commit identified above. See `THIRD_PARTY_NOTICES.md` for dependency boundaries and attribution. This repository is offered under your choice of the Apache License 2.0 or MIT License; see `LICENSE-APACHE` and `LICENSE-MIT`.
