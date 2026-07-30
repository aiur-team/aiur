# Stream Deck+ direct-HID spike

Date: 2026-07-30

## Go/no-go

**Provisional go for the direct-HID architecture, but no implementation go yet:** the real Stream Deck+ enumerates and `@elgato-stream-deck/node` 7.6.3 identifies it, while this agent sandbox cannot open the kernel-created `/dev/hidraw10`, so no device I/O, event payload, LCD, suspend, or Phoenix result can be claimed.

This is an environment-access failure, not evidence that the device or library rejected LCD output. The OpenDeck fallback was therefore not triggered: the stop condition was reached before the first LCD write.

## Environment

- OS: Arch Linux
- Kernel: `7.1.4-arch1-1` (`Linux 7.1.4-arch1-1 x86_64`)
- Node: `v24.18.0`
- npm: `11.16.0`
- Library: `@elgato-stream-deck/node@7.6.3`
- Transitive HID library: `node-hid@3.4.0`
- Device: Elgato Stream Deck Plus, VID `0x0fd9`, PID `0x0084`, firmware descriptor `1.30`
- Device serial reported by enumeration: `A00WA6211LG839`

The package and its dependencies installed successfully in a temporary directory using an npm cache outside the repository. No package or lockfile was added to Aiur.

## Step 1 — udev and enumeration: **partial**

USB enumeration works:

```text
Bus 001 Device 009: ID 0fd9:0084 Elgato Systems GmbH Stream Deck Plus
```

The kernel also has the device on `hid-generic` and exposes it in sysfs:

```text
0003:0FD9:0084.000B -> hidraw10
hid-generic ... input,hidraw10: USB HID v1.10 Device [Elgato Stream Deck Plus]
```

`@elgato-stream-deck/node` enumeration succeeds:

```json
[
  {
    "model": "plus",
    "path": "/dev/hidraw10",
    "serialNumber": "A00WA6211LG839"
  }
]
```

Direct `node-hid` enumeration reports the same device, with `usagePage: 12`, `usage: 1`, interface `0`, and product `Stream Deck Plus`.

The user-space open is not possible in this agent workspace. `/sys/class/hidraw/hidraw10` exists and udev reports `DEVNAME=/dev/hidraw10` plus `TAGS=:seat:uaccess:`, but `/dev/hidraw10` and `/dev/bus/usb` are not mounted into the sandbox. The exact open error is:

```text
Error: cannot open device with path /dev/hidraw10: Failed to open a device with a path '/dev/hidraw10': No such file or directory
```

No Elgato-specific udev rule was present under `/etc/udev/rules.d` or `/usr/lib/udev/rules.d`. `sudo` cannot be used in this sandbox (`no new privileges`), so rules could not be installed/reloaded and a physical unplug/replug could not be performed by the agent.

### Rules for the real-device run

These are the exact candidate rules for the requested test, saved here because they could not be installed in the sandbox. The USB rule covers the parent device; the hidraw rule covers the node consumed by Node HID. `plugdev` is the group fallback for headless/service use.

```udev
# /etc/udev/rules.d/50-aiur-streamdeck.rules
SUBSYSTEM=="usb", ATTR{idVendor}=="0fd9", MODE:="0660", GROUP="plugdev", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{idVendor}=="0fd9", MODE:="0660", GROUP="plugdev", TAG+="uaccess"
```

The library's shipped desktop-user rule is product-specific and uses the same access mechanism:

```udev
KERNEL=="hidraw*", ATTRS{idVendor}=="0fd9", ATTRS{idProduct}=="0084", MODE:="660", TAG+="uaccess"
```

Its shipped headless variant changes the final access policy to `GROUP="plugdev"`. The current user is not in `input` or `plugdev`; this is an additional reason to validate the rules in an ordinary host session after installation.

## Step 2 — input/output round trip: **untestable; stopped at first hard failure**

The pinned API exposes the required operations:

- `rotate(control, amount)`
- `down(control)` and `up(control)`
- `lcdShortPress(control, { x, y })`
- `fillLcd(0, buffer, { format: "..." })` for the Plus LCD segment (`800x100`)
- `fillLcdRegion(0, x, y, buffer, { width, height, format: "..." })`

The Plus model definition contains 8 keypad buttons, 4 encoder controls, and one LCD segment. This is library metadata, not a hardware event observation.

The intended test calls were therefore:

1. Attach listeners for `rotate`, `down`, `up`, and `lcdShortPress`, preserving the complete control/payload objects.
2. Send a full `800x100` image with `fillLcd(0, ...)`.
3. Send a contrasting tile with `fillLcdRegion(0, x, y, ...)`.

Neither input payloads nor output acknowledgements were observed because `openStreamDeck()` failed before a handle was created. No conclusion about `fillLcdRegion` fidelity, full-strip repaint fallback, or LCD image acceptance is justified.

## Step 3 — suspend/resume: **untestable**

The test was not run after Step 2 stopped. Suspending the shared host would also be unsafe while the HID handle cannot be opened. No heartbeat, dead-handle detection, close/reopen, brightness reset, or repaint result was observed.

## Step 4 — Phoenix wiring smoke: **untestable**

The test was not run after Step 2 stopped. No PubSub-to-key repaint, dial-to-HTTP call, state change, repaint, or tick-coalescing behavior was observed.

## hidraw feature-report sub-check: **untestable**

`node-hid@3.4.0` includes both Linux prebuilds. The normal Linux load path selects the `HID_hidraw` prebuild, which links against `libudev` and `libusb`; the separate `HID` prebuild is the libusb backend. The kernel version is `7.1.4-arch1-1`.

The hidraw attempt reached enumeration but could not construct a handle, so `getFeatureReport()` was never sent:

```text
TypeError: cannot open device with path /dev/hidraw10: Failed to open a device with path '/dev/hidraw10': No such file or directory
```

The alternate libusb enumeration sees `1-11:1.0`, but opening it fails before a feature report:

```text
TypeError: cannot open device with path 1-11:1.0: hid_error is not implemented yet
```

Therefore this run does not answer whether the current kernel's hidraw backend can send brightness/reset/serial/firmware feature reports. That answer requires a host process with the actual hidraw node mounted and the udev ACL applied.

## Sources and reproducibility

- [Elgato Stream Deck+ HID API](https://docs.elgato.com/streamdeck/hid/stream-deck-plus/): official VID/PID, 2x4 keypad, 4 encoders, touch payloads, output reports, and feature reports.
- [@elgato-stream-deck/node](https://github.com/Julusian/node-elgato-stream-deck): pinned Node HID library and Linux udev guidance.

Commands used included `lsusb -v -d 0fd9:0084`, `udevadm info --query=all --path=/sys/class/hidraw/hidraw10`, `node-hid` enumeration, and a minimal `openStreamDeck()`/`getFeatureReport()` probe. Re-run the same probes outside the sandbox after installing the rules and physically unplugging/replugging the device; only then should Steps 2–4 be treated as pending hardware work rather than results.
