"""Model-free regression tests: python3 -m unittest discover -s macos/tests -p 'test_*.py'."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]


def load_daemon(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.log = lambda message: None
    return module


class DaemonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ogma-regression-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.modules = [load_daemon("tts_server"), load_daemon("stt_server")]
        for module in self.modules:
            module.CONFIG_FILE = str(Path(self.temp.name) / (module.__name__ + "-config"))
            module.STATE_FILE = str(Path(self.temp.name) / (module.__name__ + "-state"))

    def test_active_requests_survive_idle_deadline(self):
        for module in self.modules:
            with self.subTest(daemon=module.__name__):
                module.active_requests = 1
                module.last_activity = time.monotonic() - 600
                module.effective_timeout = lambda: 5
                module.do_shutdown = Mock()
                # Run one real watchdog iteration without sleeping.
                with patch.object(module.shutdown_event, "wait",
                                  side_effect=lambda seconds: module.shutdown_event.set()):
                    module.idle_watchdog()
                module.do_shutdown.assert_not_called()

    def test_idle_requests_unload(self):
        for module in self.modules:
            with self.subTest(daemon=module.__name__):
                module.last_activity = time.monotonic() - 600
                module.do_shutdown = Mock()
                module.idle_watchdog()
                module.do_shutdown.assert_called_once()

    def test_malformed_timeout_does_not_crash_watchdog(self):
        for module in self.modules:
            key = "LOCAL_IDLE_TIMEOUT" if module.__name__ == "tts_server" else "STT_IDLE_TIMEOUT"
            Path(module.CONFIG_FILE).write_text(f"{key}\n{key}_OTHER=5\n{key}=17\n")
            self.assertEqual(module.effective_timeout(), 17)
            Path(module.CONFIG_FILE).write_text(f"{key}=9999999999999999999999999\n")
            with patch.dict(os.environ, {"OGMA_IDLE_TIMEOUT": "nan", "STT_IDLE_TIMEOUT": "nan"}):
                self.assertEqual(module.effective_timeout(), 120)

    def test_concurrent_state_publication_is_valid_json(self):
        for module in self.modules:
            threads = [threading.Thread(target=lambda: [module.write_state() for _ in range(30)])
                       for _ in range(4)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            self.assertIn("last_request", json.loads(Path(module.STATE_FILE).read_text()))

    def test_stt_rejects_bad_frame_lengths_and_rates(self):
        stt = self.modules[1]
        for size in (1, 3, 1048580, 0xFFFFFFFF):
            with self.assertRaises(ValueError):
                stt.validate_frame_size(size)
        for size in (0, 4, 16384, 1048576):
            stt.validate_frame_size(size)
        for rate in (0, -1, 1, 999999999):
            with self.assertRaises(ValueError):
                stt.stream_sample_rate({"sample_rate": rate})
        self.assertEqual(stt.stream_sample_rate({}), 16000)

    def test_daemon_runtime_files_are_private(self):
        # Exercise real startup and Unix-socket permissions, replacing only
        # heavyweight model loading. Never load the user's installed models.
        script = '''
import importlib.util, sys, tempfile
spec = importlib.util.spec_from_file_location("daemon", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
tempfile.tempdir = m.DATA_DIR
m.load_tts_model = m.load_stt_model = lambda: None
m.warmup_pipeline = m.warmup = lambda: None
m.get_autocorrect = lambda: None
m.main()
'''
        for name in ("tts", "stt"):
            data = Path(self.temp.name) / name
            data.mkdir(mode=0o755)
            process = subprocess.Popen([sys.executable, "-c", script, str(ROOT / f"{name}_server.py")],
                                       env=dict(os.environ, OGMA_DATA_DIR=str(data)),
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                path = data / f"{name}.sock"
                deadline = time.monotonic() + 5
                while not path.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(path.exists(), "daemon failed to create a test socket")
                self.assertEqual(data.stat().st_mode & 0o777, 0o700)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertEqual((data / f"{name}_server.pid").stat().st_mode & 0o777, 0o600)
            finally:
                if process.poll() is None:
                    process.terminate()
                process.communicate(timeout=5)

    def test_oversized_requests_release_activity_and_return_error(self):
        mx = types.ModuleType("mlx.core")
        mx.metal = types.SimpleNamespace(clear_cache=lambda: None)
        mlx = types.ModuleType("mlx")
        mlx.core = mx
        with patch.dict("sys.modules", {"mlx": mlx, "mlx.core": mx}):
            for module in self.modules:
                with self.subTest(daemon=module.__name__):
                    conn = Mock()
                    conn.recv.return_value = b"x" * 65536
                    started = time.monotonic()
                    module.handle_client(conn)
                    self.assertLess(time.monotonic() - started, 2)
                    self.assertEqual(module.active_requests, 0)
                    self.assertGreater(module.last_activity, started)
                    reply = json.loads(conn.sendall.call_args.args[0])
                    self.assertEqual(reply["status"], "error")
                    conn.close.assert_called_once()

    def test_cancelled_parakeet_stream_does_not_flush_tail(self):
        stt = self.modules[1]
        np = types.ModuleType("numpy")
        np.float32 = "float32"
        np.zeros = lambda *args, **kwargs: []
        mx = types.ModuleType("mlx.core")
        mlx = types.ModuleType("mlx")
        mlx.core = mx
        stream = Mock()
        context = Mock()
        context.__enter__ = Mock(return_value=stream)
        context.__exit__ = Mock(return_value=False)
        stt.model = Mock()
        stt.model.preprocessor_config.sample_rate = 16000
        stt.model.transcribe_stream.return_value = context
        conn = Mock()
        conn.recv.return_value = b""
        with patch.dict("sys.modules", {"numpy": np, "mlx": mlx, "mlx.core": mx}):
            stt.handle_stream(conn, {})
        stream.add_audio.assert_not_called()
        conn.sendall.assert_not_called()


if __name__ == "__main__":
    unittest.main()
