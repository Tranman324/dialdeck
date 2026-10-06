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

## Ownership boundaries

- Runtime owns `Package.swift`, build scripts, core models, shared contracts, and action/runtime modules.
- Device owns transport and decoding modules. Device adapters should translate observed input into the neutral normalized contracts without assuming unverified mappings.
- Interface owns presentation and view modules.
- Shared contract amendments go through the Runtime owner so all consumers can update against one accepted interface.

## Local signing

Local signing identity availability was observed on the verified host as noted above. No signing credentials are stored in this repository. Public Developer ID signing and notarization are not configured or verified by this foundation.
