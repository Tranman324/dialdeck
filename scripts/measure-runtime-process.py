#!/usr/bin/env python3
"""Sample verified DialDeck process CPU time and RSS for a fixed 300s window."""

from __future__ import annotations

import argparse
import ctypes
import csv
import hashlib
import math
import os
import plistlib
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


WINDOW_SECONDS = 300
SAMPLE_INTERVAL_SECONDS = 1
DIALDECK_PROCESS_IDENTITY = "com.dialdeck.app (DialDeck.app/Contents/MacOS/DialDeckApp)"
_proc_pidpath: Callable[..., int] | None = None
_proc_pidinfo: Callable[..., int] | None = None
_libproc: ctypes.CDLL | None = None
PROC_PIDTBSDINFO = 3
MAXCOMLEN = 16


class _ProcBSDInfo(ctypes.Structure):
    """Fields used from macOS sys/proc_info.h's proc_bsdinfo."""

    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * MAXCOMLEN),
        ("pbi_name", ctypes.c_char * (2 * MAXCOMLEN)),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


@dataclass(frozen=True)
class VerifiedDialDeckProcess:
    canonical_identity: str
    executable_sha256: str
    build_epoch_ns: int


def parse_cpu_seconds(value: str) -> float:
    value = value.strip()
    days = 0
    if "-" in value:
        day_part, value = value.split("-", 1)
        days = int(day_part)
    parts = value.split(":")
    if len(parts) == 3:
        hours, minutes, seconds = parts
    elif len(parts) == 2:
        hours = "0"
        minutes, seconds = parts
    else:
        hours, minutes, seconds = "0", "0", parts[0]
    return days * 86_400 + int(hours) * 3_600 + int(minutes) * 60 + float(seconds)


def process_executable_path(pid: int) -> str:
    """Return the executable path for validation only; callers must not persist it."""
    global _libproc, _proc_pidpath
    if sys.platform != "darwin":
        raise RuntimeError("Process identity verification requires macOS libproc")
    try:
        if _proc_pidpath is None:
            _libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
            function = _libproc.proc_pidpath
            function.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
            function.restype = ctypes.c_int
            _proc_pidpath = function
        buffer = ctypes.create_string_buffer(4096)
        result = _proc_pidpath(pid, buffer, len(buffer))
    except (AttributeError, OSError) as error:
        raise RuntimeError("DialDeck process identity could not be verified") from error
    if result <= 0:
        raise RuntimeError("DialDeck process identity could not be verified")
    return os.fsdecode(buffer.value)


def process_instance_identity(pid: int) -> tuple[int, int]:
    """Return the process start time, without retaining it in evidence."""
    global _libproc, _proc_pidinfo
    if sys.platform != "darwin":
        raise RuntimeError("Process instance verification requires macOS libproc")
    try:
        if _proc_pidinfo is None:
            _libproc = _libproc or ctypes.CDLL("/usr/lib/libproc.dylib")
            function = _libproc.proc_pidinfo
            function.argtypes = (
                ctypes.c_int,
                ctypes.c_int,
                ctypes.c_uint64,
                ctypes.c_void_p,
                ctypes.c_int,
            )
            function.restype = ctypes.c_int
            _proc_pidinfo = function
        info = _ProcBSDInfo()
        result = _proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            ctypes.byref(info),
            ctypes.sizeof(info),
        )
    except (AttributeError, OSError) as error:
        raise RuntimeError("DialDeck process instance could not be verified") from error
    if result != ctypes.sizeof(info) or info.pbi_pid != pid:
        raise RuntimeError("DialDeck process instance could not be verified")
    return int(info.pbi_start_tvsec), int(info.pbi_start_tvusec)


