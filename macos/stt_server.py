#!/usr/bin/env python3
"""Persistent speech-to-text daemon for Ogma.

Keeps a Parakeet (MLX) model loaded in memory and transcribes audio files sent
over a Unix socket, so dictation is near-instant once the model is warm.  This
is the STT twin of tts_server.py and shares its lifecycle conventions.

Request  (one JSON line):  {"audio_file": "/path/to/recording.wav"}
Response (one JSON line):  {"status": "ok", "text": "...", "words": [...]}
                     or:   {"status": "error", "message": "..."}

"words" is a list of {"text": word, "confidence": 0..1} built from Parakeet's
per-token confidence scores, so clients can flag shaky words. Streaming
partials/finals carry the same key.

Two modes:
  Default:   started on-demand; auto-shuts down after idle timeout.
  --managed: started by the Settings app; auto-shuts down after idle timeout
             AND when the parent process exits (or on SIGTERM).
"""

import fcntl
import json
import os
import signal
import socket
import struct
import sys
import threading
import time
import traceback

# ── Paths ────────────────────────────────────────────────────────────

# OGMA_DATA_DIR lets tests run an isolated daemon (own socket, flock, AND
# config — otherwise the user's real config would override test timeouts).
_data_dir_override = os.environ.get("OGMA_DATA_DIR")
DATA_DIR = _data_dir_override or os.path.expanduser("~/.local/share/ogma")
SOCKET_PATH = os.path.join(DATA_DIR, "stt.sock")
PID_FILE = os.path.join(DATA_DIR, "stt_server.pid")
LOCK_FILE = os.path.join(DATA_DIR, "stt_server.lock")
LOG_FILE = os.path.join(DATA_DIR, "stt.log")
STATE_FILE = os.path.join(DATA_DIR, "stt_state.json")
CONFIG_FILE = (os.path.join(DATA_DIR, "config") if _data_dir_override
               else os.path.expanduser("~/.config/ogma/config"))

# The Parakeet model to load.  Override with the STT_MODEL env var.
MODEL_ID = os.environ.get("STT_MODEL", "mlx-community/parakeet-tdt-0.6b-v2")


def _config_value(key):
    """Read a value from the shell config file, or None.  Matches the key
    exactly (STT_ENGINE must not match STT_ENGINES_INSTALLED)."""
    try:
        with open(CONFIG_FILE) as f:
            for line in f:
                k, eq, v = line.strip().partition("=")
                if eq and k.strip() == key:
                    return v.strip().strip("\"'")
    except OSError:
        pass
    return None


# Dictation engine. "parakeet" is the default; "voxtral" loads Voxtral Realtime
# 4B through mlx-audio and uses its stateful streaming session for both partials
# and finals. Resolved once at startup: the menu app kills the daemon on engine
# change, so a live re-read would only invite a half-switched state. Keep the
# model repo id in sync with install-local.sh.
VOXTRAL_MODEL_ID = os.environ.get("STT_VOXTRAL_MODEL",
                                  "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit")
ENGINE = (os.environ.get("STT_ENGINE") or _config_value("STT_ENGINE")
          or "parakeet").lower()
if ENGINE not in ("parakeet", "voxtral"):
    ENGINE = "parakeet"

# Leading silence (seconds) prepended to a stream before the user's first
# audio.  Streaming ASR decodes the first word much more reliably with a bit
# of leading context than when speech starts at the very edge of the buffer —
# which is exactly what happens on a cold start, where you tend to start
# talking the instant you press the hotkey.  Set STT_LEAD_SILENCE=0 to disable.
try:
    LEAD_SILENCE_SEC = float(os.environ.get("STT_LEAD_SILENCE", "0.3"))
    if not 0 <= LEAD_SILENCE_SEC <= 2:
        LEAD_SILENCE_SEC = 0.3
except ValueError:
    LEAD_SILENCE_SEC = 0.3

MAX_FRAME_BYTES = 1024 * 1024
activity_lock = threading.Lock()
active_requests = 0
last_activity = time.monotonic()
state_write_lock = threading.Lock()


def validate_frame_size(size):
    if size > MAX_FRAME_BYTES or size % 4:
        raise ValueError("Invalid audio frame length")


def stream_sample_rate(request):
    rate = int(request.get("sample_rate", 16000))
    if not 8000 <= rate <= 192000:
        raise ValueError("Unsupported audio sample rate")
    return rate

# Idle timeout: the model is released after this long with no requests.
# Resolved fresh on each check (see effective_timeout) so the menu bar's
# "Auto-unload after" picker applies to a running daemon.  Shares the same
# STT_IDLE_TIMEOUT config key so STT and TTS can be tuned independently.
DEFAULT_IDLE_TIMEOUT = 120
MIN_IDLE_TIMEOUT = 5


