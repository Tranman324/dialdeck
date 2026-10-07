# Development

## Toolchain and target

The native foundation uses Swift Package Manager and the SwiftUI framework shipped with Xcode. The project requires Xcode command line tools with a macOS SDK. The verified development host for this foundation was a `Mac17,3` with Apple M5, 24 GB RAM, and `arm64`, running macOS 26.6.2 (25G83), with Xcode 27.0, Swift 6.4, and the macOS 27.0 SDK. Builds are explicitly requested for `arm64`.

The package deployment target and app bundle minimum system version are macOS 14.0. The current host is macOS 26.6.2, so it is within the declared deployment range. This target is a foundation baseline and can be raised if later product APIs require it.

Two valid local code-signing identities were present during inspection. Names and certificate details are intentionally omitted. The development build does not require or claim public signing or notarization.

## Build and smoke test

From the repository root:

```sh
./scripts/build-app.sh
./scripts/run-core-smoke-tests.sh
```

The first command builds the `arm64` SwiftUI executable from a snapshot of the committed source and assembles a uniquely identified bundle under `.build/candidates/<commit-sha>/<build-id>/DialDeck.app`. It prints the bundle path; use that exact path when opening the app. Builds never replace an earlier bundle, so a running process remains associated with the same build directory. The second command runs the reusable core's contract smoke tests. The package test target compiles fake producers and consumers for the input, capability, programming, and runtime command/status contracts.

UI-facing code submits commands through `RuntimeCommandHandling.submit(_:)`. A `.program(request)` command completes with `.programming(result)`, where `result.requestID` matches the request and `result.outcome` preserves sent-unverified, failed, behavior-verified, or persistence-verified status. Lifecycle and capability commands complete with `.noProgrammingResult`. Create normalized input through `NormalizedInputEvent` factories; key factories reject dial IDs, and the dial-rotation factory rejects key IDs.

## Ownership boundaries

- Runtime owns `Package.swift`, build scripts, core models, shared contracts, and action/runtime modules.
- Device owns transport and decoding modules. Device adapters should translate observed input into the neutral normalized contracts without assuming unverified mappings.
- Interface owns presentation and view modules.
- Shared contract amendments go through the Runtime owner so all consumers can update against one accepted interface.

## Configuration model and storage

`DialDeckCore` exposes validated `PrimitiveAction`, `ConfiguredAction`, `ActionSequence`, `Profile`, `DialMode`, and `Configuration` values. Profiles use UUID-backed `ProfileID` and `DialModeID`; labels and array order do not determine identity. Application profiles match validated bundle identifiers. A missing application assignment or `.inherit` resolves to the default profile, while `.set(.primitive(.doNothing))` is an explicit disabled action. Missing default-profile assignments resolve to Do nothing.

Use `ProfileActionResolver.resolve(bundleIdentifier:target:in:)` for button assignments and `resolveDialModeAction(bundleIdentifier:target:in:)` for the selected profile's dial mode. A profile remembers a mode by ID; if it has no remembered selection, its default mode is selected. Deleting the remembered mode selects the profile default. Deleting the default mode promotes the first remaining mode in current order; a profile cannot delete its last mode.

`ConfigurationStore` is an actor with `load()`, `save(_:)`, `importConfiguration(_:)`, and `exportConfiguration()`. Its JSON envelope carries schema version 1. Imports are limited to 1 MiB and are completely decoded and validated before any state is replaced; malformed input and unsupported schema versions have structured errors. Saves write the previous valid snapshot to a backup before atomically replacing the primary file. The store serializes file transactions and checks cancellation after the backup write, immediately before starting the primary replacement; cancellation observed at that checkpoint leaves the primary snapshot intact. Consumers should await store calls from UI code; synchronous filesystem operations run inside the store actor. File-access implementations must preserve the destination when an atomic write fails.