def verify_dialdeck_process(
    pid: int,
    candidate_sha: str,
    path_reader: Callable[[int], str] | None = None,
    *,
    process_start_identity: tuple[int, int] | None = None,
) -> VerifiedDialDeckProcess:
    reader = path_reader or process_executable_path
    try:
        executable_path = Path(reader(pid))
    except (OSError, RuntimeError, ValueError) as error:
        raise RuntimeError("DialDeck process identity could not be verified") from error
    if tuple(executable_path.parts[-4:]) != ("DialDeck.app", "Contents", "MacOS", "DialDeckApp"):
        raise RuntimeError("Selected process is not the DialDeck.app executable")
    info_path = executable_path.parent.parent / "Info.plist"
    try:
        with info_path.open("rb") as bundle_info:
            info = plistlib.load(bundle_info)
        executable_digest = hashlib.sha256()
        with executable_path.open("rb") as executable:
            for chunk in iter(lambda: executable.read(1024 * 1024), b""):
                executable_digest.update(chunk)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise RuntimeError("DialDeck app bundle identity could not be verified") from error
    if (
        not isinstance(info, dict)
        or info.get("CFBundleExecutable") != "DialDeckApp"
        or info.get("CFBundleIdentifier") != "com.dialdeck.app"
    ):
        raise RuntimeError("Selected process does not match the DialDeck app bundle identity")
    if info.get("DialDeckBuildSHA") != candidate_sha.lower():
        raise RuntimeError("Selected process does not match the requested candidate SHA")
    if info.get("DialDeckExecutableSHA256") != executable_digest.hexdigest():
        raise RuntimeError("Selected process executable does not match its bundle digest")
    build_epoch_ns = info.get("DialDeckBuildEpochNS")
    if not isinstance(build_epoch_ns, int) or isinstance(build_epoch_ns, bool) or build_epoch_ns < 0:
        raise RuntimeError("Selected process bundle has no valid build timestamp")
    if process_start_identity is not None:
        process_start_ns = process_start_identity[0] * 1_000_000_000 + process_start_identity[1] * 1_000
        if process_start_ns <= build_epoch_ns:
            raise RuntimeError("Selected process started before the verified bundle was built")
    return VerifiedDialDeckProcess(
        canonical_identity=DIALDECK_PROCESS_IDENTITY,
        executable_sha256=executable_digest.hexdigest(),
        build_epoch_ns=build_epoch_ns,
    )


def read_process_sample(
    pid: int,
    candidate_sha: str,
    *,
    instance_reader: Callable[[int], tuple[int, int]] = process_instance_identity,
    identity_verifier: Callable[[int, str], VerifiedDialDeckProcess] = verify_dialdeck_process,
) -> tuple[float, int, tuple[int, int]]:
    instance_before = instance_reader(pid)
    identity_before = identity_verifier(pid, candidate_sha)
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "cputime=", "-o", "rss="],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError("The selected process is no longer available")
    fields = result.stdout.split()
    if len(fields) != 2:
        raise RuntimeError("The process sampler returned an unexpected counter format")
    cpu_seconds, rss_kib = parse_cpu_seconds(fields[0]), int(fields[1])
    identity_after = identity_verifier(pid, candidate_sha)
    instance_after = instance_reader(pid)
    if instance_after != instance_before:
        raise RuntimeError("The selected process instance changed during sampling")
    if identity_after != identity_before:
        raise RuntimeError("The selected process identity changed during sampling")
    return cpu_seconds, rss_kib, instance_before


def collect_samples(
    pid: int,
    candidate_sha: str,
    *,
    window_seconds: float = WINDOW_SECONDS,
    sample_interval_seconds: float = SAMPLE_INTERVAL_SECONDS,
    read_sample: Callable[[int, str], tuple[float, int, tuple[int, int]]] = read_process_sample,
    monotonic_ns: Callable[[], int] = time.monotonic_ns,
    sleep: Callable[[float], None] = time.sleep,
    expected_process_instance: tuple[int, int] | None = None,
) -> list[tuple[float, float, int]]:
    if window_seconds <= 0 or sample_interval_seconds <= 0:
        raise ValueError("Sampling window and interval must be positive")
    window_ns = math.ceil(window_seconds * 1_000_000_000)
    interval_ns = max(1, math.ceil(sample_interval_seconds * 1_000_000_000))

    first_cpu, first_rss, process_instance = read_sample(pid, candidate_sha)
    if expected_process_instance is not None and process_instance != expected_process_instance:
        raise RuntimeError("The selected process instance changed after bundle verification")
    first_observed_ns = monotonic_ns()
    samples = [(0.0, first_cpu, first_rss)]
    interval_count = math.ceil(window_ns / interval_ns)

    for index in range(1, interval_count + 1):
        target_ns = first_observed_ns + min(index * interval_ns, window_ns)
        while True:
            remaining_ns = target_ns - monotonic_ns()
            if remaining_ns <= 0:
                break
            sleep(remaining_ns / 1_000_000_000)
        cpu_seconds, rss_kib, observed_instance = read_sample(pid, candidate_sha)
        if observed_instance != process_instance:
            raise RuntimeError("The selected process instance changed during sampling")
        if cpu_seconds < samples[-1][1]:
            raise RuntimeError("The selected process CPU counter decreased during sampling")
        observed_ns = monotonic_ns()
        elapsed_seconds = (observed_ns - first_observed_ns) / 1_000_000_000
        samples.append((elapsed_seconds, cpu_seconds, rss_kib))

    if samples[-1][0] < window_seconds:
        raise RuntimeError("Observed process-counter samples did not span the required window")
    return samples


