import { afterEach, describe, expect, it, vi } from "vitest";
import { createDeckBrightness, resolveAudioDevice } from "../src/deck-settings.js";
const setup = () => {
  const write = vi.fn();
  return { write, brightness: createDeckBrightness({ defaultBrightness: 70, setTimer: setTimeout, clearTimer: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>), write }) };
};
afterEach(() => vi.useRealTimers());
describe("daemon deck settings on the PC", () => {
  it("dims at five idle seconds and restores saved brightness on any input", () => {
    vi.useFakeTimers();
    const { brightness, write } = setup();
    brightness.apply({ brightness: 30, dim_after_seconds: 5 });
    expect(write).toHaveBeenLastCalledWith(30);
    vi.advanceTimersByTime(4999);
    expect(write).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(1);
    expect(write).toHaveBeenLastCalledWith(0);
    brightness.input();
    expect(write).toHaveBeenLastCalledWith(30);
    vi.advanceTimersByTime(4000);
    brightness.input();
    vi.advanceTimersByTime(4000);
    expect(write).toHaveBeenCalledTimes(3);
    vi.advanceTimersByTime(1000);
    expect(write).toHaveBeenLastCalledWith(0);
    brightness.stop();
  });
  it("uses the environment until brightness is saved, clamps and disables idle dim", () => {
    vi.useFakeTimers();
    const { brightness, write } = setup();
    brightness.apply({ brightness: null, dim_after_seconds: 1 });
    expect(write).toHaveBeenLastCalledWith(70);
    brightness.apply({ brightness: 200, dim_after_seconds: 0 });
    vi.advanceTimersByTime(10000);
    expect(write.mock.calls).toEqual([[70], [100]]);
    brightness.apply({ brightness: -5, dim_after_seconds: 0 });
    brightness.opened();
    expect(write.mock.calls.slice(-2)).toEqual([[0], [0]]);
    brightness.stop();
  });
  it("resolves an unplugged saved device to the first while retaining the choice", () => {
    const saved = "unplugged";
    const devices = [{ id: "first", label: "First" }, { id: "second", label: "Second" }];
    expect(resolveAudioDevice(saved, devices)).toBe("first");
    expect(resolveAudioDevice(saved, [...devices, { id: saved, label: "Back" }])).toBe(saved);
    expect(resolveAudioDevice("second", devices)).toBe("second");
    expect(resolveAudioDevice(null, [])).toBeNull();
  });
  it("restores dimmed brightness after a flash without waking the deck", () => {
    vi.useFakeTimers();
    const { brightness, write } = setup();
    brightness.apply({ brightness: 30, dim_after_seconds: 5 });
    vi.advanceTimersByTime(5000);
    brightness.flash();
    expect(write).toHaveBeenLastCalledWith(100);
    vi.advanceTimersByTime(200);
    expect(write).toHaveBeenLastCalledWith(0);
    brightness.flash();
    brightness.input();
    expect(write).toHaveBeenLastCalledWith(30);
    vi.advanceTimersByTime(200);
    expect(write).toHaveBeenLastCalledWith(30);
    brightness.flash();
    brightness.apply({ brightness: 40, dim_after_seconds: 0 });
    vi.advanceTimersByTime(200);
    expect(write).toHaveBeenLastCalledWith(40);
    brightness.stop();
  });

  it("flashes at full brightness and handles input before the flash expires", () => {
    vi.useFakeTimers();
    const { brightness, write } = setup();
    brightness.apply({ brightness: 100, dim_after_seconds: 0 });
    brightness.flash();
    expect(write).toHaveBeenLastCalledWith(0);
    brightness.input();
    expect(write).toHaveBeenLastCalledWith(100);
    brightness.apply({ brightness: 40, dim_after_seconds: 0 });
    brightness.flash();
    vi.advanceTimersByTime(200);
    expect(write).toHaveBeenLastCalledWith(40);
    brightness.stop();
  });

});
