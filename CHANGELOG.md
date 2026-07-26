# Changelog

## Unreleased

## v2.3.0

### Bug fixes

- Fixed a crash after successful dictation when Ogma tried to preserve a nonempty clipboard. Clipboard items are now snapshotted representation-by-representation instead of receiving an unsupported Objective-C `copy()` message.
- Voxtral now uses `mlx-audio`'s stateful streaming caches instead of repeatedly decoding the entire recording. Detailed mode receives live Voxtral text; None and Simple run the higher-quality stream silently and only publish the final.

### Menu and recording controls

- **Backend** is now **TTS Engine** and leads the TTS controls; **Engine** is now **STT Engine** and leads the Dictation controls.
- **Sentence Pause** now closes the TTS section, while the standalone **Speed Read…** action has moved to the bottom of the menu.
- A new **Recording Indicator** setting offers **None** (animated menu-bar waveform only), **Simple** (speech-responsive audio meter with a Stop Recording button), and **Detailed** (the existing live transcript card).
- **Improve Dictation / Share Corrections** has been removed. Dictation audio, transcripts, and edits remain on-device.
- **Future — not in this build:** additional opt-in API engines for audio generation or transcription.

### Highlights

**A second dictation engine: Voxtral Realtime 4B.** A new **STT Engine** picker in the Dictation menu offers **Voxtral (best accuracy)** alongside the default **Parakeet (fast)**. Voxtral runs a language-model decoder, so transcripts come out with markedly better grammar, punctuation, and sentence structure — the things n-gram autocorrect could never fix. It's an opt-in ~3.2 GB Apache-2.0 download (4-bit MLX quantization, via `mlx-audio`), entirely on-device like everything else.

### Details

- **The live transcript IS Voxtral**: Detailed mode displays text from Voxtral's stateful streaming decoder, while None and Simple advance the same transcript silently — no repeated full-recording decodes and no jarring model swap when you stop
- **One model in memory at a time** (~3.5 GB in Voxtral mode); if Voxtral can't load, the daemon falls back to Parakeet and dictation keeps working
- Confidence tinting and ↻ suggestion chips remain a Parakeet feature (Voxtral reports no per-word confidences; its transcripts rarely need them)
- Shared corrections were tagged with the engine that produced the final. This sharing feature is removed in the current build.
- `STT_ENGINE="voxtral"` / `"parakeet"` in `~/.config/ogma/config`; install via the menu or `bash install-local.sh --with-voxtral`
- Voxtral gets the same lead-in-silence onset fix that v2.2.2 gave streaming and uses deterministic decoding so verbatim repeats remain stable

## v2.2.2

### Bug fixes

- **Cleaner first word.** Dictation now prepends a short lead-in of silence (300ms) to the audio stream before your first spoken word, so the streaming model decodes the word's onset with real left context instead of catching it at the very edge of the buffer. This most often garbled the opening word or two — especially on a cold start, where you tend to start talking the instant you press `⌥⇧D`. Tunable via `STT_LEAD_SILENCE` (seconds; `0` disables).

## v2.2.1

### Bug fixes

- **Dictation now inserts into terminals and other Accessibility-opaque apps.** Pressing Insert on the review card pasted at the cursor in most apps, but silently fell back to *"Transcript copied — press ⌘V"* whenever the target app exposed no focused element to Accessibility — GPU-rendered terminals (Ghostty and others) and some Electron/web views. A synthetic ⌘V lands in those apps perfectly, so Ogma now pastes there directly instead of giving up.
- The clipboard fallback is now reserved for **secure-input (password) fields**, the one place a synthetic keystroke genuinely cannot go. Everywhere else, the paste is attempted — and it is **fail-safe**: if a paste ever misses (no editable focus, focus vanished), the transcript is left on the clipboard for a manual ⌘V rather than being restored over, so it can never be lost.

## v2.2.0

### Highlights

> Historical note: this opt-in sharing feature was introduced in v2.2.0 and has been removed from the current build.

**Help fix what dictation gets wrong — opt-in.** A new **Improve Dictation → Share Corrections** setting (off by default) sent review-card corrections to Stover Distributed so recognition errors could be analyzed. Only text was shared; audio was never sent.

### Details

- Consent dialog on opt-in spells out exactly what leaves the machine; **What Gets Shared…** shows it again anytime
- Corrections queue locally (`~/.local/share/ogma/corrections.jsonl`) and upload in batches with offset tracking — nothing is lost offline, nothing is sent twice
- `SHARE_CORRECTIONS="false"` in `~/.config/ogma/config` (or the menu toggle) turns it off; the local log stays yours

## v2.1.0

### Highlights

**One-click setup.** First launch now opens with **Install Everything** — one click configures cloud voices and downloads the on-device speech models (Kokoro for reading aloud, Parakeet for dictation, ~3 GB) in the background. **Customize…** keeps the old pick-your-backend flow for people who want to choose the pieces themselves.

