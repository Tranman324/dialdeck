#!/usr/bin/env python3
"""Sample DialDeck process CPU time and resident memory for a fixed 300s window."""

from __future__ import annotations

import argparse
import csv
import math
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path


WINDOW_SECONDS = 300
SAMPLE_INTERVAL_SECONDS = 1


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


def read_process_sample(pid: int) -> tuple[float, int]:
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
    return parse_cpu_seconds(fields[0]), int(fields[1])


def percentile(values: list[int], fraction: float) -> int:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def run() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Sample one supplied DialDeck PID for exactly five minutes. "
            "Warm up the app and prepare the requested scenario before starting."
        )
    )
    parser.add_argument("--pid", type=int, required=True, help="PID of the DialDeck.app process")
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
    parser.add_argument("--candidate-sha", default="unknown", help="40-character candidate commit SHA")
    parser.add_argument("--output", type=Path, required=True, help="New CSV evidence file path")
    args = parser.parse_args()

    if args.pid <= 1:
        parser.error("--pid must identify a user process")
    if args.candidate_sha != "unknown" and (
        len(args.candidate_sha) != 40 or any(char not in "0123456789abcdefABCDEF" for char in args.candidate_sha)
    ):
        parser.error("--candidate-sha must be a 40-character hexadecimal SHA or omitted")
    is_cycle_scenario = args.scenario in ("focus-cycles", "reconnect-cycles")
    if is_cycle_scenario and (args.cycle_count is None or args.cycle_count < 1):
        parser.error("--cycle-count >= 1 is required for focus-cycles and reconnect-cycles")
    if not is_cycle_scenario and args.cycle_count is not None:
        parser.error("--cycle-count is only valid for focus-cycles and reconnect-cycles")
    if args.output.exists():
        parser.error("--output must not already exist")
    args.output.parent.mkdir(parents=True, exist_ok=True)

    logical_cpu_count = os.cpu_count() or 1
    samples: list[tuple[float, float, int]] = []
    start_ns = time.monotonic_ns()
    try:
        for index in range(WINDOW_SECONDS + 1):
            target_ns = start_ns + index * SAMPLE_INTERVAL_SECONDS * 1_000_000_000
            remaining_ns = target_ns - time.monotonic_ns()
            if remaining_ns > 0:
                time.sleep(remaining_ns / 1_000_000_000)
            observed_ns = time.monotonic_ns()
            cpu_seconds, rss_kib = read_process_sample(args.pid)
            elapsed_seconds = (observed_ns - start_ns) / 1_000_000_000
            samples.append((elapsed_seconds, cpu_seconds, rss_kib))
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Measurement stopped: {error}", file=sys.stderr)
        return 2

    elapsed = samples[-1][0] - samples[0][0]
    cpu_delta = max(0.0, samples[-1][1] - samples[0][1])
    one_core_percent = 100.0 * cpu_delta / elapsed if elapsed > 0 else 0.0
    host_percent = one_core_percent / logical_cpu_count
    rss_values = [sample[2] for sample in samples]
    settled_rss = int(statistics.median(rss_values[-30:]))
    idle_scenario = args.scenario in ("idle-connected", "idle-disconnected")
    threshold_result = "PASS" if idle_scenario and one_core_percent < 1.0 else (
        "FAIL" if idle_scenario else "NOT_APPLICABLE"
    )

    with args.output.open("x", newline="", encoding="utf-8") as evidence:
        evidence.write(f"# candidate_sha={args.candidate_sha}\n")
        evidence.write(f"# scenario={args.scenario}\n")
        if args.cycle_count is not None:
            evidence.write(f"# operator_reported_completed_cycles={args.cycle_count}\n")
        evidence.write(f"# required_window_seconds={WINDOW_SECONDS}\n")
        evidence.write(f"# logical_cpu_count={logical_cpu_count}\n")
        evidence.write("# cpu_counter=per-process ps cputime delta over monotonic elapsed wall time\n")
        evidence.write("# denominator=100 percent is one logical CPU; host-normalized divides by logical CPU count\n")
        evidence.write("# rss_counter=ps resident set size in KiB, converted to MiB in samples\n")
        evidence.write("# warmup=completed by operator before sampling; app and target app details are not recorded\n")
        writer = csv.writer(evidence)
        writer.writerow(("elapsed_seconds", "cumulative_cpu_seconds", "cpu_percent_one_core", "cpu_percent_host_normalized", "rss_mib"))
        previous_elapsed, previous_cpu, _ = samples[0]
        for elapsed_seconds, cpu_seconds, rss_kib in samples:
            interval = elapsed_seconds - previous_elapsed
            cpu_delta_interval = max(0.0, cpu_seconds - previous_cpu)
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
    print(f"Window: {elapsed:.3f}s (required 300s)")
    print(f"CPU average: {one_core_percent:.4f}% of one logical CPU; {host_percent:.4f}% host-normalized")
    print(f"CPU threshold (<1% of one logical CPU): {threshold_result}")
    print(
        "RSS MiB: "
        f"baseline={rss_values[0] / 1024:.2f}, peak={max(rss_values) / 1024:.2f}, "
        f"settled-median-last-30={settled_rss / 1024:.2f}"
    )
    print(f"Evidence: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
