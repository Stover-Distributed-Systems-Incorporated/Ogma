"""Exercise shell safety and failure recovery with disposable fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ShellTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ogma-shell-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)

    def executable(self, name, source):
        path = self.work / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/bash\n" + source)
        path.chmod(0o700)
        return path

    def test_invalid_numeric_values_use_defaults(self):
        source = (ROOT / "speak.sh").read_text()
        function = "_validate_num() {" + source.split("_validate_num() {", 1)[1].split("\n}", 1)[0] + "\n}"
        for key, value, expected in [("LOCAL_SPEED", "0", "1.0"), ("SPEED", "999", "1.0"),
                                     ("SPEED", ".5", "1.0"), ("SPEED", "01", "1.0"),
                                     ("SPEED", "nan", "1.0"), ("SPEED", "1.10", "1.10")]:
            result = subprocess.run(["bash", "-c", function + '\n_validate_num "$1" "$2" 1.0',
                                     "test", key, value], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), expected)

    def test_stale_pid_does_not_kill_an_unrelated_process(self):
        self.executable("bin/pbpaste", "exit 0\n")
        sleeper = subprocess.Popen(["sleep", "30"])
        try:
            (self.work / "ogma_tts.pid").write_text(str(sleeper.pid))
            env = dict(os.environ, TMPDIR=str(self.work), TTS_BACKEND="local",
                       OGMA_DATA_DIR=str(self.work / "data"),
                       OGMA_CONFIG_FILE=str(self.work / "missing-config"),
                       PATH=str(self.work / "bin") + ":" + os.environ["PATH"])
            result = subprocess.run(["bash", str(ROOT / "speak.sh")], input="", env=env,
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(sleeper.poll(), "an unrelated process was killed by a stale PID file")
        finally:
            if sleeper.poll() is None:
                sleeper.terminate()
            sleeper.wait(timeout=3)

    def test_failed_dependency_install_restores_previous_environment(self):
        venv = self.work / "venv"
        venv.mkdir()
        (venv / "pyvenv.cfg").write_text("test environment\n")
        (venv / "keep-me").write_text("old working data")
        self.executable("venv/bin/python3", "exit 1\n")
        failing_pip = self.executable("failing-pip", "exit 1\n")
        python = self.executable("fake-python", '''
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
    mkdir -p "$3/bin"
    cp "$OGMA_TEST_PIP" "$3/bin/pip"
    exit 0
fi
exit 1
''')
        source = (ROOT / "install-local.sh").read_text()
        block = source.split("# ── Create / update venv", 1)[1].split("# ── Download Kokoro model", 1)[0]
        block = block.split("\n", 1)[1]
        result = subprocess.run(["bash", "-c", 'set -e\nVENV_DIR="$1"\nPYTHON="$2"\n' + block,
                                 "test", str(venv), str(python)],
                                env=dict(os.environ, OGMA_TEST_PIP=str(failing_pip)),
                                capture_output=True, text=True, errors="replace", timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((venv / "keep-me").read_text(), "old working data")
        self.assertIn("Previous Python environment restored", result.stderr)

    def test_broad_venv_override_is_rejected_before_setup(self):
        result = subprocess.run(["bash", str(ROOT / "install-local.sh")],
                                env=dict(os.environ, VENV_DIR=str(self.work)),
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absolute path ending in venv", result.stderr)
