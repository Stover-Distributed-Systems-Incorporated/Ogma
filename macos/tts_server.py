#!/usr/bin/env python3
"""Persistent TTS daemon for Ogma.

Keeps the Kokoro model loaded in memory and serves TTS requests over a Unix
socket.

Two modes:
  Default:   started on-demand by speak.sh; auto-shuts down after idle timeout.
  --managed: started by the Settings app; auto-shuts down after idle timeout
             AND when the parent process exits (or on SIGTERM).
"""

import fcntl
import json
import os
import signal
import socket
import sys
import tempfile
import threading
import time
import traceback

# ── Paths ────────────────────────────────────────────────────────────

DATA_DIR = os.environ.get("OGMA_DATA_DIR") or os.path.expanduser("~/.local/share/ogma")
SOCKET_PATH = os.path.join(DATA_DIR, "tts.sock")
PID_FILE = os.path.join(DATA_DIR, "tts_server.pid")
LOCK_FILE = os.path.join(DATA_DIR, "tts_server.lock")
LOG_FILE = os.path.join(DATA_DIR, "tts.log")
STATE_FILE = os.path.join(DATA_DIR, "tts_state.json")
CONFIG_FILE = (os.path.join(DATA_DIR, "config") if os.environ.get("OGMA_DATA_DIR")
               else os.path.expanduser("~/.config/ogma/config"))

# Idle timeout: the model is released after this long with no requests,
# freeing ~350 MB.  Resolved fresh on each check (see effective_timeout) so
# the menu bar's "Auto-unload after" picker applies to a running daemon.
DEFAULT_IDLE_TIMEOUT = 120
MIN_IDLE_TIMEOUT = 5


def _config_idle_timeout():
    """Read LOCAL_IDLE_TIMEOUT from the shell config file, or None."""
    try:
        with open(CONFIG_FILE) as f:
            for line in f:
                key, separator, value = line.strip().partition("=")
                if separator and key.strip() == "LOCAL_IDLE_TIMEOUT":
                    return value.strip().strip("\"'")
    except OSError:
        pass
    return None


def effective_timeout():
    """Idle timeout in seconds.  Priority: LOCAL_IDLE_TIMEOUT in the config
    file (menu-driven, applied live), then the OGMA_IDLE_TIMEOUT env var,
    then DEFAULT_IDLE_TIMEOUT."""
    for source in (_config_idle_timeout(), os.environ.get("OGMA_IDLE_TIMEOUT")):
        try:
            v = int(source)
            if MIN_IDLE_TIMEOUT <= v <= 86400:
                return v
        except (TypeError, ValueError):
            continue
    return DEFAULT_IDLE_TIMEOUT

# ── Logging ──────────────────────────────────────────────────────────


def log(msg):
    """Append a timestamped line to the shared log file."""
    try:
        with open(LOG_FILE, "a") as f:
            f.write(
                f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] tts_server: {msg}\n"
            )
    except OSError:
        pass


# ── Globals ──────────────────────────────────────────────────────────

model = None
last_request_time = time.time()
server_socket = None
shutdown_event = threading.Event()
managed_mode = False
activity_lock = threading.Lock()
active_requests = 0
last_activity = time.monotonic()
state_write_lock = threading.Lock()


def write_state():
    """Publish daemon state for the menu bar (best-effort, atomic write).

    The app reads this to show the "Model loaded" toggle and the live
    "Unloading in" countdown: remaining = idle_timeout - (now - last_request).
    """
    try:
        tmp = STATE_FILE + ".tmp"
        with state_write_lock:
            with open(tmp, "w") as f:
                json.dump({"idle_timeout": effective_timeout(),
                           "last_request": last_request_time}, f)
            os.replace(tmp, STATE_FILE)
    except OSError:
        pass
generation_lock = threading.Lock()

# ── Model ────────────────────────────────────────────────────────────


