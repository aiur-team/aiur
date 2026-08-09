# Aiur Stream Deck sidecar

This package ships the deployment artifacts and operator runbook for the
direct-HID Node sidecar for an Elgato Stream Deck on Arch Linux. The sidecar
owns the device and connects to the Aiur Phoenix surface. It is deliberately
an always-running, hotplug-aware user service: the process stays alive when
the deck is unplugged or absent and #1354 reopens it when udev reports a new
device.

Download the Linux x64 Stream Deck archive from its commit-addressed release
asset, extract it, and copy the extracted directory to
`~/.local/share/aiur/streamdeck`. The archive contains the Node runtime,
compiled sidecar, and production dependencies, so installation does not need
Node, npm, or a native build toolchain. `BUILD-INFO.json` records the exact
Aiur commit, version, target, and reproducible-build timestamp; compare its
`commit` field to the daemon revision when diagnosing a mismatch.

`STREAMDECK_BRIGHTNESS` (0–100, default 80) sets the brightness the
sidecar reapplies on open and on resume.

## Prerequisites

- Arch Linux with systemd, logind, and a graphical user session.
- An Elgato Stream Deck connected over USB.
- The Phoenix URL and credentials for the Aiur dashboard.
- Membership in the `users` group for the headless-service fallback ACL:
  `sudo usermod -aG users "$USER"`, followed by a new login if needed.

The sidecar uses the official Stream Deck HID protocol. It must be the only
process opening the deck; hidraw does not provide kernel-level exclusive
access, so the sidecar takes its own advisory lock and refuses to start when
another instance holds it.

### Transport backend: libusb

The sidecar talks to the deck over **libusb** (the `usb` package, which ships
N-API prebuilt binaries — no native toolchain needed at install time). libusb
is required because brightness, reset / "Show Logo", serial, and firmware are
USB HID **feature reports**, and the `node:fs`/hidraw path cannot issue the
`HIDIOCSFEATURE`/`HIDIOCGFEATURE` ioctls those need. Over libusb they are plain
class control transfers, so all four work. OUTPUT reports (images, the
key-stream reset) and INPUT reports (dials/touch) go over the interrupt
endpoints.

Because libusb **claims the interface and detaches the kernel hidraw driver**,
the sidecar is the single owner of the device — do not also open the hidraw
node. Access is granted by the `uaccess` tag on the **usb**-subsystem device
(see the udev rules below), not by the hidraw node's ACL.

## udev permissions

Install the shipped rules as root. In an installed archive the rule is at
`~/.local/share/aiur/streamdeck/share/udev/70-streamdeck.rules`:

```sh
sudo install -Dm644 ~/.local/share/aiur/streamdeck/share/udev/70-streamdeck.rules \
  /etc/udev/rules.d/70-streamdeck.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Physically unplug and replug the Stream Deck after triggering the rules.
This matters: logind ACLs from `TAG+="uaccess"` are reliably applied on a
real USB add event, not merely by reloading rules.

Verify the matching hidraw node and its ACL:

```sh
udevadm info --query=property --name=/dev/hidrawN | grep -E 'ID_VENDOR_ID=0fd9|TAGS='
getfacl /dev/hidrawN
```

The output should include `user:<your-login>:rw-`. Replace `hidrawN` with the
node shown by `ls /dev/hidraw*` or `udevadm monitor --udev --property`.

Both rules in `70-streamdeck.rules` are intentional. The `usb` rule covers
the parent device; the `hidraw` rule uses `ATTRS{idVendor}` to walk to that
parent. Arch does not have Debian's `plugdev` group. `uaccess` grants the
active-seat user, while `GROUP="users", MODE="0660"` is the fallback for a
lingering/headless user service. Do not replace this with `MODE:="0666"`.
The `70-` prefix runs before systemd's late seat rule, so the tag is applied
in time.

## Install and enable the user unit

Install the downloaded sidecar and unit, then create the private configuration
file. The credentials belong in the environment file, never in the unit:

```sh
install -d -m755 ~/.local/share/aiur
install -d -m755 ~/.local/share/aiur/streamdeck
tar -xzf aiur-streamdeck-<version>-linux-x64-<sha256>.tar.gz \
  -C ~/.local/share/aiur/streamdeck --strip-components=1
install -Dm644 ~/.local/share/aiur/streamdeck/share/systemd/aiur-streamdeck.service \
  ~/.config/systemd/user/aiur-streamdeck.service
install -dm700 ~/.config/aiur
# Create the file only if it does not exist; preserve credentials on reruns.
touch ~/.config/aiur/streamdeck.env
chmod 600 ~/.config/aiur/streamdeck.env
${EDITOR:-vi} ~/.config/aiur/streamdeck.env
systemctl --user daemon-reload
systemctl --user enable --now aiur-streamdeck.service
```

Install the included udev rule before starting the service:

```sh
sudo install -Dm644 ~/.local/share/aiur/streamdeck/share/udev/70-streamdeck.rules \
  /etc/udev/rules.d/70-streamdeck.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

