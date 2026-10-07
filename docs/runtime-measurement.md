# Runtime recovery and measurement guide

## Instrumentation boundary

`RuntimeMeasurementRecorder` keeps a bounded ring of monotonic durations and normalized input classes only. It records the interval from entry to `ActionRuntime.consume` (or `dialPressed`) until the first call to `HostActionServicing.perform`. It excludes hardware callback, report decoding, and producer queue time. One event contributes only one receipt-to-dispatch sample, even when a configured sequence dispatches several actions.

The recorder reports these timing categories separately:

- `receiptToDispatch`: runtime receipt to first service dispatch.
- `serviceCall`: one injected host-action adapter call, from invocation through return.
- `sequenceAction`: one configured sequence action step.
- `sequencePause`: one configured sequence pause.

The service call duration is an adapter duration, not an observed target-application response. This repository currently has no production host-action adapter or app composition root, so target-application response remains unmeasured. Instrumentation contains no control IDs, key values, shortcut names, clipboard contents, or app content.

## Deterministic offline workload

Run the synthetic runtime workload with:

```sh
swift test --package-path . --arch arm64 --filter ActionRuntimeTests/testRuntimeMeasurementHarnessSeparatesDispatchServiceAndSequenceTiming
```

It submits 50 dial-rotation events with 10 ms spacing, then 50 more with no added gap, through `ActionRuntime` with an injected input producer and recording action-service double. Each event runs two service actions with a configured 2 ms pause. The test checks 50 receipt-to-dispatch samples, 100 adapter calls, 100 sequence action steps, and 50 pause samples for each workload. Its output is labeled `SIMULATED_RUNTIME_METRICS`; it measures only the runtime and test double, and cannot establish HID, host input, target-app, CPU, memory, or energy acceptance.

## Five-minute process windows

Use a built, integrated candidate on the same Mac used for the supervised target-app checks. The application must be composed with the production producer and host-action adapter before these windows can represent connected/disconnected runtime behavior. Warm up for at least two minutes, then identify the PID of `DialDeck.app` in Activity Monitor. The sampler reads only that PID's cumulative `ps cputime` and RSS counters; it does not record the process name or PID.

Run separate five-minute windows for the connected and disconnected idle scenarios:

```sh
python3 scripts/measure-runtime-process.py --pid <DialDeck-PID> --scenario idle-connected --candidate-sha <40-character-SHA> --output evidence/idle-connected.csv
python3 scripts/measure-runtime-process.py --pid <DialDeck-PID> --scenario idle-disconnected --candidate-sha <40-character-SHA> --output evidence/idle-disconnected.csv
```

The sampler records 301 observations across 300 seconds using a monotonic clock. CPU time is the delta in the process CPU-time counter divided by elapsed wall time. `100%` means one logical CPU fully occupied; the script reports that percentage and a host-normalized value divided by the logical CPU count. The idle threshold is average CPU below `1%` of one logical CPU. RSS baseline is the first sample, peak is the maximum, and settled memory is the median of the final 30 one-second samples. Record whether the run actually had the keypad connected; the script cannot detect that state.

Run focus and reconnect cycle windows separately while an operator performs 20 cycles of the named type:

```sh
python3 scripts/measure-runtime-process.py --pid <DialDeck-PID> --scenario focus-cycles --cycle-count 20 --candidate-sha <40-character-SHA> --output evidence/focus-cycles.csv
python3 scripts/measure-runtime-process.py --pid <DialDeck-PID> --scenario reconnect-cycles --cycle-count 20 --candidate-sha <40-character-SHA> --output evidence/reconnect-cycles.csv
```

`--cycle-count` is operator-reported; this process sampler does not verify the focus changes or physical reconnects. Save only the aggregate session count, RSS baseline/peak/settled values, and whether growth remained after settling. Do not record foreground window titles, user content, HID reports, or unrelated input.

## Energy observation

When the candidate and target-only environment are ready, run an idle energy sample in each matching connected/disconnected scenario without concurrent compilation or UI automation. The wrapper captures the macOS `cpu_power` sampler at one-second intervals for five minutes and does not enable per-process energy listings:

```sh
sudo scripts/measure-runtime-energy.sh evidence/energy-connected.txt <40-character-SHA>
sudo scripts/measure-runtime-energy.sh evidence/energy-disconnected.txt <40-character-SHA>
```

The result is system-wide estimated subsystem power, not an attribution to DialDeck. Keep the two scenarios, host, power source, and warm-up procedure consistent. If the sampler is unavailable or access is denied, record it as blocked. Do not infer application energy from the process CPU or RSS samples.

## Supervised physical and target-app checks

The fixed live checklist requires actual keypad input and target-app observation. With a supervised session, a no-op runtime fixture may first verify the capture path without synthesizing host input. Then, using the production adapter and a blank or disposable target document, separately observe and record outcome/duration for:

1. Command-C and Command-V.
2. Sustained Control+Option speech in Wispr Flow.
3. The configured clipboard-manager shortcut.
4. Application launch.
5. An Apple Shortcut.
6. Horizontal scrolling.
7. Application-appropriate zoom.
8. Dial mode changes and restoration after restart.

For latency, report runtime receipt-to-dispatch, sequence action/pause durations, and target-app response as distinct measurements. Target-app response begins when the intended action is dispatched and ends at a predefined visible result in the target app. Use only aggregate timings and outcomes; do not retain text, clipboard data, or screenshots containing personal content.

## Current environment limits

`Sources/DialDeckApp/main.swift` currently shows only a placeholder window. The production app does not instantiate `KeyboardHIDInputEventProducer` or `ActionRuntime`, and there is no concrete foreground, mapping, capability, or `HostActionServicing` implementation. No physical capture, user permission change, device write, target-app check, five-minute CPU window, memory-cycle run, or energy sample was performed for this candidate. Those results must remain blocked until the UI composition and production action adapters exist and a supervised keypad session is available.
