# Voice filter: transcribe only the enrolled user

*Design sketch — not yet implemented. Opt-in, local-only, like everything else.*

## Problem

Dictating in public transcribes bystanders. Parakeet is a pure ASR model — it has
no concept of *who* is speaking, so anything audible becomes text.

## Why not pitch?

Tracking the user's pitch (F0) over time is appealing but too weak as the primary
signal: fundamental-frequency ranges overlap heavily between speakers (most
same-sex speakers are nearly indistinguishable by F0 alone), and within-speaker
pitch varies more across moods and volumes than between many speakers. Pitch can
be a cheap *auxiliary* feature, not the discriminator.

## Proposed design: speaker-embedding gate

A small speaker-verification model runs in front of Parakeet inside `stt_server.py`:

1. **Enrollment** — build a voice profile (mean speaker embedding) from dictations
   the user *accepted* on the review card (rolling average, stored locally at
   `~/.local/share/ogma/voice-profile.npy`). Optional explicit path: a 15-second
   read-aloud enrollment from the menu. The profile never leaves the machine.
2. **Runtime gating** — during recording, compute an embedding per ~1 s window
   (hop ~250 ms), cosine-score against the profile, and replace below-threshold
   windows with silence before they reach Parakeet. Hysteresis (require 2
   consecutive windows to flip state) avoids chopping mid-word.
3. **Candidate models** — WeSpeaker ResNet34 (ONNX, ~25 MB, real-time on CPU),
   ECAPA-TDNN (SpeechBrain), or resemblyzer-style d-vectors. onnxruntime on CPU
   is sufficient at these sizes; no MLX port required initially.
4. **Menu** — `Voice Filter (only my voice)` toggle, default **off**, plus
   `Re-enroll Voice…`. Documented limitation: this *gates*, it does not *separate*.

## Known limitation → phase 2

When a bystander talks **over** the user, gating drops the whole window — the
user's words in it are lost too. Recovering those requires target-speaker
extraction (TSE, e.g. SpeakerBeam-family models) as a true front-end filter
rather than a gate. Heavier, harder to run streaming; treat as research after
the gate proves out.

## Phases

- **P0** — enrollment + offline evaluation harness: record multi-speaker samples,
  measure false-accept / false-reject rates across thresholds
- **P1** — streaming gate in `stt_server.py` behind the opt-in toggle
- **P2** — per-user threshold auto-calibration (score distribution of accepted dictations)
- **P3** — TSE front-end for overlapped speech (research)

## Signal we already collect

The v2.2.0 opt-in correction reports quantify this problem: corrections that
*delete entire sentences* from a transcript are a strong indicator of bystander
speech being written down. Worth measuring before tuning.

## Effort estimate

P0+P1 is roughly a focused week: the plumbing (venv dependency, gating in the
audio path — the socket protocol is untouched) is straightforward. The real work
is threshold calibration and boundary quality, which needs real recorded audio.
