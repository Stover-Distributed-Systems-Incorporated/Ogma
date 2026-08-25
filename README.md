<p align="center">
  <img src="icon.svg" width="96" height="96" alt="Ogma icon">
</p>

<h1 align="center">Ogma</h1>

<p align="center">
  Select text in any app, press <kbd>⌥</kbd><kbd>⇧</kbd><kbd>/</kbd>, hear it read aloud.<br>
  Press <kbd>⌥</kbd><kbd>⇧</kbd><kbd>D</kbd> and talk — your words appear at the cursor (local, Apple Silicon).<br>
  Cloud TTS via <a href="https://elevenlabs.io">ElevenLabs</a>, or local TTS via <a href="https://github.com/Blaizzy/mlx-audio">Kokoro</a> (Apple Silicon).<br>
  Runs in your menu bar.
</p>

<p align="center">
  <a href="https://unlicense.org"><img src="https://img.shields.io/badge/license-Unlicense-green" alt="License: Unlicense"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey" alt="macOS 13+">
</p>

---

## Why this exists

Mac voice tools have a racket going: **$49** for a text-to-speech utility here, a monthly subscription for dictation there — for things your computer should just *do*. This project is the counter-argument:

- **Free. Actually free.** No license key, no trial, no upsell. It's public domain ([Unlicense](https://unlicense.org)) — you can't even pay for it.
- **Open source.** Read every line before you trust it with your voice.
- **Private.** The models run locally on your own silicon. Your audio and your words never have to leave the machine.
- **Easy.** Two hotkeys. `⌥⇧/` reads anything to you. `⌥⇧D` types anything you say.

If you were about to spend $49 on this: don't.

## Lineage