def patch_kokoro_speed_bug():
    """Work around an mlx-audio iSTFTNet bug that breaks non-default speeds.

    At many speed/length combinations the harmonic source SineGen._f02sine
    runs an interpolate down-then-up round-trip whose rounding returns a few
    hundred more samples than the input f0.  The next line, `sine_waves * uv`,
    then fails:

        ValueError: [broadcast_shapes] Shapes (1,N,1) and (1,N+300,9)
                    cannot be broadcast.

    It is deterministic per (text, speed) — a fresh process fails too — so the
    real trigger is changing speed, not stale daemon state.  Align _f02sine's
    output length to its input so sine_waves and uv always match (cropping the
    ~300-sample tail of the harmonic source is inaudible).
    """
    try:
        import mlx.core as mx
        from mlx_audio.tts.models.kokoro import istftnet

        sine_gen = istftnet.SineGen
        if getattr(sine_gen._f02sine, "_ogma_patched", False):
            return
        _orig_f02sine = sine_gen._f02sine

        def _f02sine_aligned(self, f0_values):
            out = _orig_f02sine(self, f0_values)
            length = f0_values.shape[1]
            if out.shape[1] > length:
                out = out[:, :length, :]
            elif out.shape[1] < length:
                pad = mx.repeat(out[:, -1:, :], length - out.shape[1], axis=1)
                out = mx.concatenate([out, pad], axis=1)
            return out

        _f02sine_aligned._ogma_patched = True
        sine_gen._f02sine = _f02sine_aligned
        log("applied Kokoro _f02sine length-alignment patch")
    except Exception as e:
        log(f"could not apply Kokoro speed patch (non-fatal): {e}")


def load_tts_model():
    """Load Kokoro model into memory."""
    global model
    from mlx_audio.tts.utils import load_model

    log("loading model mlx-community/Kokoro-82M-bf16")
    model = load_model("mlx-community/Kokoro-82M-bf16")
    patch_kokoro_speed_bug()
    log("model loaded")


def warmup_pipeline():
    """Run a short generation to pre-cache the language pipeline.

    The first generation for each language initializes a KokoroPipeline
    (phonemizer, espeak-ng).  This adds ~400ms overhead.  Running a short
    warmup after model load eliminates that penalty for real requests.
    """
    try:
        log("warming up pipeline")
        for _ in model.generate(text=".", voice="bf_lily", speed=1.0, lang_code="b"):
            pass
        log("pipeline warm")
    except Exception as e:
        log(f"warmup failed (non-fatal): {e}")


class CancelledError(Exception):
    """Raised when a generation is cancelled (client disconnected)."""
    pass


def generate_audio(text, voice, speed, lang_code, cancel_check=None):
    """Generate a WAV file from text.  Returns the file path.

    cancel_check: optional callable that returns True if the client has
    disconnected and generation should be aborted early.
    """
    import gc

    import mlx.core as mx
    import numpy as np
    from mlx_audio.audio_io import write as audio_write

    tmp_dir = tempfile.mkdtemp(prefix="ogma_tts_")
    out_path = os.path.join(tmp_dir, "ogma.wav")

    try:
        results = model.generate(
            text=text,
            voice=voice,
            speed=float(speed),
            lang_code=lang_code,
        )

        segments = []
        sample_rate = None
        for result in results:
            if cancel_check and cancel_check():
                raise CancelledError("client disconnected")
            segments.append(np.array(result.audio))
            sample_rate = result.sample_rate

        if not segments or sample_rate is None:
            raise RuntimeError("model produced no audio")

        audio = np.concatenate(segments) if len(segments) > 1 else segments[0]
        audio_write(out_path, audio, sample_rate, format="wav")

        if not os.path.isfile(out_path) or os.path.getsize(out_path) == 0:
            raise RuntimeError("audio file empty after write")

        del segments, audio
        return out_path

    except Exception:
        # Clean up temp dir on failure
        import shutil

        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise


# ── Client handler ───────────────────────────────────────────────────


def _client_gone(conn):
    """Non-blocking check: has the client closed the connection?"""
    import select
    try:
        readable, _, _ = select.select([conn], [], [], 0)
        if readable:
            # If the socket is readable, either data arrived (unexpected)
            # or the client closed the connection (recv returns b"").
            data = conn.recv(1, socket.MSG_PEEK)
            return len(data) == 0
        return False
    except OSError:
        return True


