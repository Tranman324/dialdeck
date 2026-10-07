# Runtime recovery and measurement

## Timing boundaries

`RuntimeMeasurementRecorder` stores a bounded set of monotonic durations and normalized event classes. It retains no control IDs, key values, shortcuts, text, clipboard data, or app content.

For each input event, the runtime reports:

- `inputQueueWait`: event receipt until it acquires the serialized input gate.
- `preDispatchRouting`: gate acquisition until the first `HostActionServicing.perform` call, including configuration, focus, and route checks.
- `receiptToDispatch`: the combined interval from receipt to that first service call. The recorder also stores a paired decomposition for the same dispatched event.
- `eventHandling`: gate acquisition through completion of the runtime's event handler, including action execution and configured pauses.
- `serviceCall`: each injected host-action adapter call, from invocation through return.
- `sequenceAction` and `sequencePause`: configured sequence action and pause durations.

`receiptToDispatch` ends when service execution begins. It does not include the service call itself or prove when a target app visibly responds. The repository has no production host-action adapter or completed app composition root, so target-app response remains unmeasured.

## Deterministic offline workload

Run the simulated timing and focus-contract workload with:

```sh
swift test --package-path . --arch arm64 --filter ActionRuntimeTests
```

`testRuntimeMeasurementHarnessSeparatesDispatchServiceAndSequenceTiming` reports p50, p95, and maximum queue wait, pre-dispatch routing, full event handling, and service-call timings for a no-gap backlog and a 40-event, 20 Hz simulated knob spin. The backlog result decomposes its slowest receipt-to-dispatch sample into queue wait and routing time. Output is labeled `SIMULATED_RUNTIME_METRICS`; it measures the runtime and test doubles, not HID callback latency, host input, target-app behavior, CPU, memory, or energy.

## Final supervised hardware session

During the final supervised hardware session, use Activity Monitor for one manual idle check: observe the app for five minutes with the keypad plugged in, then five minutes with it unplugged. The pass criterion is CPU near 0% while idle and memory remaining flat across both periods. Record only the observed result. This manual check replaces the previously planned formal energy samples and scripted five-minute resource windows.

The same final session must separately cover the approved user-visible recovery checks: sleep/wake, missing or revoked permissions, unplug/replug, held keys, and repeated knob rotation. Confirm there are no stuck or duplicate actions. These checks require the production app composition, host-action adapter, and supervised user interaction; simulated tests do not establish physical behavior.

When the production adapter and target-only environment are ready, verify the configured actions with a blank or disposable target document: Command-C and Command-V, sustained Control+Option speech in Wispr Flow, the clipboard-manager shortcut, application launch, an Apple Shortcut, horizontal scrolling, application-appropriate zoom, and dial mode changes with restoration after restart. Keep target-app response time distinct from runtime receipt-to-dispatch and use aggregate outcomes only.

At this candidate, `Sources/DialDeckApp/main.swift` remains a placeholder. The app does not instantiate `KeyboardHIDInputEventProducer` or `ActionRuntime`, and no production foreground, mapping, capability, or host-action service is connected. Physical and target-app checks remain pending; no device writes, permission changes, or hardware measurements were made for the runtime-recovery change.