def effective_timeout():
    """Idle timeout in seconds.  Priority: STT_IDLE_TIMEOUT in the config file
    (menu-driven, applied live), then the STT_IDLE_TIMEOUT env var, then the
    default."""
    for source in (_config_value("STT_IDLE_TIMEOUT"),
                   os.environ.get("STT_IDLE_TIMEOUT")):
        try:
            v = int(source)
            if MIN_IDLE_TIMEOUT <= v <= 86400:
                return v
        except (TypeError, ValueError):
            continue
    return DEFAULT_IDLE_TIMEOUT


# ── Logging ──────────────────────────────────────────────────────────


def log(msg):
    """Append a timestamped line to the STT log file."""
    try:
        with open(LOG_FILE, "a") as f:
            f.write(
                f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] stt_server: {msg}\n"
            )
    except OSError:
        pass


# ── Globals ──────────────────────────────────────────────────────────

model = None
voxtral = None            # mlx-audio Voxtral model when the engine is up
last_request_time = time.time()
server_socket = None
shutdown_event = threading.Event()
managed_mode = False
transcribe_lock = threading.Lock()


def write_state():
    """Publish daemon state for the menu bar (best-effort, atomic write)."""
    try:
        tmp = STATE_FILE + ".tmp"
        with state_write_lock:
            with open(tmp, "w") as f:
                json.dump({"idle_timeout": effective_timeout(),
                           "last_request": last_request_time,
                           "engine": ENGINE if voxtral is not None else "parakeet"}, f)
            os.replace(tmp, STATE_FILE)
    except OSError:
        pass


# ── Model ────────────────────────────────────────────────────────────


def load_stt_model():
    """Load the selected engine.  Only ONE model is resident: Voxtral serves
    both live partials and finals when selected (Parakeet stays on disk as
    the fallback and loads instead only if Voxtral can't)."""
    global model, voxtral

    if ENGINE == "voxtral":
        try:
            # Only load from the local cache — from_pretrained would otherwise
            # start a 3 GB download inside a GUI-launched daemon.
            from huggingface_hub import try_to_load_from_cache
            if try_to_load_from_cache(VOXTRAL_MODEL_ID, "config.json") is None:
                raise RuntimeError("model not cached; re-run install-local.sh --with-voxtral")
            from mlx_audio.stt.utils import load as load_voxtral
            log(f"loading voxtral {VOXTRAL_MODEL_ID}")
            voxtral = load_voxtral(VOXTRAL_MODEL_ID)
            log("voxtral loaded")
            return
        except Exception as e:
            voxtral = None
            log(f"voxtral unavailable, falling back to parakeet: {e}")

    from parakeet_mlx import from_pretrained

    log(f"loading model {MODEL_ID}")
    model = from_pretrained(MODEL_ID)
    log("model loaded")


def voxtral_transcribe(samples, sample_rate=16000):
    """Batch-decode a full utterance with Voxtral Realtime 4B.

    samples: float32 mono numpy array.  Returns the transcript text —
    punctuated and cased by the LLM decoder, no per-word confidences.
    """
    import numpy as np

    import mlx.core as mx
    # Same onset problem LEAD_SILENCE_SEC solves for Parakeet: with speech
    # starting at the very edge of the buffer, Voxtral drops the opening
    # sentence.  Half a second of leading silence reliably fixes it.
    samples = np.concatenate(
        [np.zeros(int(0.5 * sample_rate), dtype=np.float32), samples])
    # Generous token budget: ~15 tokens/s of audio covers fast speech with
    # punctuation several times over.
    max_new = max(256, min(4096, int(len(samples) / sample_rate * 15)))
    out = voxtral.generate([mx.array(samples)], max_tokens=max_new,
                           temperature=0.0, transcription_delay_ms=480)
    return out.text.strip()


def words_from_text(text):
    """Word list for an engine that gives no per-word confidences.  Same
    "join reproduces text" invariant as words_from_result; confidence 1.0
    means the suggestion machinery leaves these words alone."""
    text = (text or "").strip()
    if not text:
        return []
    return [{"text": w, "confidence": 1.0} for w in text.split(" ")]


def warmup():
    """Transcribe a short silent clip so the first real request is fast."""
    try:
        import numpy as np
        import soundfile as sf
        import tempfile

        log("warming up")
        tmp = os.path.join(tempfile.mkdtemp(prefix="ogma_stt_warm_"), "s.wav")
        sf.write(tmp, np.zeros(16000, dtype="float32"), 16000)
        if voxtral is not None:
            voxtral_transcribe(np.zeros(16000, dtype="float32"))
        else:
            transcribe_file(tmp)
        # Drop the warmup's cached buffers: MLX's allocator fragments badly
        # when the first decode is tiny and the next is 30× larger — measured
        # 47s instead of 2s for the first real Voxtral request without this.
        import mlx.core as mx
        mx.clear_cache()
        try:
            os.unlink(tmp)
            os.rmdir(os.path.dirname(tmp))
        except OSError:
            pass
        log("warm")
    except Exception as e:
        log(f"warmup failed (non-fatal): {e}")


