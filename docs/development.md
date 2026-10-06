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
open -g -n .build/DialDeck.app
```

The first command builds the `arm64` SwiftUI executable and assembles `.build/DialDeck.app`. The second runs the reusable core's contract smoke tests. The last command launches the app without asking macOS to bring it to the foreground. The package test target compiles fake producers and consumers for the input, capability, programming, and runtime command/status contracts.

UI-facing code submits commands through `RuntimeCommandHandling.submit(_:)`. A `.program(request)` command completes with `.programming(result)`, where `result.requestID` matches the request and `result.outcome` preserves sent-unverified, failed, behavior-verified, or persistence-verified status. Lifecycle and capability commands complete with `.noProgrammingResult`. Create normalized input through `NormalizedInputEvent` factories; key factories reject dial IDs, and the dial-rotation factory rejects key IDs.

## Ownership boundaries

- Runtime owns `Package.swift`, build scripts, core models, shared contracts, and action/runtime modules.
- Device owns transport and decoding modules. Device adapters should translate observed input into the neutral normalized contracts without assuming unverified mappings.
- Interface owns presentation and view modules.
- Shared contract amendments go through the Runtime owner so all consumers can update against one accepted interface.

## Configuration model and storage

`DialDeckCore` exposes validated `PrimitiveAction`, `ConfiguredAction`, `ActionSequence`, `Profile`, `DialMode`, and `Configuration` values. Profiles use UUID-backed `ProfileID` and `DialModeID`; labels and array order do not determine identity. Application profiles match validated bundle identifiers. A missing application assignment or `.inherit` resolves to the default profile, while `.set(.primitive(.doNothing))` is an explicit disabled action. Missing default-profile assignments resolve to Do nothing.

Use `ProfileActionResolver.resolve(bundleIdentifier:target:in:)` for button assignments and `resolveDialModeAction(bundleIdentifier:target:in:)` for the selected profile's dial mode. A profile remembers a mode by ID; if it has no remembered selection, its default mode is selected. Deleting the remembered mode selects the profile default. Deleting the default mode promotes the first remaining mode in current order; a profile cannot delete its last mode.

`ConfigurationStore` is an actor with `load()`, `save(_:)`, `importConfiguration(_:)`, and `exportConfiguration()`. Its JSON envelope carries schema version 1. Imports are limited to 1 MiB and are completely decoded and validated before any state is replaced; malformed input and unsupported schema versions have structured errors. Saves write the previous valid snapshot to a backup before atomically replacing the primary file. The store serializes file transactions and checks cancellation before replacement, so cancellation before commit leaves the primary snapshot intact. Consumers should await store calls from UI code; synchronous filesystem operations run inside the store actor. File-access implementations must preserve the destination when an atomic write fails.

Host action sequences contain only leaf primitive actions and bounded pauses, so nested or cyclic sequence graphs cannot be represented. Current app-side safety bounds are 32 steps, 10,000 ms per explicit pause, and 60,000 ms total explicit pause duration in a sequence. These bounds describe host configuration only; they do not establish action-execution timeouts or device capacity. The recovered Windows encoder serializes only five keyboard steps and provides no macro delays. That observed encoder format is separate from host-run sequences and does not prove a firmware maximum. Configuration resolution and storage do not synthesize system input, execute actions, or write hardware.

## Local signing

Local signing identity availability was observed on the verified host as noted above. No signing credentials are stored in this repository. Public Developer ID signing and notarization are not configured or verified by this foundation.