### Improvements

- **Dictation for cloud users**: choosing *ElevenLabs Only* now offers to install the local dictation engine too — speech-to-text is independent of which voices you listen with
- **No more dead ends**: pressing `⌥⇧D` before the dictation engine is installed now offers to install it on the spot, instead of pointing you at the menu
- **Honest download sizes**: install dialogs now say ~3 GB (Kokoro + Parakeet + dependencies) instead of quoting only the 350 MB Kokoro model

## v2.0.0

### Highlights

**Native installer package.** Ogma now ships as a standard macOS `.pkg` — download, double-click, done. The app arrives prebuilt as a universal binary (Apple Silicon + Intel, macOS 13+), so **Xcode Command Line Tools are no longer required**. First-run setup moved from the installer script into the app itself: choose your backend, paste your API key, and the local models download in the background — all from the menu bar app. The helper scripts install themselves into `~/.local/bin` on first launch and re-sync automatically after every update. `install.command` still works for source installs.

**Ogma** — a fork of [Speak11](https://speakeleven.com), named for the Celtic god of eloquence who invented the Ogham script: the deity of both speech and writing, which is exactly what this app does. The icon is the name "OGMA" written in real Ogham strokes on a stemline, carved cream-on-green. Same public-domain license (Unlicense) as the upstream project. Everything below the fork point — the review card, word confidence, autocorrect, stabilized live transcripts — is Ogma.

**Local dictation with an interactive review card.** Press `⌥⇧D` and talk — a floating caption shows the live transcript, wrapping and growing vertically as you speak (Parakeet STT via parakeet-mlx, fully local, Apple Silicon). Press `⌥⇧D` again and the caption becomes a review card: **✓ Insert** (`Return`) pastes at your cursor, clicking the text lets you edit it first (typed edits render gray), **✗ Discard** (`Esc`) throws it away, and `⌥⇧D` dictates *more* into the transcript at the caret. A "Review before insert" menu toggle restores the old paste-immediately behavior.

**Word-level confidence display.** The STT daemon reports per-word confidence derived from Parakeet's token scores. Words the model wasn't sure about are tinted yellow (uncertain) or red + underlined (probably wrong) in both the live caption and the review card. Clicking a flagged word pops a tiny ✓/✕ chip to keep or cut it, with a gray explainer line at the bottom of the card. Thresholds calibrated against live model output (correct words on clean audio score ≥0.96; misrecognitions ~0.79–0.87; noise hallucinations <0.55).

### New features

- **Dictation** (`stt_server.py` + `Ogma.swift`): push-to-talk speech-to-text with a warm-model daemon (Unix socket, idle auto-unload, menu-bar load/unload toggle + countdown, `STT_IDLE_TIMEOUT` config), live streaming captions, and paste-at-cursor
- **Review card**: non-activating floating panel that can take keyboard focus without stealing your app's frontmost status (Spotlight-style); grows with the transcript and scrolls past 40% of screen height; won't grab the keyboard if you've typed since stopping — click it to arm
- **Word confidence protocol**: daemon partials/finals/one-shot responses carry `words: [{text, confidence}]`; the word list is derived from the transcript text itself so the display always matches what gets inserted; older app/daemon combinations keep working
- **Insert that can't lose your words**: the paste verifies a focused UI element in the frontmost app (via Accessibility), detects secure-input (password) fields, and re-activates the original target if needed — and when no safe paste target exists, the transcript is copied to the clipboard with an on-screen notice instead of being dropped
- **Personal dictionary**: names and jargon you list are offered as one-click ↻ replacements when dictation mishears them (phonetic matching: "Zantipi" finds `Xanthippe`), are never autocorrected away, and reload live on every edit — editable from the menu bar (**Dictionary…**) or directly at `~/.config/ogma/dictionary.txt`
- **Filler words removed**: *um, uh, er, hmm…* never make it into the transcript — filtered live from the very first partial, with capitalization and punctuation repaired at each removal point. `FILTER_FILLERS="false"` in the config keeps them
- **Context autocorrect for shaky words**: an old-school n-gram + phonetics engine (Norvig word/bigram counts + metaphone matching, ~10 MB, no LLM) checks each low-confidence word against its sentence context; when a phonetically similar word fits far better, the word's ✓/✕ chip gains a one-click "↻ replacement" button. Suggest-only — it never rewrites anything by itself, and unknown proper nouns are left alone
- **Speak the card**: select text in the review card and press `⌥⇧/` to hear it read aloud
- **Hotkey auto-recovery**: the app re-arms its global hotkeys automatically after Accessibility permission is toggled or the event tap dies — no relaunch needed
- **Test isolation**: `OGMA_DATA_DIR` runs an isolated STT daemon (own socket, lock, and config) for the new live end-to-end streaming test

### Bug fixes

- The dictation card no longer vanishes mid-recording when you switch apps while Ogma is the active app (e.g. after starting dictation from the menu bar): panels hide on app-deactivate by default, so the mic stayed hot with nothing on screen
- Live transcripts are stabilized (local-agreement): a word is committed once two consecutive decodes agree on it and is never rewritten on screen afterwards — only the last couple of words keep revising while you talk
- Clipboard restore after paste is guarded by a pasteboard change count and waits 1s, so a busy target app pastes the transcript rather than the restored old clipboard, and a copy made meanwhile is never clobbered
- Stale dictation sessions (slow daemon, abandoned recordings) can no longer hijack or tear down a newer session: finals are matched to their session, the teardown fallback is generation-guarded, and orphaned socket clients close instead of wedging the single-flight daemon
- Held-down hotkeys no longer thrash start/stop (key autorepeats are consumed)
- A second `⌥⇧D` during the microphone-permission prompt can no longer double-start recording

## v1.1.0

### Highlights

**Gapless playback.** A native Swift audio queue player replaces per-sentence `afplay` calls, cutting the gap between sentences from ~970ms to ~30ms. A configurable pause (default 400ms at 1× speed) restores natural speech rhythm and scales automatically with your speed setting. Adjustable from the menu bar -- click "Sentence Pause" and type any value in milliseconds.

**Text normalizer.** A new 6-phase Python preprocessor turns PDFs, LaTeX, and Markdown into clean, speakable text. It combines general-purpose normalization (currency, abbreviations, Unicode cleanup) with domain-specific handling for technical and scientific content (LaTeX math, SI units, Greek letters). Separate front-ends for PDF, LaTeX, and Markdown input clean up format-specific artifacts before the text reaches the TTS engine.

### New features

- **Audio queue player** (`ogma-audio.swift`): gapless sentence playback via `AVAudioPlayer` queue with `CoreAudio` mute detection, replacing the old afplay-per-sentence approach
- **Sentence pause**: configurable inter-sentence silence (0--1000+ ms) that scales inversely with playback speed; free-form input from the menu bar
- **Text normalizer** (`normalize.py`): 1200-line preprocessor with general and domain-specific rules:
  - *General*: currency (`$1.5M` reads as "1.5 million dollars"), abbreviations (`e.g.`, `i.e.`, `et al.`), math symbols (`±`, `×`, `∞`), Unicode cleanup via ftfy
  - *Scientific*: LaTeX math environments (`equation`, `align`, `matrix`, `cases`, fractions, superscripts, subscripts), SI units and compound units (`kg/m³`, `kPa`, `nm`, `°C`, `kcal/mol`), Greek letters (`\alpha`, `\beta`, including diacritics and final sigma), Miller crystallographic indices (`(111)`, `[110]`), set theory symbols (`∈`, `⊂`, `∪`)
  - *PDF front-end*: rejoins mid-word line breaks, strips superscript citations, removes page headers
  - *LaTeX front-end*: converts math environments, commands, and macros into spoken text
  - *Markdown front-end*: strips YAML front matter, wikilinks, callout syntax, inline code, HTML tags

### Performance

- Audio queue player eliminates ~970ms inter-sentence overhead (down to ~30ms hardware latency)
- Test suite runs in ~36s, down from ~2min, with section filtering (`--fast`, `--section`)
- ftfy is now a required dependency for reliable Unicode normalization

### Bug fixes

- Bare URLs (`go.nature.com/4rzrnyx`) verbalized as "go dot nature dot com slash 4rzrnyx" so local TTS reads dots and slashes correctly
- PDF mid-word newlines: text copied from PDFs no longer has spurious line breaks inside words and sentences
- Compound hyphen rejoining across PDF line breaks
- Superscript citations glued to sentence-ending periods (e.g., `result.²³` now strips cleanly)
- Nested LaTeX environments (`\begin{equation}\begin{cases}...\end{cases}\end{equation}`)
- Nested bold/italic in Markdown (`***bold italic***`)
- `\left\langle` / `\right\rangle` bracket commands
- Chained equals signs in equations (`a = b = c`)
- Dollar signs inside math environments (`\$`)
- Scientific notation (`3\times10^{5}`, negative exponents)
- `\cfrac` (continuous fractions)
- Unit slash not triggering false positives on `s/he`
- Greek final sigma (`ς`) spoken as "sigma"
- Greek letters with tonos diacritics
- Star-prefixed lists not breaking italic regex
- siunitx edge cases and unit joining
- Denominator singular vs plural (`per mole` not `per moles`)
- Matrix environments inside equation wrappers
- `SCRIPT_DIR` ordering bug in speak.sh
- Terminal no longer minimizes during install/uninstall

### Infrastructure

- Repo-local dev venv for the test suite
- Always uses the venv Python interpreter, never falls back to system python3
- `VENV_PYTHON` guards on `split_sentences` and `run_local_tts`
- Test suite expanded from ~200 to 1066 tests
- Profiling script (`tests/profile.sh`) for end-to-end pipeline timing

## v1.0.0

Initial release.