def words_from_result(result, tokens=None):
    """Word list with confidence scores for the transcript in result.text.

    Word texts come from result.text itself (split on spaces) so that
    " ".join(word texts) reproduces the transcript exactly — parakeet's
    token-level sentence splitting can disagree with the text about word
    boundaries (e.g. around "!"/"?").  Confidences come from walking the
    tokens in order and giving each word the minimum confidence of the
    tokens overlapping it, so one shaky token flags the whole word.

    Pass `tokens` explicitly for STREAMING results: result.tokens is
    re-sorted by window-relative start times, which scrambles token order
    once dictation outlasts the streaming context window (~20s); the
    stream's raw finalized+draft token list preserves decode order.
    """
    text = (getattr(result, "text", "") or "").strip()
    if not text:
        return []
    if tokens is None:
        tokens = result.tokens
    words = [[w, 1.0] for w in text.split(" ")]
    idx = 0                          # word being covered by the token walk
    remaining = len(words[0][0])     # its characters not yet covered
    for tok in tokens:
        chars = len(tok.text.replace(" ", ""))
        conf = float(getattr(tok, "confidence", 1.0))
        while chars > 0 and idx < len(words):
            if remaining == 0:       # empty word from a doubled space
                idx += 1
                if idx < len(words):
                    remaining = len(words[idx][0])
                continue
            words[idx][1] = min(words[idx][1], conf)
            take = min(chars, remaining)
            chars -= take
            remaining -= take
            if remaining == 0:
                idx += 1
                if idx < len(words):
                    remaining = len(words[idx][0])
        if idx >= len(words):
            break
    return [{"text": w, "confidence": round(c, 3)} for w, c in words]


# ── Filler-word filtering ────────────────────────────────────────────
#
# Spoken disfluencies the model transcribes faithfully but nobody wants in
# their text. Pure fillers only — never real words. Disable by setting
# FILTER_FILLERS="false" in the config file.

FILLER_WORDS = {"um", "uh", "umm", "uhm", "uhh", "er", "erm",
                "hmm", "mhm", "mm", "mmm"}
_PUNCT = ".,!?;:'\""


def filter_fillers_enabled():
    v = _config_value("FILTER_FILLERS")
    if v is not None:
        return v.lower() not in ("false", "0", "no", "off")
    return True


def strip_fillers(words):
    """Drop disfluencies from a word list, preserving sentence shape: a
    dropped sentence-initial filler passes its capitalization to the next
    word; a dropped sentence-final filler passes its terminal punctuation
    back to the previous word."""
    out = []
    capitalize_next = False
    for w in words:
        text = w["text"]
        if text.strip(_PUNCT).lower() in FILLER_WORDS:
            if text[:1].isupper():
                capitalize_next = True
            punct = text[len(text.rstrip(_PUNCT)):]
            if any(p in punct for p in ".!?") and out and \
               not out[-1]["text"].endswith((".", "!", "?", ",", ";", ":")):
                out[-1] = dict(out[-1], text=out[-1]["text"] + punct)
            continue
        if capitalize_next and text[:1].islower():
            w = dict(w, text=text[0].upper() + text[1:])
        capitalize_next = False
        out.append(w)
    return out


# ── Context autocorrect (old-school n-grams + phonetics) ────────────
#
# For words the model was unsure about, look for a phonetically similar
# lexicon word that fits the surrounding context much better, and attach it
# as {"suggestion": ...} so the app can offer a one-click replacement.
# Data: Norvig's count_1w.txt / count_2w.txt (Google Web Trillion Word
# Corpus counts, fetched by install-local.sh) + jellyfish for metaphone and
# edit distance. Entirely optional — missing data or package disables it.

NGRAM_DIR = os.path.join(DATA_DIR, "ngrams")
SUGGEST_BELOW = 0.88      # mirror the app's low-confidence (yellow) tier
LEXICON_SIZE = 100_000    # top unigrams kept for candidates
SCAN_SIZE = 30_000        # top words scanned for near-typo candidates

# Personal dictionary: names and jargon the user wants recognized. Matches
# are high-precision (the user's own vocabulary), so they're checked against
# a looser confidence bar — and a hit caps the word's confidence below the
# yellow tier so the app surfaces the chip with the suggestion.
DICT_FILE = os.path.join(os.path.dirname(CONFIG_FILE), "dictionary.txt")
DICT_SUGGEST_BELOW = 0.97
DICT_FLAG_CONFIDENCE = 0.87

_autocorrect = None       # None = not loaded yet; False = unavailable
_autocorrect_lock = threading.Lock()
_user_dict = None