def handle_client(conn):
    """Read one JSON request, generate audio, send JSON response."""
    global last_request_time, last_activity, active_requests
    with activity_lock:
        if shutdown_event.is_set():
            conn.close()
            return
        active_requests += 1
        last_request_time = time.time()

    try:
        data = b""
        conn.settimeout(10)
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
            if len(data) > 1024 * 1024:
                raise ValueError("TTS request exceeds 1 MiB")
            if b"\n" in data:
                break

        if not data.strip():
            return

        request = json.loads(data.decode("utf-8").strip())
        text = request.get("text", "")
        voice = request.get("voice", "bf_lily")
        speed = request.get("speed", "1.00")
        lang_code = request.get("lang_code", "b")

        log(f"request: text_len={len(text)} voice={voice} speed={speed} lang={lang_code}")

        with generation_lock:
            audio_file = generate_audio(
                text, voice, speed, lang_code,
                cancel_check=lambda: _client_gone(conn),
            )

        response = json.dumps({"status": "ok", "audio_file": audio_file})
        conn.sendall((response + "\n").encode("utf-8"))
        log(f"response: {audio_file}")

        # Reset the idle clock to the end of generation and republish state so
        # the menu countdown restarts from the full timeout after each use.
        last_request_time = time.time()
        write_state()

    except CancelledError:
        log("generation cancelled (client disconnected)")
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
        # Release MLX metal buffers after response is sent (not between
        # sentences) so back-to-back requests don't pay gc overhead.
        import gc

        import mlx.core as mx

        with generation_lock:
            gc.collect()
            mx.metal.clear_cache()
        with activity_lock:
            active_requests -= 1
            last_activity = time.monotonic()
            last_request_time = time.time()
        write_state()


# ── Idle watchdog ────────────────────────────────────────────────────


def idle_watchdog():
    """Background thread: shuts down after the idle timeout of inactivity.

    The timeout is re-read each iteration so changing it from the menu bar
    applies to the running daemon, and state is republished so the menu's
    countdown stays accurate."""
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
    """Background thread: shuts down if the parent process dies.

    In managed mode the daemon is a child of the Settings app.  Normal quit
    sends SIGTERM, but if the app crashes the daemon becomes an orphan
    (reparented to PID 1 / launchd).  This watchdog detects that.
    """
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
    # The lock is held for the lifetime of the process and released
    # automatically on exit (even on crash or SIGKILL).
    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        # Another daemon already holds the lock — exit cleanly.
        sys.exit(0)

    # Write PID file (safe — we hold the lock)
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    # Remove stale socket
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    # Clean up orphaned temp dirs from previous interrupted generations
    import glob
    import shutil

    for d in glob.glob(os.path.join(tempfile.gettempdir(), "ogma_tts_*")):
        try:
            # A previous request's clips may still be playing or cached by
            # the speed reader when the daemon reloads.
            if (not os.path.islink(d) and os.stat(d).st_uid == os.getuid()
                    and time.time() - os.stat(d).st_mtime > 86400):
                shutil.rmtree(d, ignore_errors=True)
        except OSError:
            pass

    # Signal handlers for clean shutdown
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Load model (slow — speak.sh waits for the socket to appear)
    load_tts_model()

    # Warm up the pipeline so the first real request is fast
    warmup_pipeline()

    # Model load can take seconds — reset the idle clock to now and publish
    # initial state so the menu countdown starts from the full timeout.
    last_request_time = time.time()
    last_activity = time.monotonic()
    write_state()

    # The idle watchdog runs in every mode so the model is released after
    # IDLE_TIMEOUT of inactivity.  In managed mode we additionally run the
    # parent watchdog so the daemon also dies if the app crashes/exits.
    threading.Thread(target=idle_watchdog, daemon=True).start()
    if managed_mode:
        threading.Thread(target=parent_watchdog, daemon=True).start()

    # Create socket — this signals readiness to speak.sh (it polls for the
    # socket file to appear).
    server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server_socket.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o600)
    server_socket.listen(2)
    server_socket.settimeout(5)

    mode_str = ("managed, " if managed_mode else "") + f"idle timeout {effective_timeout()}s"
    log(f"listening on {SOCKET_PATH} ({mode_str})")

    # Accept loop — each client runs in a thread so a new request can
    # cancel a long-running generation (the hotkey toggle kills the old
    # speak.sh, whose connection drops, and the new request proceeds).
    while not shutdown_event.is_set():
        try:
            conn, _ = server_socket.accept()
            t = threading.Thread(target=handle_client, args=(conn,), daemon=True)
            t.start()
        except socket.timeout:
            continue
        except OSError:
            if not shutdown_event.is_set():
                log("socket error in accept loop")
            break

    do_shutdown()


if __name__ == "__main__":
    main()