The archive launch command is `~/.local/share/aiur/streamdeck/bin/aiur-streamdeck`.
With no attached deck it logs `no Stream Deck + detected; waiting for hotplug`
and stays alive for the next udev add event.

Set the environment file to mode `600` and use values appropriate for the
local sidecar build:

```dotenv
AIUR_PHOENIX_URL=http://127.0.0.1:4000
AIUR_DASHBOARD_USERNAME=operator
AIUR_DASHBOARD_PASSWORD=replace-with-a-secret
STREAMDECK_BRIGHTNESS=80
```

Use `http://` only for a Phoenix endpoint on the same machine (such as the
loopback example above). A non-loopback endpoint must use `https://`; never
send the dashboard credentials over plaintext HTTP.

`AIUR_DASHBOARD_USERNAME` and `AIUR_DASHBOARD_PASSWORD` are the same HTTP
Basic Auth credentials used by the Phoenix dashboard. Keep them in this
EnvironmentFile; do not put them in the unit or commit a populated copy.
The key pipeline exports `resolveJpegQuality()` for the eventual canvas/JPEG
encoder. Its default is 90, with an accepted range of 1–100; the encoder must
pass an explicit value when that composition layer lands. There is not yet an
`AIUR_STREAMDECK_JPEG_QUALITY` sidecar environment setting, so do not document
or rely on one. The write queue coalesces pending key content and serializes
writes; changing JPEG quality does not make concurrent device owners safe.

For a user service to start before an interactive login after reboot, enable
user lingering once:

```sh
loginctl enable-linger "$USER"
```

Otherwise `enable --now` starts it immediately and `default.target` starts it
when that user logs in. Check the effective state with:

```sh
systemctl --user status aiur-streamdeck.service
journalctl --user -u aiur-streamdeck.service -f
```

The service is not a system unit. The deck belongs to the seated operator and
`uaccess` is seat-scoped. #1354 owns `PrepareForSleep`: it closes before
suspend, reopens after resume, reapplies brightness, and repaints. This unit
only keeps the process alive; it must not add a competing sleep hook or force
a restart on every resume.

## Optional start-on-plug activation

Always-running plus hotplug awareness is the recommended setup. If a host
needs start-on-plug, udev can request a user unit with a rule containing
`TAG+="systemd"` and `ENV{SYSTEMD_USER_WANTS}="aiur-streamdeck.service"`.
That approach requires the `systemd` tag and the `systemd.device(5)` user
activation plumbing. User-service device activation has long-standing
flakiness reports (systemd#7109), especially around seats and lingering.
Treat it as an opt-in experiment, not a replacement for the unit above.

## Troubleshooting

| Failure mode | Symptoms | Fix |
| --- | --- | --- |
| Permissions / udev | `EACCES`, no deck in the sidecar log, or `getfacl` lacks the logged-in user | Confirm both rules are installed, run `udevadm control --reload-rules && udevadm trigger`, physically replug, then check `getfacl`. Confirm the user is in `users`; do not use `plugdev` or `0666`. |
| Suspend zombie | The service remains active after resume, but keys and LCD stop updating; `connected()` still says true | Do not restart blindly. Inspect `journalctl --user -u aiur-streamdeck`; #1354 should detect the failed write heartbeat, close/reopen, reapply brightness, and repaint. Verify no second sleep hook is fighting it. |
| Device wedge | Writes fail after an interrupted image transfer and the deck stays on its last frame until replug | Stop other writers, then let the sidecar perform its key-stream reset and device reset. If it cannot recover, physically replug. Do not run two sidecars against one hidraw node. |
| Second-process lock conflict | Startup refuses with an advisory-lock/ownership error, or frames are corrupted when another tool is open | Stop OpenDeck, streamdeck-ui, test scripts, and old sidecar processes. Find the owner with `fuser /dev/hidrawN` and start exactly one Aiur sidecar. |

If the deck is absent at boot, an active service is expected: #1354 waits for
the matching udev hotplug event instead of exiting. A repeated `activating`
state with restart messages means the sidecar is not honoring that contract;
inspect its journal and report it against #1354 rather than increasing
`RestartSec` or adding a polling loop.

## Device activation and recovery checklist

After a fresh install, verify in this order:

1. Install the rules, reload/trigger udev, physically replug, and confirm the
   ACL with `getfacl`.
2. Start with the deck unplugged. Confirm the user service remains `active`
   without a restart loop.
3. Plug the deck in and confirm #1354 opens it and paints the initial view.
4. Suspend and resume; confirm the same service recovers without a manual
   restart.
5. Unplug and replug; confirm hotplug reopens and repaints.
6. Reboot, then check `systemctl --user status` and the sidecar journal.

These last hardware steps need the direct-HID sidecar from #1354 and a real
Stream Deck. Logs alone prove that events fired, not that the operator saw a
recovered device.
