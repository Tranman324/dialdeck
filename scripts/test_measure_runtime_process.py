from __future__ import annotations

import argparse
import importlib.util
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("measure-runtime-process.py")
SPEC = importlib.util.spec_from_file_location("measure_runtime_process", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
sampler = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sampler)
CANDIDATE_SHA = "a" * 40


class FakeClock:
    def __init__(self) -> None:
        self.now_ns = 0
        self.sample_count = 0

    def monotonic_ns(self) -> int:
        return self.now_ns

    def sleep(self, seconds: float) -> None:
        self.now_ns += round(seconds * 1_000_000_000)

    def read_sample(self, _pid: int, _candidate_sha: str) -> tuple[float, int]:
        self.sample_count += 1
        # Make the initial counter read slower than later reads. Scheduling from
        # before that first observation would leave the observed span short.
        if self.sample_count == 1:
            self.now_ns += 50_000_000
        return float(self.sample_count), 1024


def create_app_bundle(
    directory: str,
    *,
    path_executable: str = "DialDeckApp",
    bundle_executable: str = "DialDeckApp",
    bundle_identifier: str = "com.dialdeck.app",
    build_sha: str = CANDIDATE_SHA,
) -> Path:
    executable = Path(directory) / "DialDeck.app" / "Contents" / "MacOS" / path_executable
    executable.parent.mkdir(parents=True)
    info_path = executable.parent.parent / "Info.plist"
    with info_path.open("wb") as bundle_info:
        plistlib.dump(
            {
                "CFBundleExecutable": bundle_executable,
                "CFBundleIdentifier": bundle_identifier,
                "DialDeckBuildSHA": build_sha,
            },
            bundle_info,
        )
    return executable


class ProcessSamplerTests(unittest.TestCase):
    def test_dialdeck_process_identity_is_canonical_and_does_not_return_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = create_app_bundle(directory)
            identity = sampler.verify_dialdeck_process(
                4321,
                CANDIDATE_SHA,
                path_reader=lambda _pid: str(executable),
            )
            self.assertEqual(
                identity,
                "com.dialdeck.app (DialDeck.app/Contents/MacOS/DialDeckApp)",
            )
            self.assertNotIn(directory, identity)

    def test_dialdeck_executable_with_wrong_bundle_identifier_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = create_app_bundle(directory, bundle_identifier="com.example.other")
            with self.assertRaisesRegex(RuntimeError, "bundle identity"):
                sampler.verify_dialdeck_process(
                    4321,
                    CANDIDATE_SHA,
                    path_reader=lambda _pid: str(executable),
                )

    def test_dialdeck_executable_metadata_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = create_app_bundle(directory, bundle_executable="DialDeck")
            with self.assertRaisesRegex(RuntimeError, "bundle identity"):
                sampler.verify_dialdeck_process(
                    4321,
                    CANDIDATE_SHA,
                    path_reader=lambda _pid: str(executable),
                )

    def test_dialdeck_build_sha_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = create_app_bundle(directory, build_sha="b" * 40)
            with self.assertRaisesRegex(RuntimeError, "candidate SHA"):
                sampler.verify_dialdeck_process(
                    4321,
                    CANDIDATE_SHA,
                    path_reader=lambda _pid: str(executable),
                )

    def test_arbitrary_process_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "not the DialDeck.app executable"):
            sampler.verify_dialdeck_process(
                4321,
                CANDIDATE_SHA,
                path_reader=lambda _pid: "/usr/bin/python3",
            )

    def test_candidate_sha_must_be_concrete(self) -> None:
        with self.assertRaises(argparse.ArgumentTypeError):
            sampler.validate_candidate_sha("unknown")
        self.assertEqual(sampler.validate_candidate_sha("a" * 40), "a" * 40)

    def test_cli_rejects_arbitrary_process_and_missing_sha_without_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence.csv"
            arbitrary_process = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--pid",
                    str(os.getpid()),
                    "--scenario",
                    "idle-connected",
                    "--candidate-sha",
                    CANDIDATE_SHA,
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(arbitrary_process.returncode, 2)
            self.assertIn("DialDeck", arbitrary_process.stderr)
            self.assertFalse(output.exists())

            missing_sha = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--pid",
                    "12345",
                    "--scenario",
                    "idle-connected",
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(missing_sha.returncode, 2)
            self.assertIn("--candidate-sha", missing_sha.stderr)
            self.assertFalse(output.exists())

    def test_counter_window_spans_at_least_300_seconds_between_observations(self) -> None:
        clock = FakeClock()
        samples = sampler.collect_samples(
            4321,
            CANDIDATE_SHA,
            window_seconds=300,
            sample_interval_seconds=1,
            read_sample=clock.read_sample,
            monotonic_ns=clock.monotonic_ns,
            sleep=clock.sleep,
        )
        self.assertEqual(len(samples), 301)
        observed_span = samples[-1][0] - samples[0][0]
        self.assertEqual(observed_span, 300)
        self.assertGreaterEqual(observed_span, 300)

    def test_cpu_threshold_is_labeled_as_counter_only(self) -> None:
        self.assertEqual(
            sampler.cpu_counter_threshold_result("idle-connected", 0.25),
            "COUNTER_ONLY_PASS",
        )
        self.assertEqual(
            sampler.cpu_counter_threshold_result("idle-connected", 1.25),
            "COUNTER_ONLY_FAIL",
        )
        self.assertEqual(
            sampler.cpu_counter_threshold_result("focus-cycles", 0.0),
            "NOT_APPLICABLE",
        )


if __name__ == "__main__":
    unittest.main()