Ogma is a **fork of [Speak11](https://speakeleven.com)** — Speak11 remains its own project. The fork adds the interactive dictation review card, word-level confidence highlighting, context autocorrect, stabilized live transcripts, and more. Ogma keeps Speak11's public-domain license, so everything flows freely in both directions.

> **Running both?** They coexist (Ogma keeps its data in `~/.local/share/ogma` and `~/.config/ogma`), but both install helper scripts with the same names into `~/.local/bin` — whichever you install last wins those. Pick one for daily use.

## Requirements

- macOS Ventura (13) or later
- **Cloud TTS:** a free [ElevenLabs account](https://elevenlabs.io) and API key
- **Local TTS:** Apple Silicon (M1 or later) — Python is downloaded automatically if needed
- **Optional Intent Rewrite:** an OpenAI or Anthropic API key, or any local/remote OpenAI-compatible server

## Installation

1. [Download **Ogma.pkg**](../../releases/latest/download/Ogma.pkg) and double-click it
2. **First open only:** macOS will refuse to open it, because the package isn't notarized (that requires a $99/yr Apple Developer subscription — this app is free). Approve it once:
   - **macOS 15 (Sequoia) and later:** open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Ogma message, then confirm
   - **macOS 13–14:** Control-click `Ogma.pkg` → **Open** → **Open**
3. Click through the installer — Ogma launches automatically when it finishes
4. On first launch, click **Install Everything** (recommended): the on-device speech models — Kokoro for reading aloud, Parakeet for dictation — download in the background (~3 GB, Apple Silicon), and you can add a free ElevenLabs key for cloud voices. Prefer to pick the pieces yourself? Click **Customize…** instead and choose exactly which backend and models get installed.

The app is a prebuilt universal binary (Apple Silicon + Intel) — no developer tools needed. Everything keeps working while the models download; you're notified when they're ready.

> **Getting your API key:** sign in at [elevenlabs.io](https://elevenlabs.io) → click your profile icon → **Profile + API Key** → create or copy a key. The key needs the **Text-to-Speech** and **User Read** permissions enabled (User Read lets the menu bar show your remaining credits).

> **Local TTS note:** if no Python 3.10–3.12 is found on your system, a standalone Python (~17 MB) is downloaded automatically (the local TTS engine's `misaki==0.8.4` dependency does not support Python 3.13+). The Kokoro voice model (~350 MB) is also downloaded during installation.

> **Prefer to build from source?** [Download the source zip](../../releases/latest/download/ogma.zip), unzip, and double-click `install.command` — it compiles the app on your machine (requires Xcode Command Line Tools, which it offers to install).

### First use

Once installed, the **waveform icon** appears in your menu bar. On first launch the app will ask for Accessibility permission — click **Allow** so it can register the global hotkey.

- **Select any text** in any app → press `⌥⇧/` → audio plays
- **Press `⌥⇧/` again** while audio is playing → stops immediately
- **Press `⌥⇧D`** and talk → a live caption shows what's being heard → press `⌥⇧D` again → review the transcript, then press **Return** to insert it at your cursor (local dictation, Apple Silicon)

The waveform icon pulses while audio is being generated and played, so you always know it's working.

Text copied from PDFs, LaTeX documents, and Markdown files is automatically cleaned up before reading -- math equations, SI units, Greek letters, citations, and formatting artifacts are converted to natural spoken language.

API keys are stored separately in your macOS Keychain — never written to the config file. Speech recognition and audio always remain on your Mac. Dictation transcripts also remain local by default; enabling a remote **Intent Rewrite** provider sends only the final transcript text to that provider, after an explicit disclosure in the settings dialog.

## Settings

Click the **waveform icon** in the menu bar. The menu adapts to your setup — you only see settings that apply. Use **TTS Engine** at the top to switch between **Auto** (cloud + local fallback), **ElevenLabs** (cloud only), and **Local** (offline only).

### ElevenLabs settings

| Setting | Options |
|---------|---------|
| **Voice** | Popular presets or a custom voice ID |
| **Model** | v3 · Flash v2.5 · Turbo v2.5 · Multilingual v2 |
| **Speed** | 0.7× to 1.2× |
| **Stability** | 0.0 (expressive) to 1.0 (steady) — controls pitch and pacing variation |
| **Similarity** | 0.0 (low) to 1.0 (high) — how closely output matches the original voice |
| **Style** | 0.0 (none) to 1.0 (max) — amplifies the voice's characteristic delivery; adds latency |
| **Speaker Boost** | On / Off — subtle enhancement to voice similarity |

### Local (Kokoro) settings

| Setting | Options |
|---------|---------|
| **Voice** | 12 curated English voices (American and British) |
| **Speed** | 0.5× to 2× |

### Dictation (Parakeet / Voxtral STT, Apple Silicon)

Press `⌥⇧D` to start dictating anywhere. The default **Detailed** recording indicator shows the live transcript as you speak. Press `⌥⇧D` again to stop; when **Review before insert** is enabled, the final transcript appears in an interactive review card:

- **✓ Insert** (`Return`) — insert the transcript at your cursor using the selected **Insert Method**. Click into another app first to redirect it there.
- **Edit** — just click the text and type; your edits show in gray so you can tell them apart from the transcription. `Shift+Return` adds a newline.
- **✗ Discard** (`Esc`) — throw it away.
- **`⌥⇧D` again** — dictate *more*, straight into the transcript at the cursor (to re-record from scratch, discard first).

Words the model wasn't sure about are tinted **yellow** (uncertain) or **red + underlined** (probably wrong), so you can spot-check exactly the shaky parts before inserting. Click a highlighted word and a tiny **✓ / ✕** chip pops up — keep it or cut it with one click. When a phonetically similar word fits the sentence context much better, the chip also offers a one-click **↻ replacement** (classic n-gram autocorrect — local, no LLM, and it never rewrites anything on its own). You can even select text in the card and press `⌥⇧/` to hear it. If the insertion target disappears, the transcript is copied to the clipboard instead — it is never lost.

Filler words (*um, uh, er, hmm…*) are removed automatically — they never even appear in the live transcript, and capitalization is repaired where they're dropped. Set `FILTER_FILLERS="false"` in `~/.config/ogma/config` if you want them kept.

**Intent Rewrite (optional):** after local speech recognition finishes, Ogma can ask an LLM to produce the text you meant to write. It resolves spoken revisions and false starts—for example, *“Today I got ice cream—no, wait—licorice”* becomes *“Today I got licorice.”*—while preserving meaning instead of answering or acting on the dictated text. Choose **OpenAI**, **Anthropic**, or **OpenAI-compatible (local or remote)**. Provider, model, endpoint, timeout, and credentials are configurable; keys stay in Keychain. OpenAI requests use the Responses API with storage disabled. Local servers default to Ollama's `http://127.0.0.1:11434/v1` compatibility endpoint, but LM Studio and other OpenAI-compatible endpoints work too. Plain HTTP is accepted only on loopback; remote endpoints must use HTTPS.

While a rewrite is in flight, the overlay says **Refining transcript…** and ignores repeat hotkeys. If the request times out, is rejected, returns malformed/empty output, or expands suspiciously, Ogma uses the original transcript. With review enabled the card says so explicitly; with immediate insertion the same target-safe fallback is used. Rewritten words do not display STT confidence colors because their positions no longer correspond to the recognizer's tokens.

**Personal dictionary:** click **Dictionary…** in the menu to add names and jargon (one word per line, `#` for comments — it's a plain file at `~/.config/ogma/dictionary.txt` if you prefer an editor; changes apply immediately either way). When dictation mishears one of your words, the chip offers it as the ↻ replacement — matching is *phonetic*, so `Xanthippe` is found even when the model heard "Zantipi". Your dictionary words are also protected: autocorrect will never suggest changing them.

**STT Engine:** two on-device models are available under **STT Engine** at the top of the Dictation section. **Parakeet** (default, ~2.4 GB) is fast and light, with sub-second live updates. **Voxtral** (Voxtral Realtime 4B, an extra ~3.2 GB Apache-licensed download on first selection) runs a language-model decoder for noticeably better grammar, punctuation, and sentence structure. Voxtral incrementally caches each audio chunk instead of re-decoding the recording: Detailed mode shows its live text, while None and Simple advance the same high-quality transcription silently for near-instant finalization. Only one model is in memory at a time; if Voxtral ever fails to load, dictation automatically falls back to Parakeet. Confidence highlighting and ↻ suggestions apply to Parakeet transcripts only — Voxtral doesn't report per-word confidence.

| Setting | Options |
|---------|---------|
| **STT Engine** | Parakeet (fast, default) or Voxtral (best accuracy — better grammar and punctuation, ~3.5 GB in memory while loaded). |
| **Recording Indicator** | **None:** animated menu-bar waveform only. **Simple:** animated menu-bar waveform plus a compact speech-responsive audio meter and Stop Recording button. **Detailed** (default): the existing live transcript card. |
| **Review before insert** | On (default) — show the review card when dictation stops. Off — insert immediately, as if the card didn't exist. |
| **Intent Rewrite** | Off (default), OpenAI, Anthropic, or an OpenAI-compatible local/remote endpoint. Configure model, endpoint, key, and timeout from the submenu. |
| **Insert Method** | **Paste all at once** (default), or type the transcript as ordinary key events at 60, 120, 240, or a custom WPM. Paced typing helps web editors that mishandle a large paste event. |
| **Auto-unload after** | How long the speech model stays in memory after the last dictation (default 2 minutes). |

### Playback settings

| Setting | Options |
|---------|---------|
| **Sentence Pause** | Milliseconds of silence between sentences (default 400ms). Scales inversely with speed -- at 2× speed, a 400ms pause becomes 200ms. Click the menu item and type any value; set to 0 for no pause. |

Settings take effect immediately — no restart needed.

### ElevenLabs voices

| Name | Style |
|------|-------|
| Lily | British, raspy |
| Alice | British, confident |
| Rachel | Calm |
| Adam | Deep |
| Domi | Strong |
| Josh | Young, deep |
| Sam | Raspy |

You can also enter any voice ID from the [ElevenLabs Voice Library](https://elevenlabs.io/voice-library) via **Voice → Custom voice ID…** in the menu.

### Kokoro voices

| Name | Style |
|------|-------|
| Lily | British, bright (default) |
| Heart | Warm |
| Bella | Soft |
| Nova | Confident |
| Sarah | Gentle |
| Sky | Bright |
| Adam | Deep |
| Echo | Clear |
| Eric | Steady |
| Michael | Warm |
| Emma | British, warm |
| George | British, deep |

## Uninstall

Double-click **`uninstall.command`** — it removes everything including the Accessibility permission, login item, API keys, and app bundle.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `⌥⇧/` does nothing | Grant Accessibility permission when prompted, or check System Settings → Privacy & Security → Accessibility. The app re-checks every few seconds and recovers automatically once permission is granted |
| `⌥⇧D` does nothing | Same Accessibility check as above, plus Microphone permission (System Settings → Privacy & Security → Microphone). If the local engine isn't installed yet, pressing `⌥⇧D` offers to install it (Apple Silicon) |
| Waveform icon not in menu bar | Open `/Applications/Ogma.app` (pkg installs) or `~/Applications/Ogma.app` (source installs) manually |
| HTTP 401 | API key is wrong or expired — update it via the menu bar icon → **API Key…** |
| HTTP 429 | Monthly character quota exceeded — if both backends are installed, the app automatically falls back to local TTS. On Apple Silicon with ElevenLabs only, it will offer to install local TTS as a free alternative |
| Intent Rewrite uses the original transcript | Open **Intent Rewrite → Configure…** and check the model, API key, endpoint, and timeout. Remote compatible endpoints require HTTPS; local HTTP endpoints must use `localhost`, `127.x.x.x`, or `::1`. Provider failures are logged to Console under Ogma without transcript contents. |
| "python3 not found" | Run `xcode-select --install` in Terminal |
| Settings app fails to compile *(source installs only)* | Check `~/.local/share/ogma/install.log` for the error. Usually fixed by updating Command Line Tools: `sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install` |
| Local TTS is slow | Check `~/.local/share/ogma/tts.log` for errors. The TTS daemon keeps the model loaded and warmed up in memory so requests are near-instant |
| Audio playback issues | Set `OGMA_NO_QUEUE_PLAYER=1` to fall back to afplay (slower but simpler). If that fixes it, the issue is with the audio queue player — re-run `install.command` to rebuild it |

## Cost

**ElevenLabs:** the free tier includes a monthly character allowance — usually sufficient for casual read-aloud use. Paid plans start at $5/month. See [elevenlabs.io/pricing](https://elevenlabs.io/pricing).

**Local (Kokoro):** completely free. Runs on your Mac with no API calls or credits. Requires Apple Silicon and a one-time ~350 MB model download.

**Intent Rewrite:** local OpenAI-compatible servers are free aside from your hardware. OpenAI and Anthropic usage is billed by those providers according to the model you configure; Ogma sends one text-only request per completed dictation when enabled.

## License

[Unlicense](LICENSE) — public domain. Speak11 created by [Stefano Martiniani](https://github.com/smcantab); the Ogma fork is maintained by [Stover Distributed](https://stoverdistributed.com).

---

<details>
<summary><strong>Advanced</strong></summary>

### Config file

Settings are saved to `~/.config/ogma/config`. You can edit this file directly:

```bash
TTS_BACKEND="auto"
TTS_BACKENDS_INSTALLED="both"
VOICE_ID="pFZP5JQG7iQjIQuC4Bku"
MODEL_ID="eleven_flash_v2_5"
STABILITY="0.50"
SIMILARITY_BOOST="0.75"
STYLE="0.00"
USE_SPEAKER_BOOST="true"
SPEED="1.00"
LOCAL_VOICE="bf_lily"
LOCAL_SPEED="1.00"
LOCAL_IDLE_TIMEOUT="120"
STT_IDLE_TIMEOUT="120"
STT_ENGINE="parakeet"
STT_ENGINES_INSTALLED="parakeet"
DICTATION_REVIEW="true"
DICTATION_INSERT_MODE="paste"
DICTATION_TYPING_WPM="120"
INTENT_REWRITE_PROVIDER="off"
INTENT_OPENAI_MODEL="gpt-5.6-luna"
INTENT_ANTHROPIC_MODEL="claude-haiku-4-5-20251001"
INTENT_COMPATIBLE_URL="http://127.0.0.1:11434/v1"
INTENT_COMPATIBLE_MODEL="llama3.2:3b"
INTENT_REWRITE_TIMEOUT="15"
RECORDING_INDICATOR="detailed"
SENTENCE_PAUSE="400"
```

### Environment variables

Environment variables take highest priority and override both the config file and the settings app:

```bash
export ELEVENLABS_API_KEY="your-api-key"       # overrides Keychain
export ELEVENLABS_VOICE_ID="your-voice-id"
export ELEVENLABS_MODEL_ID="eleven_multilingual_v2"
export TTS_BACKEND="local"                     # "auto" (default), "elevenlabs", or "local"
export SPEED="1.10"                            # ElevenLabs speed (0.7 to 1.2)
export STABILITY="0.50"                        # 0.0 (expressive) to 1.0 (steady)
export SIMILARITY_BOOST="0.75"                 # 0.0 to 1.0
export STYLE="0.00"                            # 0.0 to 1.0 (adds latency)
export USE_SPEAKER_BOOST="true"                # "true" or "false"
export LOCAL_VOICE="am_adam"                   # Kokoro voice ID
export LOCAL_SPEED="1.25"                      # 0.5 to 2.0
export SENTENCE_PAUSE="400"                    # inter-sentence pause (ms at 1× speed, default 400)
export OGMA_IDLE_TIMEOUT="600"              # daemon idle shutdown (seconds, default 300)
```

Debug variables (not needed for normal use):

```bash
export OGMA_TRACE=1                         # print timing trace to stderr
export OGMA_NO_QUEUE_PLAYER=1               # fall back to afplay (one process per sentence)
export VENV_PYTHON="/path/to/python3"          # override the default venv Python
```

### Voice IDs

| Name | ID |
|------|----|
| Lily | `pFZP5JQG7iQjIQuC4Bku` |
| Alice | `Xb7hH8MSUJpSbSDYk0k2` |
| Rachel | `21m00Tcm4TlvDq8ikWAM` |
| Adam | `pNInz6obpgDQGcFmaJgB` |
| Domi | `AZnzlk1XvdvUeBnXmlld` |
| Josh | `TxGEqnHWrfWFTfGW9XjX` |
| Sam | `yoZ06aMxZJJ28mfd3POQ` |

### Accessibility permission

The global hotkey requires Accessibility access. The app prompts for this on first launch, but if you need to grant it manually:

**System Settings → Privacy & Security → Accessibility** → enable **Ogma**

The hotkey activates automatically once access is granted.

### Electron apps (Beeper, Slack, VS Code, etc.)

Electron apps intercept keyboard shortcuts before macOS Services sees them. The settings app solves this by registering `⌥⇧/` as a **global hotkey** via CoreGraphics — it works at the system level and cannot be blocked by any app.

The settings app simulates `⌘C` via CGEvent to copy the current selection before calling the TTS script, so the hotkey works everywhere — including apps that don't support macOS Services.

### Optional: Services shortcut

The installer also creates a macOS Services action you can bind to any shortcut. This is optional — `⌥⇧/` already works everywhere — but useful if you prefer a different key combination.

1. System Settings → **Keyboard → Keyboard Shortcuts → Services → Text**
2. Find **Speak Selection** and assign a shortcut — e.g. `⌃⌥S`

> **Speak Selection** not in the list? Log out and back in, or trigger via right-click → **Services**.

### TTS daemon

Local TTS uses a persistent daemon (`tts_server.py`) that keeps the Kokoro model loaded in memory. When the menu bar app is running, it manages the daemon directly -- the daemon stays alive as long as the app is open. If you run `speak.sh` from the terminal without the app, the daemon starts on first request and shuts down after 5 minutes of inactivity.

Logs are written to `~/.local/share/ogma/tts.log`. Installer errors (pip, swiftc) go to `~/.local/share/ogma/install.log`.

### Updating

Download and run the [latest `Ogma.pkg`](../../releases/latest/download/Ogma.pkg) — the app re-syncs its helper scripts automatically on first launch after an update. (Source installs: re-run `install.command`.)

To update your API key, use the menu bar icon → **API Key…** — or update it directly:

```bash
security add-generic-password \
  -a "ogma" \
  -s "ogma-api-key" \
  -w "your-new-key" \
  -U
```

</details>