def _word_core(word):
    return word.strip(".,!?;:'\"()").lower()


class UserDictionary:
    """~/.config/ogma/dictionary.txt — one word per line, # for comments.
    Reloaded whenever the file's mtime changes."""

    def __init__(self, path, jf):
        self.path = path
        self.jf = jf
        self.mtime = -1
        self.words = []       # original casing, file order
        self.by_lower = {}
        self.entries = []     # (word, lowercase, metaphone key)

    def refresh(self):
        try:
            mtime = os.path.getmtime(self.path)
        except OSError:
            mtime = None
        if mtime == self.mtime:
            return
        self.mtime = mtime
        self.words, self.by_lower, self.entries = [], {}, []
        if mtime is None:
            return
        try:
            with open(self.path) as f:
                for line in f:
                    w = line.strip()
                    if not w or w.startswith("#") or " " in w:
                        continue
                    self.words.append(w)
                    self.by_lower.setdefault(w.lower(), w)
                    self.entries.append((w, w.lower(), self.jf.metaphone(w.lower())))
            log(f"dictionary loaded: {len(self.words)} words")
        except OSError:
            pass

    def suggest(self, word):
        """The phonetically closest dictionary word, or None.

        Ranked primarily by metaphone-key distance (names mangle letters far
        more than sounds — 'Zantipi'/'Xanthippe' is 4 letter edits but 1 key
        edit), with a length-scaled letter-distance sanity cap.
        """
        core = _word_core(word)
        if len(core) < 3 or not self.words:
            return None
        key = self.jf.metaphone(core)
        best, best_rank = None, (2, 99)      # key distance must be <= 1
        for c, cl, ckey in self.entries:
            key_lev = self.jf.levenshtein_distance(key, ckey)
            if key_lev > 1:
                continue
            letter_lev = self.jf.levenshtein_distance(cl, core)
            if letter_lev > max(3, len(core) // 2 + 1):
                continue
            if (key_lev, letter_lev) < best_rank:
                best, best_rank = c, (key_lev, letter_lev)
        if best is None:
            return None
        stripped = word.rstrip(".,!?;:'\"")
        return best + word[len(stripped):]   # keep trailing punctuation


def get_user_dictionary():
    global _user_dict
    if _user_dict is None:
        try:
            import jellyfish
            _user_dict = UserDictionary(DICT_FILE, jellyfish)
        except Exception as e:
            _user_dict = False
            log(f"user dictionary unavailable: {e}")
    d = _user_dict or None
    if d is not None:
        d.refresh()
    return d


class Autocorrect:
    def __init__(self, uni_path, bi_path):
        import jellyfish

        self.jf = jellyfish
        self.uni = {}
        self.rank = []
        total = 0
        with open(uni_path) as f:
            for line in f:
                try:
                    w, c = line.split("\t")
                    c = int(c)
                except ValueError:
                    continue
                total += c
                if len(self.uni) < LEXICON_SIZE:
                    self.uni[w] = c
                    self.rank.append(w)
        self.total = float(total)
        self.bi = {}
        with open(bi_path) as f:
            for line in f:
                try:
                    pair, c = line.rstrip("\n").split("\t")
                    self.bi[pair] = int(c)
                except ValueError:
                    continue
        self.index = {}
        for w in self.uni:
            self.index.setdefault(self.jf.metaphone(w), []).append(w)

    def _logp(self, w):
        import math
        return math.log10((self.uni.get(w, 0) + 0.5) / self.total)

    def _logp2(self, w1, w2):
        c = self.bi.get(w1 + " " + w2, 0)
        if c:
            import math
            return math.log10(c / self.total)
        return self._logp(w2) - 2.0        # unigram backoff, penalized

    def _context_score(self, prev, w, nxt):
        s = self._logp(w)
        if prev:
            s += self._logp2(prev, w)
        if nxt:
            s += self._logp2(w, nxt)
        return s

    @staticmethod
    def _core(word):
        return word.strip(".,!?;:'\"()").lower()

    def suggest(self, prev, word, nxt):
        """A context-fitting, phonetically similar alternative, or None."""
        core = self._core(word)
        if len(core) < 3 or not core.isalpha():
            return None
        # Candidates: same metaphone key (homophones) plus frequent words a
        # small edit away (near-misses the phonetic key doesn't catch).
        cands = set(self.index.get(self.jf.metaphone(core), ()))
        for w in self.rank[:SCAN_SIZE]:
            if abs(len(w) - len(core)) <= 2 and \
               self.jf.levenshtein_distance(w, core) <= 2:
                cands.add(w)
        cands.discard(core)
        if not cands:
            return None
        p, n = self._core(prev), self._core(nxt)
        best, best_score = None, self._context_score(p, core, n) + 1.0
        for c in cands:                     # must fit ~10x better to win
            if self.jf.levenshtein_distance(c, core) > 3:
                continue
            s = self._context_score(p, c, n)
            if s > best_score:
                best, best_score = c, s
        if best is None:
            return None
        out = best.capitalize() if word[:1].isupper() else best
        stripped = word.rstrip(".,!?;:'\"")
        return out + word[len(stripped):]   # keep trailing punctuation


def get_autocorrect():
    """Lazy singleton; warmed in the background at startup."""
    global _autocorrect
    with _autocorrect_lock:
        if _autocorrect is None:
            uni = os.path.join(NGRAM_DIR, "count_1w.txt")
            bi = os.path.join(NGRAM_DIR, "count_2w.txt")
            try:
                if os.path.isfile(uni) and os.path.isfile(bi):
                    t0 = time.time()
                    _autocorrect = Autocorrect(uni, bi)
                    log(f"autocorrect loaded in {time.time() - t0:.1f}s")
                else:
                    _autocorrect = False
                    log("autocorrect data missing; suggestions disabled")
            except Exception as e:
                _autocorrect = False
                log(f"autocorrect unavailable: {e}")
        return _autocorrect or None


def add_suggestions(words):
    """Attach dictionary/context suggestions to shaky words (in place)."""
    ac = get_autocorrect()
    dic = get_user_dictionary()
    have_dict = dic is not None and dic.words
    if ac is None and not have_dict:
        return words
    for i, w in enumerate(words):
        conf = w["confidence"]
        if conf >= DICT_SUGGEST_BELOW:
            continue
        core = _word_core(w["text"])
        # The user's own words are never "corrected" — at most their casing
        # is aligned with the dictionary entry.
        if have_dict and core in dic.by_lower:
            proper = dic.by_lower[core]
            cased = w["text"].strip(".,!?;:'\"()")
            if cased != proper:
                w["suggestion"] = proper + w["text"][len(w["text"].rstrip(".,!?;:'\"")):]
                w["confidence"] = min(conf, DICT_FLAG_CONFIDENCE)
            continue
        s = None
        if have_dict:
            try:
                s = dic.suggest(w["text"])
            except Exception:
                s = None
            if s and _word_core(s) != core:
                # A dictionary hit is strong evidence of a mishearing: flag
                # the word so the app surfaces the chip.
                w["suggestion"] = s
                w["confidence"] = min(conf, DICT_FLAG_CONFIDENCE)
                continue
            s = None
        if ac is None or conf >= SUGGEST_BELOW:
            continue
        prev = words[i - 1]["text"] if i else ""
        nxt = words[i + 1]["text"] if i + 1 < len(words) else ""
        try:
            s = ac.suggest(prev, w["text"], nxt)
        except Exception:
            continue
        if s and s != w["text"]:
            w["suggestion"] = s
    return words


def read_audio(audio_file):
    """Decode an audio file to float32 mono samples at the model's rate.

    We decode with soundfile instead of shelling out to ffmpeg — ffmpeg is
    not on the restricted PATH of a GUI-launched daemon, and avoiding it
    removes a dependency.  Ogma records 16 kHz mono WAV (the model's native
    rate), so normally there is no resampling.
    """
    import numpy as np
    import soundfile as sf

    samples, sr = sf.read(audio_file, dtype="float32", always_2d=False)
    if getattr(samples, "ndim", 1) > 1:      # stereo → mono
        samples = samples.mean(axis=1)
    target_sr = (model.preprocessor_config.sample_rate
                 if model is not None else 16000)
    if sr != target_sr:
        import librosa
        samples = librosa.resample(samples, orig_sr=sr, target_sr=target_sr)
    return samples.astype(np.float32), target_sr


def transcribe_file(audio_file):
    """Transcribe an audio file with Parakeet and return the AlignedResult."""
    import mlx.core as mx
    from parakeet_mlx.audio import get_logmel

    samples, _ = read_audio(audio_file)
    mel = get_logmel(mx.array(samples), model.preprocessor_config)
    return model.generate(mel)[0]


# ── Client handler ───────────────────────────────────────────────────


def handle_stream(conn, request, initial=b""):
    """Real-time streaming transcription.

    After the {"mode":"stream"} header line, the client sends length-prefixed
    audio frames: a 4-byte big-endian length N, then N bytes of little-endian
    float32 mono samples at `sample_rate` (0 length = end of stream).  After
    each frame we push it through transcribe_stream() and send back a
    {"partial": text} line; at the end we send {"status":"ok","final": text}.
    """
    global last_request_time
    import numpy as np
    import mlx.core as mx

    sr = stream_sample_rate(request)
    target_sr = model.preprocessor_config.sample_rate
    log(f"stream start (sr={sr})")

    buf = bytearray(initial)

    def read_exact(n):
        while len(buf) < n:
            try:
                conn.settimeout(60)
                chunk = conn.recv(65536)
            except socket.timeout:
                return None
            if not chunk:
                return None
            buf.extend(chunk)
        out = bytes(buf[:n])
        del buf[:n]
        return out

    # Parakeet's streaming API returns empty output when fed very small
    # chunks (< ~200 ms), and the app streams tiny audio-tap buffers (~85 ms).
    # So we accumulate here and only push ~0.5 s at a time to the model,
    # regardless of the client's frame size.
    chunk_samples = int(0.5 * target_sr)
    # Prime the buffer with a short lead-in of silence so the model has left
    # context for the very first word instead of decoding its onset at the
    # buffer edge (see LEAD_SILENCE_SEC).  The first real chunk is then decoded
    # as [silence + speech onset] in one pass.
    lead = int(LEAD_SILENCE_SEC * target_sr)
    pending = np.zeros(lead, dtype=np.float32) if lead > 0 else np.zeros(0, dtype=np.float32)

    final = ""
    final_words = []
    with transcribe_lock:
        with model.transcribe_stream(context_size=(256, 256)) as stream:
            # Prefix-agreement stabilization (LocalAgreement-2): a word is
            # committed once two consecutive decodes agree on it, and
            # committed words are never rewritten in later partials — the
            # model re-decodes its whole context window every chunk, so
            # without this the first words keep flapping on screen. Committed
            # text keeps its wording; confidences still refresh while the
            # model agrees.
            committed = []
            prev_words = []

            def stabilized():
                nonlocal committed, prev_words
                res = stream.result
                cur = words_from_result(
                    res, stream.finalized_tokens + stream.draft_tokens)
                agree = 0
                while (agree < len(prev_words) and agree < len(cur)
                       and prev_words[agree]["text"] == cur[agree]["text"]):
                    agree += 1
                if agree > len(committed):
                    committed = cur[:agree]
                prev_words = cur
                words = []
                for i, w in enumerate(committed):
                    if i < len(cur) and cur[i]["text"] == w["text"]:
                        words.append(cur[i])   # fresher confidence, same text
                    else:
                        words.append(w)
                words += cur[len(committed):]
                # Fillers are filtered on the OUTPUT view only — agreement
                # and commitment always track the raw decode.
                if filter_fillers_enabled():
                    words = strip_fillers(words)
                return " ".join(w["text"] for w in words), words

            while not shutdown_event.is_set():
                header = read_exact(4)
                if header is None:
                    return   # disconnected/cancelled: do not finalize
                (n,) = struct.unpack(">I", header)
                validate_frame_size(n)
                if n == 0:
                    break
                payload = read_exact(n)
                if payload is None:
                    return
                samples = np.frombuffer(payload, dtype="<f4")
                if not np.isfinite(samples).all():
                    raise ValueError("Non-finite audio samples")
                if sr != target_sr:
                    import librosa
                    samples = librosa.resample(
                        samples.astype(np.float32), orig_sr=sr, target_sr=target_sr)
                pending = np.concatenate([pending, samples.astype(np.float32)])
                if len(pending) >= chunk_samples:
                    stream.add_audio(mx.array(pending))
                    pending = np.zeros(0, dtype=np.float32)
                    last_request_time = time.time()
                    text, words = stabilized()
                    conn.sendall((json.dumps(
                        {"partial": text, "words": words}) + "\n").encode())
            # Flush any remaining tail audio before finalizing. The final is
            # committed words + the last decode's tail, so it never contradicts
            # text the user already watched stabilize.
            if len(pending) > 0:
                stream.add_audio(mx.array(pending))
            final, final_words = stabilized()
            add_suggestions(final_words)

    conn.sendall((json.dumps({"status": "ok", "final": final,
                              "words": final_words,
                              "model": MODEL_ID.rsplit("/", 1)[-1]}) + "\n").encode())
    last_request_time = time.time()
    write_state()
    log(f"stream final: {len(final)} chars")


def handle_stream_voxtral(conn, request, initial=b""):
    """Stateful, linear-time streaming transcription with Voxtral.

    mlx-audio incrementally caches mel features, audio-encoder state, and the
    decoder KV state. Detailed mode receives full partial transcripts. None and
    Simple still advance the same final transcription while recording, but do
    so silently with the high-quality 2400 ms delay preset. Closing the stream
    only drains the remaining cached tail; it never re-decodes the utterance.
    """
    global last_request_time
    import numpy as np

    sr = stream_sample_rate(request)
    target_sr = 16000
    want_partials = request.get("want_partials", True) is not False
    delay_ms = 480 if want_partials else 2400
    log(f"stream start (voxtral, sr={sr}, partials={want_partials}, "
        f"delay={delay_ms}ms)")

    buf = bytearray(initial)
    session = voxtral.create_streaming_session(
        max_tokens=4096, temperature=0.0, transcription_delay_ms=delay_ms)
    transcript_parts = []
    total_samples = 0
    ended = False

    def recv_into_buf(timeout):
        """One recv into buf.  True = got data, None = nothing yet, False = EOF."""
        conn.settimeout(timeout)
        try:
            chunk = conn.recv(65536)
        except socket.timeout:
            return None
        if not chunk:
            return False
        buf.extend(chunk)
        return True

    def pop_frames():
        """Feed all complete wire frames into the stateful session."""
        nonlocal total_samples, ended
        while True:
            if len(buf) < 4:
                return
            (n,) = struct.unpack(">I", bytes(buf[:4]))
            validate_frame_size(n)
            if n == 0:
                del buf[:4]
                ended = True
                return
            if len(buf) < 4 + n:
                return
            payload = bytes(buf[4:4 + n])
            del buf[:4 + n]
            samples = np.frombuffer(payload, dtype="<f4")
            if not np.isfinite(samples).all():
                raise ValueError("Non-finite audio samples")
            if sr != target_sr:
                import librosa
                samples = librosa.resample(
                    samples.astype(np.float32), orig_sr=sr, target_sr=target_sr)
            samples = samples.astype(np.float32)
            session.feed(samples)
            total_samples += len(samples)

    def output_view(raw_text):
        """Apply output-only cleanup without changing the session's token state."""
        text = raw_text.strip()
        words = words_from_text(text)
        if filter_fillers_enabled():
            words = strip_fillers(words)
            text = " ".join(w["text"] for w in words)
        return text, words

    def advance(max_decode_tokens, emit_partial):
        """Run one bounded unit of cached MLX work and optionally publish it."""
        deltas = session.step(max_decode_tokens=max_decode_tokens)
        if not deltas:
            return
        transcript_parts.extend(deltas)
        if emit_partial:
            text, words = output_view("".join(transcript_parts))
            conn.settimeout(30)
            conn.sendall((json.dumps(
                {"partial": text, "words": words}) + "\n").encode())

    pop_frames()                 # complete frames may already be in `initial`
    last_audio_at = time.monotonic()

    with transcribe_lock:
        while not shutdown_event.is_set() and not ended:
            got = recv_into_buf(0.1)
            if got is False:
                log("voxtral stream: client disconnected")
                return
            if got is not None:
                pop_frames()
                last_audio_at = time.monotonic()
                last_request_time = time.time()
            elif time.monotonic() - last_audio_at > 60:
                log("voxtral stream: 60s idle, finalizing")
                break
            advance(max_decode_tokens=16, emit_partial=want_partials)

        session.close()
        drain_started = time.monotonic()
        while not session.done:
            if time.monotonic() - drain_started > 60:
                raise TimeoutError("Voxtral streaming finalization timed out")
            advance(max_decode_tokens=64, emit_partial=False)

    final, final_words = output_view("".join(transcript_parts))

    conn.settimeout(30)
    conn.sendall((json.dumps(
        {"status": "ok", "final": final, "words": final_words,
         "model": VOXTRAL_MODEL_ID.rsplit("/", 1)[-1]}) + "\n").encode())
    last_request_time = time.time()
    write_state()
    log(f"stream final (voxtral): {len(final)} chars, "
        f"{total_samples/target_sr:.1f}s audio, "
        f"{time.monotonic()-drain_started:.2f}s tail")


def handle_client(conn):
    """Handle one connection: streaming (mode:stream) or one-shot transcription."""
    global last_request_time, last_activity, active_requests
    with activity_lock:
        if shutdown_event.is_set():
            conn.close()
            return
        active_requests += 1
        last_request_time = time.time()

    try:
        data = b""
        conn.settimeout(30)
        while b"\n" not in data:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
            if len(data.partition(b"\n")[0]) > 65536:
                raise ValueError("STT request header exceeds 64 KiB")

        if not data.strip():
            return

        line, _, rest = data.partition(b"\n")
        request = json.loads(line.decode("utf-8").strip())

        if request.get("mode") == "stream":
            if voxtral is not None:
                handle_stream_voxtral(conn, request, rest)
            else:
                handle_stream(conn, request, rest)
            return

        audio_file = request.get("audio_file", "")
        if not audio_file or not os.path.isfile(audio_file):
            raise FileNotFoundError(f"audio file not found: {audio_file!r}")

        log(f"request: {audio_file}")
        response_model = MODEL_ID.rsplit("/", 1)[-1]
        with transcribe_lock:
            words = None
            if voxtral is not None:
                try:
                    samples, target_sr = read_audio(audio_file)
                    words = words_from_text(voxtral_transcribe(samples, target_sr))
                    response_model = VOXTRAL_MODEL_ID.rsplit("/", 1)[-1]
                except Exception as e:
                    log(f"voxtral one-shot failed: {e}")
                    words = None
            if words is None:
                if model is None:
                    raise RuntimeError("voxtral transcription failed")
                words = words_from_result(transcribe_file(audio_file))

        if filter_fillers_enabled():
            words = strip_fillers(words)
        text = " ".join(w["text"] for w in words)
        response = json.dumps({"status": "ok",
                               "text": text,
                               "words": add_suggestions(words),
                               "model": response_model})
        conn.sendall((response + "\n").encode("utf-8"))
        log(f"response: {len(text)} chars")

        # Reset the idle clock to the end of transcription and republish state.
        last_request_time = time.time()
        write_state()

    except Exception as e:
        log(f"error: {e}\n{traceback.format_exc()}")
        try:
            response = json.dumps({"status": "error", "message": str(e)})
            conn.sendall((response + "\n").encode("utf-8"))
        except OSError:
            pass
    finally:
        try:
            conn.close()
        except OSError:
            pass
        import gc

        import mlx.core as mx

        gc.collect()
        mx.metal.clear_cache()
        with activity_lock:
            active_requests -= 1
            last_activity = time.monotonic()
            last_request_time = time.time()
        write_state()


# ── Idle watchdog ────────────────────────────────────────────────────


def idle_watchdog():
    """Shuts down after the idle timeout of inactivity.  Timeout is re-read
    each iteration so menu changes apply live; state is republished so the
    menu countdown stays accurate."""
    while not shutdown_event.is_set():
        timeout = effective_timeout()
        with activity_lock:
            remaining = timeout - (time.monotonic() - last_activity)
            should_stop = active_requests == 0 and remaining <= 0
            if should_stop:
                shutdown_event.set()
            elif active_requests:
                remaining = timeout
        if should_stop:
            log(f"idle for {timeout}s, shutting down")
            do_shutdown()
            return
        write_state()
        shutdown_event.wait(min(remaining + 0.5, 5))


# ── Parent watchdog (managed mode) ───────────────────────────────────


def parent_watchdog():
    """Shuts down if the parent (Settings app) dies, so an app crash doesn't
    orphan the daemon."""
    parent_pid = os.getppid()
    if parent_pid <= 1:
        log("already orphaned at startup, shutting down")
        do_shutdown()
        return
    log(f"parent watchdog started (parent pid={parent_pid})")
    while not shutdown_event.is_set():
        if os.getppid() != parent_pid:
            log(f"parent died (was {parent_pid}, now {os.getppid()}), shutting down")
            do_shutdown()
            return
        shutdown_event.wait(2)


# ── Shutdown ─────────────────────────────────────────────────────────


def do_shutdown():
    """Clean shutdown: close socket, remove files, exit."""
    shutdown_event.set()
    if server_socket is not None:
        try:
            server_socket.close()
        except OSError:
            pass
    for path in (SOCKET_PATH, PID_FILE, STATE_FILE):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    log("shutdown complete")
    os._exit(0)


def handle_signal(signum, _frame):
    log(f"received signal {signum}")
    do_shutdown()


# ── Main ─────────────────────────────────────────────────────────────


def main():
    global server_socket, managed_mode, last_request_time, last_activity

    managed_mode = "--managed" in sys.argv[1:]

    os.umask(0o077)
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    os.chmod(DATA_DIR, 0o700)

    # Acquire exclusive lock — guarantees at most one daemon runs.
    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)

    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    # Signal handlers for clean shutdown
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Load model (slow — clients wait for the socket to appear)
    load_stt_model()
    warmup()

    # Warm the autocorrect tables off the critical path so the first final
    # doesn't pay the load cost.
    threading.Thread(target=get_autocorrect, daemon=True).start()

    # Model load can take seconds — reset the idle clock and publish state.
    last_request_time = time.time()
    last_activity = time.monotonic()
    write_state()

    # Idle watchdog runs in every mode; managed mode also runs the parent
    # watchdog so the daemon dies if the app crashes/exits.
    threading.Thread(target=idle_watchdog, daemon=True).start()
    if managed_mode:
        threading.Thread(target=parent_watchdog, daemon=True).start()

    # Create socket — this signals readiness (clients poll for the socket).
    server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server_socket.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o600)
    server_socket.listen(2)
    server_socket.settimeout(5)

    mode_str = ("managed, " if managed_mode else "") + f"idle timeout {effective_timeout()}s"
    log(f"listening on {SOCKET_PATH} ({mode_str})")

    # Handle requests inline on the main thread.  Parakeet/MLX streams are
    # thread-local and bound to the thread that loaded the model, so
    # transcription must run here, not on per-client worker threads.
    # Transcription is fast and single-flight, so this is sufficient.
    while not shutdown_event.is_set():
        try:
            conn, _ = server_socket.accept()
            handle_client(conn)
        except socket.timeout:
            continue
        except OSError:
            if not shutdown_event.is_set():
                log("socket error in accept loop")
            break

    do_shutdown()


if __name__ == "__main__":
    main()
