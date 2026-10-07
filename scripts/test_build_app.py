from __future__ import annotations

import hashlib
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("build-app.sh")


class BuildAppStampTests(unittest.TestCase):
    def make_project(self, directory: str) -> tuple[Path, Path, Path]:
        root = Path(directory) / "project"
        scripts = root / "scripts"
        sources = root / "Sources"
        scripts.mkdir(parents=True)
        sources.mkdir()
        shutil.copy2(SCRIPT, scripts / "build-app.sh")
        (sources / "main.swift").write_text("print(\"fixture\")\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.name", "Build Test"], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.email", "build-test@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(root), "add", "scripts/build-app.sh", "Sources/main.swift"], check=True)
        subprocess.run(["git", "-C", str(root), "commit", "-qm", "test fixture"], check=True)

        fake_bin = Path(directory) / "fake-bin"
        fake_bin.mkdir()
        app_binary_dir = Path(directory) / "fake-build-output"
        app_binary_dir.mkdir()
        (app_binary_dir / "DialDeckApp").write_bytes(b"candidate fixture binary")
        swift = fake_bin / "swift"
        swift.write_text(
            "#!/bin/sh\n"
            "if [ \"${DIALDECK_MUTATE_SOURCE:-0}\" = 1 ] && [ ! -e \"$DIALDECK_MUTATION_DONE\" ]; then\n"
            "  printf '\\n// modified during build\\n' >> \"$DIALDECK_SOURCE_TO_MUTATE\"\n"
            "  : > \"$DIALDECK_MUTATION_DONE\"\n"
            "fi\n"
            "case \" $* \" in\n"
            "  *\" --show-bin-path \"*) printf '%s\\n' \"$DIALDECK_FAKE_BIN_DIR\" ;;\n"
            "  *) : > \"$DIALDECK_SWIFT_MARKER\" ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        swift.chmod(0o755)
        return root, fake_bin, app_binary_dir

    def run_build(
        self,
        root: Path,
        fake_bin: Path,
        app_binary_dir: Path,
        *,
        mutate_source: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        marker = app_binary_dir.parent / "swift-was-run"
        env = os.environ.copy()
        env["PATH"] = f"{fake_bin}{os.pathsep}{env.get('PATH', '')}"
        env["DIALDECK_FAKE_BIN_DIR"] = str(app_binary_dir)
        env["DIALDECK_SWIFT_MARKER"] = str(marker)
        env["DIALDECK_SOURCE_TO_MUTATE"] = str(root / "Sources/main.swift")
        env["DIALDECK_MUTATION_DONE"] = str(app_binary_dir.parent / "mutation-done")
        env["DIALDECK_MUTATE_SOURCE"] = "1" if mutate_source else "0"
        result = subprocess.run(
            ["sh", str(root / "scripts/build-app.sh")],
            cwd=root,
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )
        result.swift_marker = marker  # type: ignore[attr-defined]
        return result

    def test_clean_build_stamps_commit_and_executable_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, fake_bin, app_binary_dir = self.make_project(directory)
            expected_commit = subprocess.check_output(
                ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
            ).strip()
            result = self.run_build(root, fake_bin, app_binary_dir)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected_commit, result.stdout)
            info_path = root / ".build/DialDeck.app/Contents/Info.plist"
            with info_path.open("rb") as bundle:
                info = plistlib.load(bundle)
            executable = root / ".build/DialDeck.app/Contents/MacOS/DialDeckApp"
            self.assertEqual(info["DialDeckBuildSHA"], expected_commit)
            self.assertEqual(
                info["DialDeckExecutableSHA256"],
                hashlib.sha256(executable.read_bytes()).hexdigest(),
            )

    def test_modified_staged_and_untracked_sources_are_rejected_before_build(self) -> None:
        for dirty_kind in ("modified", "staged", "untracked"):
            with self.subTest(dirty_kind=dirty_kind), tempfile.TemporaryDirectory() as directory:
                root, fake_bin, app_binary_dir = self.make_project(directory)
                source = root / "Sources/main.swift"
                if dirty_kind == "untracked":
                    (root / "Sources/new.swift").write_text("print(\"new\")\n", encoding="utf-8")
                else:
                    source.write_text("print(\"changed\")\n", encoding="utf-8")
                    if dirty_kind == "staged":
                        subprocess.run(["git", "-C", str(root), "add", "Sources/main.swift"], check=True)

                result = self.run_build(root, fake_bin, app_binary_dir)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("dirty worktree", result.stderr)
                self.assertFalse(result.swift_marker.exists())  # type: ignore[attr-defined]

    def test_source_change_during_compilation_is_rejected_before_stamping(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, fake_bin, app_binary_dir = self.make_project(directory)
            result = self.run_build(root, fake_bin, app_binary_dir, mutate_source=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("dirty worktree", result.stderr)
            self.assertTrue(result.swift_marker.exists())  # type: ignore[attr-defined]
            self.assertFalse((root / ".build/DialDeck.app/Contents/Info.plist").exists())


if __name__ == "__main__":
    unittest.main()
