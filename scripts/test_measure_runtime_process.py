from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("measure-runtime-process.py")
SPEC = importlib.util.spec_from_file_location("measure_runtime_process", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
sampler = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = sampler
SPEC.loader.exec_module(sampler)
CANDIDATE_SHA = "a" * 40
CANDIDATE_BUILD_ID = "b" * 32


class FakeClock:
    def __init__(self) -> None:
        self.now_ns = 0
        self.sample_count = 0

    def monotonic_ns(self) -> int:
        return self.now_ns

    def sleep(self, seconds: float) -> None:
        self.now_ns += round(seconds * 1_000_000_000)

    def read_sample(self, _pid: int, _candidate_sha: str, _candidate_build_id: str) -> tuple[float, int, tuple[int, int]]:
        self.sample_count += 1
        # Make the initial counter read slower than later reads. Scheduling from
        # before that first observation would leave the observed span short.
        if self.sample_count == 1:
            self.now_ns += 50_000_000
        return float(self.sample_count), 1024, (1, 2)


class ChangingProcessClock(FakeClock):
    def __init__(self, *, change_instance: bool = False, decrease_cpu: bool = False) -> None:
        super().__init__()
        self.change_instance = change_instance
        self.decrease_cpu = decrease_cpu

    def read_sample(self, _pid: int, _candidate_sha: str, _candidate_build_id: str) -> tuple[float, int, tuple[int, int]]:
        self.sample_count += 1
        if self.sample_count == 1:
            self.now_ns += 50_000_000
        cpu = 2.0 if self.sample_count == 1 else 1.0 if self.decrease_cpu else float(self.sample_count)
        instance = (self.sample_count, 0) if self.change_instance else (1, 2)
        return cpu, 1024, instance


def create_app_bundle(
    directory: str,
    *,
    path_executable: str = "DialDeckApp",
    bundle_executable: str = "DialDeckApp",
    bundle_identifier: str = "com.dialdeck.app",
    build_sha: str = CANDIDATE_SHA,
    build_id: str = CANDIDATE_BUILD_ID,
    executable_sha256: str | None = None,
) -> Path:
    executable = Path(directory) / "DialDeck.app" / "Contents" / "MacOS" / path_executable
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"fixture DialDeck executable")
    actual_sha256 = hashlib.sha256(executable.read_bytes()).hexdigest()
    info_path = executable.parent.parent / "Info.plist"
    with info_path.open("wb") as bundle_info:
        plistlib.dump(
            {
                "CFBundleExecutable": bundle_executable,
                "CFBundleIdentifier": bundle_identifier,
                "DialDeckBuildSHA": build_sha,
                "DialDeckBuildID": build_id,
                "DialDeckExecutableSHA256": executable_sha256 or actual_sha256,
            },
            bundle_info,
        )
    return executable


class ProcessSamplerTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "macOS libproc is required")
    def test_macos_process_instance_reader_returns_start_time(self) -> None:
        start_seconds, start_microseconds = sampler.process_instance_identity(os.getpid())
        self.assertGreater(start_seconds, 0)
        self.assertGreaterEqual(start_microseconds, 0)
        self.assertLess(start_microseconds, 1_000_000)

    def test_dialdeck_process_identity_is_canonical_and_does_not_return_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = create_app_bundle(directory)
            identity = sampler.verify_dialdeck_process(
                4321,
                CANDIDATE_SHA,
                CANDIDATE_BUILD_ID,
                path_reader=lambda _pid: str(executable),
            )
            self.assertEqual(
                identity.canonical_identity,
                "com.dialdeck.app (DialDeck.app/Contents/MacOS/DialDeckApp)",
            )
            self.assertNotIn(directory, repr(identity))

    def test_dialdeck_build_id_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = create_app_bundle(directory, build_id="c" * 32)
            with self.assertRaisesRegex(RuntimeError, "candidate build ID"):
                sampler.verify_dialdeck_process(
                    4321,
                    CANDIDATE_SHA,
                    CANDIDATE_BUILD_ID,
                    path_reader=lambda _pid: str(executable),
                )

    def test_dialdeck_executable_with_wrong_bundle_identifier_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = create_app_bundle(directory, bundle_identifier="com.example.other")
            with self.assertRaisesRegex(RuntimeError, "bundle identity"):
                sampler.verify_dialdeck_process(
                    4321,
                    CANDIDATE_SHA,
                    CANDIDATE_BUILD_ID,
                    path_reader=lambda _pid: str(executable),
                )

    def test_dialdeck_executable_metadata_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = create_app_bundle(directory, bundle_executable="DialDeck")
            with self.assertRaisesRegex(RuntimeError, "bundle identity"):
                sampler.verify_dialdeck_process(
                    4321,
                    CANDIDATE_SHA,
                    CANDIDATE_BUILD_ID,
                    path_reader=lambda _pid: str(executable),
                )

    def test_dialdeck_build_sha_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = create_app_bundle(directory, build_sha="b" * 40)
            with self.assertRaisesRegex(RuntimeError, "candidate SHA"):
                sampler.verify_dialdeck_process(
                    4321,
                    CANDIDATE_SHA,
                    CANDIDATE_BUILD_ID,
                    path_reader=lambda _pid: str(executable),
                )

    def test_dialdeck_executable_bundle_digest_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = create_app_bundle(directory, executable_sha256="0" * 64)
            with self.assertRaisesRegex(RuntimeError, "bundle digest"):
                sampler.verify_dialdeck_process(
                    4321,
                    CANDIDATE_SHA,
                    CANDIDATE_BUILD_ID,
                    path_reader=lambda _pid: str(executable),
                )

    def test_arbitrary_process_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "not the DialDeck.app executable"):
            sampler.verify_dialdeck_process(
                4321,
                CANDIDATE_SHA,
                CANDIDATE_BUILD_ID,
                path_reader=lambda _pid: "/usr/bin/python3",
            )

    def test_candidate_sha_must_be_concrete(self) -> None:
        with self.assertRaises(argparse.ArgumentTypeError):
            sampler.validate_candidate_sha("unknown")
        self.assertEqual(sampler.validate_candidate_sha("a" * 40), "a" * 40)

    def test_candidate_build_id_must_be_concrete(self) -> None:
        with self.assertRaises(argparse.ArgumentTypeError):
            sampler.validate_candidate_build_id("unknown")
        self.assertEqual(sampler.validate_candidate_build_id(CANDIDATE_BUILD_ID), CANDIDATE_BUILD_ID)

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
                    "--candidate-build-id",
                    CANDIDATE_BUILD_ID,
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
            CANDIDATE_BUILD_ID,
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

    def test_sampling_rejects_a_process_id_reused_mid_window(self) -> None:
        clock = ChangingProcessClock(change_instance=True)
        with self.assertRaisesRegex(RuntimeError, "process instance changed"):
            sampler.collect_samples(
                4321,
                CANDIDATE_SHA,
                CANDIDATE_BUILD_ID,
                window_seconds=2,
                sample_interval_seconds=1,
                read_sample=clock.read_sample,
                monotonic_ns=clock.monotonic_ns,
                sleep=clock.sleep,
            )

    def test_sampling_rejects_process_replaced_after_bundle_preflight(self) -> None:
        clock = FakeClock()
        with self.assertRaisesRegex(RuntimeError, "changed after bundle verification"):
            sampler.collect_samples(
                4321,
                CANDIDATE_SHA,
                CANDIDATE_BUILD_ID,
                window_seconds=1,
                sample_interval_seconds=1,
                read_sample=clock.read_sample,
                monotonic_ns=clock.monotonic_ns,
                sleep=clock.sleep,
                expected_process_instance=(9, 9),
            )

    def test_sampling_rejects_a_decreasing_cpu_counter(self) -> None:
        clock = ChangingProcessClock(decrease_cpu=True)
        with self.assertRaisesRegex(RuntimeError, "CPU counter decreased"):
            sampler.collect_samples(
                4321,
                CANDIDATE_SHA,
                CANDIDATE_BUILD_ID,
                window_seconds=2,
                sample_interval_seconds=1,
                read_sample=clock.read_sample,
                monotonic_ns=clock.monotonic_ns,
                sleep=clock.sleep,
            )

    def test_process_sample_rejects_pid_reuse_during_one_counter_read(self) -> None:
        instance_values = iter(((10, 100), (11, 200)))
        completed = subprocess.CompletedProcess(
            args=["/bin/ps"], returncode=0, stdout="00:00:01 1024\n", stderr=""
        )
        with patch.object(sampler.subprocess, "run", return_value=completed):
            with self.assertRaisesRegex(RuntimeError, "process instance changed"):
                sampler.read_process_sample(
                    4321,
                    CANDIDATE_SHA,
                    CANDIDATE_BUILD_ID,
                    instance_reader=lambda _pid: next(instance_values),
                    identity_verifier=lambda _pid, _sha, _build_id: sampler.DIALDECK_PROCESS_IDENTITY,
                )

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