def validate_candidate_sha(value: str) -> str:
    if len(value) != 40 or any(char not in "0123456789abcdefABCDEF" for char in value):
        raise argparse.ArgumentTypeError("must be a concrete 40-character hexadecimal commit SHA")
    return value.lower()


def percentile(values: list[int], fraction: float) -> int:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def cpu_counter_threshold_result(scenario: str, one_core_percent: float) -> str:
    if scenario not in ("idle-connected", "idle-disconnected"):
        return "NOT_APPLICABLE"
    return "COUNTER_ONLY_PASS" if one_core_percent < 1.0 else "COUNTER_ONLY_FAIL"


def run() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Sample a verified DialDeck.app PID for at least five minutes. "
            "Warm up the app and prepare the requested scenario before starting."
        )
    )
    parser.add_argument("--pid", type=int, required=True, help="PID of DialDeck.app's executable")
    parser.add_argument(
        "--scenario",
        choices=("idle-connected", "idle-disconnected", "focus-cycles", "reconnect-cycles"),
        required=True,
    )
    parser.add_argument(
        "--cycle-count",
        type=int,
        help="Operator-reported completed cycles for focus-cycles or reconnect-cycles scenarios",
    )
    parser.add_argument("--candidate-sha", type=validate_candidate_sha, required=True, help="Concrete 40-character candidate commit SHA")
    parser.add_argument("--output", type=Path, required=True, help="New CSV evidence file path")
    args = parser.parse_args()

    if args.pid <= 1:
        parser.error("--pid must identify a user process")
    is_cycle_scenario = args.scenario in ("focus-cycles", "reconnect-cycles")
    if is_cycle_scenario and (args.cycle_count is None or args.cycle_count < 1):
        parser.error("--cycle-count >= 1 is required for focus-cycles and reconnect-cycles")
    if not is_cycle_scenario and args.cycle_count is not None:
        parser.error("--cycle-count is only valid for focus-cycles and reconnect-cycles")
    if args.output.exists():
        parser.error("--output must not already exist")
    try:
        process_instance = process_instance_identity(args.pid)
        process_identity = verify_dialdeck_process(
            args.pid,
            args.candidate_sha,
            process_start_identity=process_instance,
        )
        if process_instance_identity(args.pid) != process_instance:
            raise RuntimeError("The selected process instance changed during bundle verification")
    except RuntimeError as error:
        parser.error(str(error))
    args.output.parent.mkdir(parents=True, exist_ok=True)

    logical_cpu_count = os.cpu_count() or 1
    try:
        samples = collect_samples(
            args.pid,
            args.candidate_sha,
            expected_process_instance=process_instance,
        )
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Measurement stopped: {error}", file=sys.stderr)
        return 2

    elapsed = samples[-1][0] - samples[0][0]
    if elapsed < WINDOW_SECONDS:
        print("Measurement stopped: observed counter samples did not span 300 seconds", file=sys.stderr)
        return 2
    cpu_delta = samples[-1][1] - samples[0][1]
    one_core_percent = 100.0 * cpu_delta / elapsed
    host_percent = one_core_percent / logical_cpu_count
    rss_values = [sample[2] for sample in samples]
    settled_rss = int(statistics.median(rss_values[-30:]))
    threshold_result = cpu_counter_threshold_result(args.scenario, one_core_percent)

    with args.output.open("x", newline="", encoding="utf-8") as evidence:
        evidence.write(f"# candidate_sha={args.candidate_sha}\n")
        evidence.write(
            f"# process_identity={process_identity.canonical_identity} "
            "(verified; full executable path not retained)\n"
        )
        evidence.write(f"# executable_sha256={process_identity.executable_sha256}\n")
        evidence.write(f"# bundle_build_epoch_ns={process_identity.build_epoch_ns}\n")
        evidence.write(f"# scenario={args.scenario}\n")
        if args.cycle_count is not None:
            evidence.write(f"# operator_reported_completed_cycles={args.cycle_count}\n")
        evidence.write(f"# required_window_seconds={WINDOW_SECONDS}\n")
        evidence.write(f"# observed_counter_sample_span_seconds={elapsed:.3f}\n")
        evidence.write(f"# logical_cpu_count={logical_cpu_count}\n")
        evidence.write("# cpu_counter=verified DialDeck PID ps cputime delta over monotonic first-to-last sample span\n")
        evidence.write("# denominator=100 percent is one logical CPU; host-normalized divides by logical CPU count\n")
        evidence.write("# rss_counter=ps resident set size in KiB, converted to MiB in samples\n")
        evidence.write("# warmup=completed by operator before sampling; target-app details are not recorded\n")
        evidence.write("# application_acceptance=NOT_ASSESSED (process counters do not establish user-visible behavior)\n")
        writer = csv.writer(evidence)
        writer.writerow(("elapsed_seconds", "cumulative_cpu_seconds", "cpu_percent_one_core", "cpu_percent_host_normalized", "rss_mib"))
        previous_elapsed, previous_cpu, _ = samples[0]
        for elapsed_seconds, cpu_seconds, rss_kib in samples:
            interval = elapsed_seconds - previous_elapsed
            cpu_delta_interval = cpu_seconds - previous_cpu
            interval_one_core = 100.0 * cpu_delta_interval / interval if interval > 0 else 0.0
            writer.writerow((
                f"{elapsed_seconds:.3f}",
                f"{cpu_seconds:.2f}",
                f"{interval_one_core:.4f}",
                f"{interval_one_core / logical_cpu_count:.4f}",
                f"{rss_kib / 1024:.2f}",
            ))
            previous_elapsed, previous_cpu = elapsed_seconds, cpu_seconds
        evidence.write(f"# elapsed_seconds={elapsed:.3f}\n")
        evidence.write(f"# average_cpu_percent_one_core={one_core_percent:.4f}\n")
        evidence.write(f"# average_cpu_percent_host_normalized={host_percent:.4f}\n")
        evidence.write(f"# cpu_below_1_percent_one_core={threshold_result}\n")
        evidence.write(f"# rss_baseline_mib={rss_values[0] / 1024:.2f}\n")
        evidence.write(f"# rss_peak_mib={max(rss_values) / 1024:.2f}\n")
        evidence.write(f"# rss_settled_median_last_30_samples_mib={settled_rss / 1024:.2f}\n")
        evidence.write("# energy=not captured by this process sampler; see docs/runtime-measurement.md\n")

    print(f"Scenario: {args.scenario}")
    print(f"Process identity: {process_identity.canonical_identity} (verified; full path omitted)")
    print(f"Executable SHA256: {process_identity.executable_sha256}")
    print(f"Window: {elapsed:.3f}s (required >=300s)")
    print(f"CPU average: {one_core_percent:.4f}% of one logical CPU; {host_percent:.4f}% host-normalized")
    print(f"CPU counter threshold (<1% of one logical CPU): {threshold_result}")
    print("Application acceptance: NOT_ASSESSED")
    print(
        "RSS MiB: "
        f"baseline={rss_values[0] / 1024:.2f}, peak={max(rss_values) / 1024:.2f}, "
        f"settled-median-last-30={settled_rss / 1024:.2f}"
    )
    print(f"Evidence file name: {args.output.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
