"""Compile and exercise production Swift components without launching Ogma."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "requires macOS frameworks")
class NativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="ogma-swift-", dir="/tmp")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.work = Path(cls.directory.name)
        source = (ROOT / "Ogma.swift").read_text()
        config = source.split("// MARK: - Static data")[0]
        stream = source.split("struct STTWord {")[1].split("// MARK: - Floating dictation")[0]
        tests = (ROOT / "tests/reliability.swift").read_text()
        (cls.work / "main.swift").write_text(config + "\nstruct STTWord {" + stream + "\n" + tests)
        cls.binary = cls.work / "native-tests"
        build = subprocess.run(["xcrun", "swiftc", str(cls.work / "main.swift"), "-o", str(cls.binary),
                        "-module-cache-path", str(cls.work / "cache")],
                       capture_output=True, text=True, timeout=120)
        if build.returncode:
            raise RuntimeError(build.stderr)

    def test_native_regressions(self):
        result = subprocess.run([str(self.binary), str(self.work)], capture_output=True,
                                text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS:", result.stdout)

    def test_invalid_audio_does_not_hang_queue_protocol(self):
        binary = self.work / "ogma-audio"
        subprocess.run(["xcrun", "swiftc", str(ROOT / "ogma-audio.swift"), "-o", str(binary),
                        "-module-cache-path", str(self.work / "cache")], check=True,
                       capture_output=True, text=True, timeout=120)
        result = subprocess.run([str(binary), "play-queue"],
                                input=f"{self.work}/missing.wav\t0\t0\t1\t{self.work}/status\t0\n",
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["0.000", "DONE"])
