/**
 * Issues a USB port reset to the Stream Deck +.
 *
 * Diagnostic/recovery only. Repeated claim/release cycles — a crash loop, or a
 * sidecar restarted faster than the kernel reattaches hidraw — can leave the
 * deck answering opens while failing every OUT transfer with
 * `LIBUSB_ERROR_IO` / `LIBUSB_TRANSFER_NO_DEVICE`. A port reset clears that
 * without physically unplugging the device.
 *
 * Stop the sidecar first:
 *   systemctl --user stop aiur-streamdeck.service
 *   node scripts/reset-device.mjs
 */
import { findByIds } from "usb";

const device = findByIds(0x0fd9, 0x0084);
if (device === undefined) {
  console.error("no Stream Deck + found (VID 0x0fd9 / PID 0x0084)");
  process.exit(1);
}

device.open();
await new Promise((resolve, reject) => {
  device.reset((error) => (error ? reject(error) : resolve()));
});
console.log("device reset OK");
device.close();
process.exit(0);
