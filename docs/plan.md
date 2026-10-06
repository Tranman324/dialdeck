# Product plan

This is a proposed implementation plan, not a description of shipped functionality.

## Controls and actions

| Control | Planned actions |
| --- | --- |
| Buttons 1–6 | Record a hotkey, open an application, run a named Apple Shortcut, or do nothing |
| Dial counterclockwise and clockwise | Horizontal scrolling by default; vertical scrolling or custom hotkeys as alternatives |
| Dial press | The same actions available to buttons |

Scroll actions should support speed and direction settings. Zoom and tab switching can be expressed through application-specific hotkeys rather than assuming a universal shortcut.

## Interface

- A visual keypad lets the user select the control to configure.
- An action editor records hotkeys and provides application and Shortcut selection.
- A profile list contains a default profile and application-specific overrides.
- A live input indicator helps identify controls and diagnose setup.
- Connection and permission states are visible and explain the next action.
- A menu-bar control pauses remapping and opens settings.

The visual layout and numbering must be checked against the physical unit before they are treated as definitive.

## Profile behavior

Profiles are selected using the frontmost application's bundle identifier. Application overrides inherit the default action for controls they do not replace. An explicit “do nothing” assignment is different from inheritance.

Changing focus should change the profile without rewriting device storage. Saved profiles belong on the local Mac. Launch at login is optional and off by default.

## Implementation outline

Use Swift and SwiftUI for a native application. Keep configuration models, profile selection, input decoding, action execution, and presentation separate so behavior can be tested without a connected keypad.

Match the intended device before opening input interfaces. Determine whether input must be captured exclusively to prevent an original key and its replacement from both reaching an application. Permission failures must produce a visible disabled state, not silent partial operation.

Use macOS APIs for keyboard and scroll events and application launching. Run Apple Shortcuts through a supported mechanism with structured arguments, without interpolating user text into a shell command.

## Milestones and acceptance criteria

### 1. Hardware verification

- Identify all six buttons, clockwise and counterclockwise rotation, and dial press.
- Verify distinct signals, press/release behavior, and duplicate reports.
- Document descriptor information and report variants.
- If signals are indistinguishable, design a one-time device setup step and explain exactly which stored assignments it replaces before use.
- Do not assume that successful USB writes prove the device accepted or saved a configuration.

### 2. Default-profile prototype

- Assign and persist an action for each control.
- Record hotkeys and select applications and Apple Shortcuts.
- Verify horizontal scrolling and reversal in an application that supports it.
- Confirm the primary keyboard and mouse remain unaffected.
- Pause or quit cleanly and release any exclusive device access.

### 3. Application profiles

- Switch profiles based on the frontmost application.
- Test default inheritance and explicit disabled actions.
- Keep the configuration window from causing unexpected actions during editing.
- Add menu-bar controls and optional launch at login.

### 4. Release readiness

- Test unplug/replug, sleep/wake, missing permissions, and revoked permissions.
- Test repeated rotation and held keys without stuck modifiers or duplicate actions.
- Report missing applications and Shortcuts without crashing.
- Document supported macOS versions, supported hardware, installation, and permission setup based on actual tests.
- Establish signing and distribution before describing a build as ready for general installation.

## Open decisions

- First applications to use for profile testing.
- Exact physical key layout and dial orientation.
- Minimum supported macOS version.
- Whether a device programming step is necessary.
- Distribution and code-signing approach.

## Outside the initial scope

Firmware replacement, a Windows port, cloud profile sync, and support claims for untested keypad variants are outside the first release.
