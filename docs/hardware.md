# Initial hardware findings

## Confirmed

A user-identified Sinloon six-button keypad was detected by macOS with:

| Property | Observed value |
| --- | --- |
| USB vendor ID | `0x1189` |
| USB product ID | `0x8890` |
| Visible HID collections | Two keyboard devices and one mouse device |
| Keyboard usage | Usage page 1, usage 6 |
| Mouse usage | Usage page 1, usage 2 |
| Product name | Not reported in the inspected device listing |

Read-only inspection used `ioreg`, `hidutil list`, and HID descriptor enumeration. No device settings were changed.

These observations establish that macOS recognizes input interfaces; they do not establish full compatibility with a programming protocol.

## Protocol investigation

Local analysis of the user-supplied Windows configuration application identified the same USB IDs and logic for keyboard, media, mouse, layer, and LED assignments. The application includes multiple report-ID paths, so firmware-specific details still require validation.

The vendor application labels controls 1–6 as the first six buttons and controls 13, 14, and 15 as the first dial's left, press, and right actions. These are software labels, not yet verified physical mappings for the connected unit.

Vendor binaries, decompiled code, debug symbols, and extracted resources are intentionally not distributed in this repository. Any future implementation should contain original project code and clearly attributed, appropriately licensed dependencies.

## Remaining validation

- Capture deliberate input from each physical control.
- Determine whether default assignments are distinguishable.
- Confirm report sizes, report IDs, and interface access behavior on this unit.
- Verify whether exclusive capture prevents duplicate system actions.
- If programming is required, validate a bounded change and persistence after reconnection.

A device reporting the same USB IDs may have a different layout or firmware. USB IDs alone are insufficient to authorize configuration writes to arbitrary devices.

## References

These projects provide independent observations, not a compatibility guarantee or bundled dependencies:

- [MINI-KeyBoard](https://github.com/philiporange/MINI-KeyBoard): describes macOS support for a related 12-key, two-dial variant.
- [Macropad](https://github.com/jgt87/Macropad): describes a six-key, one-dial controller and configuration protocol.

Relevant Apple APIs:

- [IOHIDDeviceOpen](https://developer.apple.com/documentation/iokit/1588670-iohiddeviceopen): device access and exclusive capture.
- [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent): keyboard and scroll event creation.
