# Hardware evidence and programming limits

## Observed unit

The user identified an upright keypad with a single knob above two columns of three keys. The connected USB unit had VID `0x1189`, PID `0x8890`, one configuration, and four interfaces. The configuration interface was interface 1: HID class/subclass/protocol `3/0/0`, one interrupt OUT endpoint `0x02` with a 64-byte max packet, and a 36-byte vendor-page HID descriptor. The descriptor defines Report ID 3 with 64 data bytes in each input and output report. Location ID is connection evidence, not a durable device identity; discovery does not pin a dock or port.

A target-only capture in the original configuration found the same input pattern for all six keys and three knob actions. Separate, explicitly approved writes assigned distinct plain letters to layer-1 protocol slots 1–6 and 13–15; the USB host accepted every report. The user reported that the six-key sequence `bfaexd` remained after one reconnect following the key-slot writes. After the separate knob-slot writes and a separate reconnect, the user reported the same knob sequence `j`, `g`, `h`. A later target-only capture recorded a distinct USB keyboard usage with press and release for each of the nine gestures:

| Upright physical control | Layer-1 slot | Plain key | USB keyboard usage |
| --- | ---: | --- | ---: |
| Top-left key | 3 | `b` | `0x05` |
| Top-right key | 6 | `f` | `0x09` |
| Middle-left key | 2 | `a` | `0x04` |
| Middle-right key | 5 | `e` | `0x08` |
| Bottom-left key | 1 | `x` | `0x1b` |
| Bottom-right key | 4 | `d` | `0x07` |
| Knob clockwise, one click | 15 | `j` | `0x0d` |
| Knob counterclockwise, one click | 13 | `g` | `0x0a` |
| Knob press | 14 | `h` | `0x0b` |

This establishes the listed mappings and down/up transitions for that capture, not hold or burst behavior. Other layers and behavior across docks remain unverified. The separate lighting observations below cover only layer-1 modes 1 and 2.

## Software boundary

`ReportID3KeyboardEncoder` constructs source-derived Report ID 3 keyboard sequences of 1–5 USB HID keyboard usages. Those bytes are not macOS virtual key codes. Its broader vectors have not been physically verified. The callable USB transport accepts **only the nine exact slot/layer-1/plain-usage combinations in the table**, one at a time, plus fixed LED mode-1 and mode-2 sequences. The [manufacturer guide](https://sikaicase.com/blogs/news/before-software-setting) describes LED mode 2 as a color gradient. After the fixed mode-2 transfer was accepted, the User observed the keypad cycling green, purple, blue, yellow, red, and teal. Each color lights one key at a time: bottom-left, middle-left, top-left, bottom-right, middle-right, top-right. Pressing keys did not alter the sequence. The User observed the same sequence after one unplug/reconnect.

`ObservedDeviceProgrammingCapabilities.observedUnit` is a read-only catalog for downstream code. It records exactly those nine upright-control/layer-1/slot/plain-usage vectors and lighting modes 1 and 2. It is evidence about this tested unit, not a live detection result or permission to issue a write. It has no entry for other layers, usages, modes, macros, or action families.

After the separately approved mode-1 transfer, the User observed slow blinking colors during press and release events on the left-column keys. Reported press/release pairs cycled teal/green, purple/blue, and yellow/red. Bottom-left blinked red at idle before the first press; middle-left and top-left were unlit at idle. After one unplug/reconnect, all LEDs were initially off; following two quick bottom-right presses, purple became steady at idle. A later held bottom-right press changed purple to blue, and release changed it to yellow. This establishes User-observed press/release lighting after one reconnect, without establishing exact timing, which other keys light, or a universal color order. The transport labels each transfer `sentUnverified`; software cannot itself verify the visible effect. Media, mouse, LED mode 0, other slots, other layers, other usages, and macros remain unavailable through the transport. There is no configuration readback or verified restoration method.

Static inspection of the user-supplied Windows app shows that its LED download flow sends a layer-select report before the mode report and the LED-specific save report. Each bounded lighting vector sends exactly three 65-byte Report ID 3 reports on layer 1: `[03 a1 01]`, `[03 b0 18 01]` for mode 1 or `[03 b0 18 02]` for mode 2, and `[03 aa a1]`, with every remaining byte zero. The corresponding physical observations are above.

`KeyboardDeviceProgrammingService` requires an explicit slot and `acceptsPersistentOverwrite` request field for keyboard assignments. Lighting requests also require that explicit flag and can emit only a fixed layer-select/mode/save sequence for mode 1 or 2. Earlier user approvals covered only the completed experiments; they do **not** authorize later invocations. Any app integration must obtain a fresh, specific user decision before invoking another persistent write. An accepted report sequence returns `sentUnverified`; it never asserts behavior or retention. A rejected/short report stops the sequence before later reports or flash save. A failed or interrupted save leaves persistence unknown. The async caller waits for the synchronous C operation and teardown before receiving a result, even after cancellation. Waiting for the process-wide operation lock and each next report is cancellation-aware. A cancellation signal between the pre-write check and `interrupt_transfer` may still allow that transfer to begin; a completed save is reported as sent if cancellation arrives during that last transfer.

The C transport holds one process-wide lock from discovery through release, so separate service instances cannot interleave report sequences. It rejects a report-buffer length mismatch before reading the buffer, re-enumerates for exactly one matching VID/PID unit, validates its four-interface topology, opens that same device, claims interface 1, and checks the full Report ID 3 descriptor again on the open handle before output. All reports go only to endpoint `0x02`. It never switches to an unobserved fallback route. Same-ID, same-topology replacement hardware without serial identity remains indistinguishable.

The C bridge loads `libusb-1.0.dylib` at runtime from `/opt/homebrew/lib` or `/usr/local/lib`. If neither exists, programming returns unavailable. The app does not bundle libusb; standalone distribution remains incomplete until the dependency and its license/packaging are addressed. Separately approved lighting writes are recorded in `.apm/evidence/hardware/led-mode2-write-2026-10-06.md` and `.apm/evidence/hardware/led-mode1-write-2026-10-06.md`.

## Evidence and references

The local sanitized evidence in the main checkout is `.apm/evidence/hardware/config-interface-2026-10-06.md`, `one-slot-write-2026-10-06.md`, `slots-2-6-write-2026-10-06.md`, `knob-slots-13-15-write-2026-10-06.md`, and `capture-2026-10-06-programmed-map.md`. Packet structure was informed by the [six-key protocol account](https://github.com/jgt87/Macropad/blob/main/custom/PROTOCOL.md) and a matching public V02.1.1 application release. External material is evidence, not a firmware specification or bundled dependency. The user-supplied executable, recovered source, and raw diagnostics are not included in this repository.