Host action sequences contain only leaf primitive actions and bounded pauses, so nested or cyclic sequence graphs cannot be represented. Current configuration bounds are 32 steps, 10,000 ms per explicit pause, and 60,000 ms total explicit pause duration in a sequence. The host executor adds a 5 second timeout for each service action and a 180 second elapsed-time deadline for a sequence. Pauses and service actions are capped by the remaining sequence time. Service and mode-advance races use structured task groups; timeout or cancellation cancels the sibling work and joins every child before returning. A mode-advance wait races both its deadline and explicit route/session cancellation. If an already-started synchronous primary replacement succeeds, the runtime updates the selected mode and reports that committed mode change instead of reporting timeout or cancellation. If cancellation or deadline expiry is observed before primary replacement starts, persistence fails without changing the primary snapshot. Since the primary file replacement cannot be interrupted, the action and any cancellation cleanup waiting for it can finish only after the write returns, even if the deadline or cancellation arrived earlier. Sequence-owned inputs are released before it returns. Its default maximum dial magnitude is 100. These runtime bounds are independent of device capacity.

## Action execution and routing

`ActionRuntime` implements the existing `RuntimeCommandHandling`, `RuntimeStatusProviding`, and `NormalizedInputConsumer` contracts. Start, stop, capability refresh, device programming, session lifecycle, and the existing correlated programming outcomes retain their accepted meanings. `currentSnapshot()` adds observable editing state, foreground application and profile identity, selected dial-mode identity, and the latest correlated action result.

`HostActionExecutor` accepts keyboard, held-key, application launch or activation, Apple Shortcut, clipboard-manager shortcut, scroll, zoom, and sequence actions through the injected `HostActionServicing` boundary. Service calls use structured bundle identifiers, shortcut names, chords, scroll parameters, and zoom parameters; no user-controlled value is interpolated into a process command. Service acceptance is reported as `acceptedUnverified`, since this core layer has not observed a target application's behavior. Missing targets, unsupported operations, failures, timeouts, cancellation, and partial sequence completion have distinct typed outcomes.

Key-down records its owner and release state before routing can change. Repeated downs are ignored, key-up releases the original press, and shared synthetic modifiers remain down until the final runtime owner releases them. The executor only releases synthetic events it emitted; physical keyboard modifiers are outside its ownership ledger. Each routed action carries an admission revision: the route-permit revision for key-down and dial actions, and the current runtime revision for key-up. Session stop or failure, permission loss, session replacement, configuration replacement, editing mode, and explicit teardown raise the executor's admission floor before awaiting cleanup; older queued requests are rejected before submission or again after acquiring the action gate. Cleanup cancels current work and releases runtime-owned inputs. The executor checks task cancellation immediately before entering `HostActionServicing.perform`. A service adapter must cooperate with task cancellation and finish any in-progress call before cleanup can return. A non-cooperative adapter can delay timeout or cancellation cleanup until that call returns; the structured race waits for it rather than letting it outlive the caller. Tests use synthetic inputs and service doubles only, so they do not prove real operating-system effects.

The foreground application source returns a validated bundle identifier. The injected control mapper translates adapter-provided key identities to the six assignment targets; neither interface asserts a physical keypad layout. Button assignments use `ProfileActionResolver`, including app overrides and default inheritance. Dial rotations use the selected mode for that routed profile. A validated dial-press adapter can call `ActionRuntime.dialPressed`; the accepted normalized event contract currently carries key down/up and dial rotation, but no dial-button press payload. Dial press runs the selected mode's configured press action: `nextDialMode` advances and persists the next ordered mode, while supported one-shot actions use the injected executor. `Do Nothing` emits no action, and held-key actions are unsupported as one-shot presses. The existing store rules supply a valid mode fallback when a mode is deleted. Routing rechecks session, editing state, and configuration revision after provider awaits; install and reload invalidate older permits, cancel admitted executor work, and release runtime-owned inputs before replacing the active snapshot.

Normal assigned actions are suppressed while configuration editing is active. This task exposes no ad hoc action-test command that could turn an ordinary selection into a live OS action. `HostActionServicing`, the foreground source, control mapping, input producer, capabilities, and device programmer all require injected adapters in an app composition layer. The deterministic fixtures in `ActionRuntimeTests` record synthetic input intents and simulated service outcomes only; they do not establish physical keypad mappings, OS permissions, app availability, or real target-application behavior.

The recovered Windows encoder serializes only five keyboard steps and provides no macro delays. That observed encoder format is separate from host-run sequences and does not prove a firmware maximum. Configuration resolution and storage alone do not synthesize input, execute actions, or write hardware.

## Local signing

Local signing identity availability was observed on the verified host as noted above. No signing credentials are stored in this repository. Public Developer ID signing and notarization are not configured or verified by this foundation.
