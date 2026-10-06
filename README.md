# DialDeck

A macOS companion for programmable keypads, with custom hotkeys, app shortcuts, and per-app dial controls.

**Status: planning.** This repository contains the product plan and initial hardware findings. There is no runnable app or release yet.

## The idea

Turn a six-button keypad and rotary dial into controls that adapt to the application you are using.

- Assign keyboard shortcuts, application launches, or Apple Shortcuts to buttons.
- Scroll horizontally with the dial, with adjustable speed and direction.
- Customize clockwise, counterclockwise, and dial-press actions.
- Switch profiles automatically when the active application changes.
- Inherit default actions when an application has no override.

The proposed interface shows the keypad visually: select a control, choose an action, and test it. A menu-bar companion performs actions while DialDeck is running.

## Initial hardware target

The first target is a Sinloon six-button keypad with one rotary dial. A connected unit was detected on macOS with USB vendor ID `0x1189` and product ID `0x8890`.

Detection is confirmed; remapping, dial behavior, and configuration writes are **not yet validated**. Similar-looking devices and devices sharing these USB IDs may use different firmware.

See [hardware findings](docs/hardware.md) for the current evidence and open questions.

## Planned Mac integration

The proposed implementation is a native Swift/SwiftUI application using macOS HID APIs to receive keypad input and system event APIs to perform supported actions. Input Monitoring and Accessibility permissions are expected to be required.

Per-application behavior will run on the Mac. The companion must remain running for those actions to work. Horizontal scrolling and application-specific shortcuts depend on support in the receiving application.

## Roadmap

1. Identify every physical input and verify whether each emits a distinct signal.
2. Build the assignment interface and default profile, including horizontal scrolling.
3. Add per-application profiles, persistence, menu-bar controls, and optional launch at login.
4. Validate reconnects, permissions, duplicate-event handling, and behavior in real applications.

Read the [product plan](docs/plan.md) for scope and acceptance criteria.

## Contributing

Discussion and hardware observations are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes. Do not upload vendor executables, decompiled source, personal configurations, or logs containing private information.

## License

Original project material is available under the [MIT License](LICENSE). DialDeck is an independent project and is not affiliated with or endorsed by Sinloon.
