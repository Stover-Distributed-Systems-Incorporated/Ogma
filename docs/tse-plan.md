# Target Speaker Extraction (TSE) — execution plan

*Goal: Ogma transcribes only the enrolled user, even when other people are
talking — by extracting the user's voice from the audio before Parakeet sees
it. Supersedes the gate-only sketch in [voice-filter-design.md](voice-filter-design.md)
(the gate survives as the cheap fallback mode and auto-bypass check).*

Constraints, same as everything in Ogma: **local-only, opt-in (default off),
Apple Silicon, streaming** alongside the existing Parakeet pipeline in
`stt_server.py` (16 kHz mono). Voice profile never leaves the machine.

The user records their own enrollment and evaluation audio by reading
generated scripts — so ground-truth transcripts are known *exactly*, and WER
can be computed without any labeling work. Threshold tuning is explicitly
not a concern; the eval harness sweeps thresholds automatically.

---

## Phase 0 — Recording kit + ground truth (1–2 days of build, ~30 min of reading)

Build `tools/tse/`:

- **`make_scripts.py`** — emits numbered, timestamped reading scripts:
  - `enroll.txt` (~3 min read): phonetically balanced material — Harvard
    sentences (public domain) + numbers, spelled words, and command-ish
    phrases matching real dictation.
  - `eval_01..05.txt` (~2 min each): held-out sentences, never used for
    enrollment. These become the WER ground truth.
- **`record.py`** — guided recorder: shows one sentence at a time, records
  16 kHz mono WAV per script via the Mac mic, warns on clipping/silence.
  Output: `recordings/enroll.wav`, `recordings/eval_XX.wav`.
- **Interference bank** — no second human needed:
  - Synthesize interferers with Ogma's own Kokoro voices (12 voices,
    American + British, both sexes) reading *different* known scripts.
  - Optionally add LibriSpeech test-clean utterances for non-TTS realism.
- Also capture 2–3 *real-world* takes (dictate near a TV / podcast playing)
  for sanity checks — synthetic mixes are the controlled measurement,
  real takes are the smoke test.

## Phase 1 — Offline evaluation harness (2–3 days)

- **`mix.py`** — combine clean user eval audio with interference at
  SIR = {+10, +5, 0, −5} dB, in three overlap patterns: interferer-only
  gaps, fully overlapped speech, and turn-taking.
- **`evaluate.py`** — run any candidate front-end (or none) → Parakeet →
  report per condition:
  - **User WER** vs the known script text
  - **Bystander leak rate**: fraction of interferer-script words that appear
    in the output (this is the metric for the complaint that started this)
  - Real-time factor (RTF) on this machine
- **Baseline run with no front-end** — quantifies how bad the damage is at
  each SIR before we fix anything. Also run the v-next *embedding gate* as
  the control every TSE model must beat.

## Phase 2 — Model bake-off (3–5 days)

- **Enrollment embedding** (shared by gate, bypass check, and TSE
  conditioning): WeSpeaker ResNet34 or ECAPA-TDNN, ONNX, CPU real-time.
  Profile = mean embedding over `enroll.wav`, stored at
  `~/.local/share/ogma/voice-profile.npz`.
- **TSE candidates**, all conditioned on the profile embedding:
  1. **WeSep** pretrained checkpoints (BSRNN-TSE first — best
     quality/compute balance; TF-GridNet-TSE as the quality ceiling)
  2. **SpEx+** public checkpoints
  3. Embedding **gate** (control / fallback)
- Selection criteria on the Phase 1 harness: WER recovery and leak rate
  vs **RTF < 0.5** at ~1 s chunks on Apple Silicon (onnxruntime CPU first;
  CoreML/MPS only if needed).
- **Domain-mismatch escape hatch**: public checkpoints are trained on
  LibriMix-style data; if real-mic quality disappoints, fine-tune the winner
  on synthetic mixtures built from the user's own recordings (we own the
  clean sources — cheap to generate thousands of mixtures).
- Export winner to ONNX. Runtime dependency: `onnxruntime` only — PyTorch
  stays a dev-side tool, never shipped in the user venv.

## Phase 3 — Streaming integration (~1 week)

- `stt_server.py` audio path: mic chunks → ring buffer with 0.5–1 s
  lookahead → TSE with overlap-add windows → Parakeet. Live-partial
  stabilization (local agreement) already tolerates late revisions, which
  absorbs the added lookahead.
- **Auto-bypass**: cheap embedding similarity per window; if recent audio is
  single-speaker-user, skip TSE entirely — zero added latency in the quiet
  common case.
- Config: `VOICE_FILTER="off" | "gate" | "extract"` (default `off`).
- **Failure semantics: any TSE error → transparent bypass.** Dictation must
  never break because the filter did.

## Phase 4 — Productization (2–3 days)

- Menu: **Voice Filter (only my voice)** toggle + **Re-enroll Voice…**
  (launches the Phase 0 recorder flow with `enroll.txt`).
- Passive enrollment option: after N accepted dictations, offer to build the
  profile from audio of sessions the user inserted unedited.
- Startup RTF probe: machines too slow for `extract` degrade to `gate`.
- README/CHANGELOG, ship default-off.

---

## Success criteria (0 dB SIR, fully overlapped — the hard case)

- Bystander leak rate **< 5 %** of interferer words (baseline will likely be > 50 %)
- User WER within **15 % relative** of the clean-audio baseline
- Added latency **< 300 ms p50**; RTF **< 0.5** on an M1
- `off` mode bit-identical to today's pipeline

## Risks

| Risk | Mitigation |
|------|------------|
| Pretrained TSE degrades on real Mac-mic audio | Fine-tune on synthetic mixes from the user's own recordings (Phase 2 escape hatch) |
| Streaming latency from lookahead | Overlap-add chunks + auto-bypass; local-agreement partials already tolerate revision |
| Overlapped-speech quality below target | Ship `gate` mode as the honest fallback; it still fixes the turn-taking case |
| Dependency weight | onnxruntime-only at runtime; models ≤ ~100 MB, downloaded with the rest of the local engine |

## Immediate next steps (post-compact)

1. Build `tools/tse/make_scripts.py` + `record.py` (Phase 0)
2. User reads and records: `enroll.txt` + 5 eval scripts (~15 min total)
3. Generate the Kokoro interference bank + mixtures, run the no-front-end
   baseline (`evaluate.py`) to measure today's damage
4. Bake-off
