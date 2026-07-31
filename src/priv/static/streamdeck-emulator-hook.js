// Stream Deck emulator interaction hook.
//
// Authority model: local-first. Dial values, mode, and paging offsets are
// owned by this hook and survive LiveView patches via beforeUpdate/updated.
// The server is not consulted for individual dial increments — a round trip
// per degree would be unusable. Server data remains authoritative for fleet
// state; the hook pushes coarse events (press, key-click) when needed.
//
// Patch-survival pattern follows #1306: state is captured in beforeUpdate and
// restored in updated, so LiveView re-renders cannot revert local interaction.
// Key/mic event bindings are torn down in beforeUpdate and rebuilt in updated
// to avoid duplicate-listener accumulation across patches.
//
// Mode machine (local-first, no server round-trip):
//   grid → (key click) → cmd → (cycle-window) → logs
//   any → (back) → previous mode in history stack
(function () {
  "use strict";

  var PRESS_THRESHOLD_DEG = 8;
  var PRESS_FLASH_MS = 160;
  var WHEEL_STEP = 4;
  var KEY_STEP = 4;
  // 270-degree physical sweep maps to full [0..100] range.
  var DRAG_DIVISOR = 2.7;

  // Mode cycle order. cycle-window advances forward; back retreats via history.
  var MODES = ["grid", "cmd", "logs"];

  // Index → server-side press action. Dials 1 and 2 have no press action.
  var PRESS_ACTIONS = { 0: "back", 3: "cycle-window" };

  function angleDeg(cx, cy, x, y) {
    return (Math.atan2(y - cy, x - cx) * 180) / Math.PI;
  }

  function normaliseWrap(delta) {
    // Prevent a wild jump as the pointer crosses the ±180 boundary.
    if (delta > 180) return delta - 360;
    if (delta < -180) return delta + 360;
    return delta;
  }

  function clamp(v, min, max) {
    return Math.min(max, Math.max(min, v));
  }

  // One knob interaction controller, bound to a single .sd-knob-wrap element.
  function Knob(wrap, index, hook) {
    this.wrap = wrap;
    this.knobEl = wrap.querySelector(".sd-knob");
    this.index = index;
    this.hook = hook;
    this.value = parseInt(this.knobEl.dataset.value || "0", 10);
    this.isDragging = false;
    this.dragAngle = 0;
    this.accumulatedDeg = 0;
    this._activePid = null;
    this._pressTimer = null;

    this._onPointerDown = this._onPointerDown.bind(this);
    this._onPointerMove = this._onPointerMove.bind(this);
    this._onPointerUp = this._onPointerUp.bind(this);
    this._onPointerCancel = this._onPointerCancel.bind(this);
    this._onWheel = this._onWheel.bind(this);
    this._onKeydown = this._onKeydown.bind(this);

    this.knobEl.addEventListener("pointerdown", this._onPointerDown);
    // Non-passive wheel listener so we can call preventDefault and stop page scroll.
    this.knobEl.addEventListener("wheel", this._onWheel, { passive: false });
    this.knobEl.addEventListener("keydown", this._onKeydown);
  }

  Knob.prototype._centre = function () {
    var r = this.knobEl.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  };

  Knob.prototype._onPointerDown = function (e) {
    e.preventDefault();
    this.knobEl.setPointerCapture(e.pointerId);
    this._activePid = e.pointerId;
    var c = this._centre();
    this.dragAngle = angleDeg(c.x, c.y, e.clientX, e.clientY);
    this.accumulatedDeg = 0;
    this.isDragging = true;

    this.knobEl.addEventListener("pointermove", this._onPointerMove);
    this.knobEl.addEventListener("pointerup", this._onPointerUp);
    this.knobEl.addEventListener("pointercancel", this._onPointerCancel);
  };

  Knob.prototype._onPointerMove = function (e) {
    if (!this.isDragging) return;
    var c = this._centre();
    var newAngle = angleDeg(c.x, c.y, e.clientX, e.clientY);
    var delta = normaliseWrap(newAngle - this.dragAngle);
    this.dragAngle = newAngle;
    this.accumulatedDeg += Math.abs(delta);
    this._step(delta / DRAG_DIVISOR);
  };

  Knob.prototype._onPointerUp = function (e) {
    if (!this.isDragging) return;
    this._endDrag();
    if (this.accumulatedDeg < PRESS_THRESHOLD_DEG) {
      this._press();
    }
  };

  // A cancelled gesture is never a press — only reset drag state.
  Knob.prototype._onPointerCancel = function () {
    if (!this.isDragging) return;
    this._endDrag();
  };

  Knob.prototype._endDrag = function () {
    this.isDragging = false;
    this._activePid = null;
    this.knobEl.removeEventListener("pointermove", this._onPointerMove);
    this.knobEl.removeEventListener("pointerup", this._onPointerUp);
    this.knobEl.removeEventListener("pointercancel", this._onPointerCancel);
  };

  Knob.prototype._onWheel = function (e) {
    e.preventDefault();
    var direction = e.deltaY > 0 ? -1 : 1;
    this._step(direction * WHEEL_STEP);
  };

  Knob.prototype._onKeydown = function (e) {
    if (e.key === "ArrowUp" || e.key === "ArrowRight") {
      e.preventDefault();
      this._step(KEY_STEP);
    } else if (e.key === "ArrowDown" || e.key === "ArrowLeft") {
      e.preventDefault();
      this._step(-KEY_STEP);
    }
  };

  Knob.prototype._step = function (delta) {
    this.value = clamp(Math.round(this.value + delta), 0, 100);
    this._render();
    // Angle: 0 → -135deg (min), 100 → +135deg (max), centred at top.
    var angle = (this.value / 100) * 270 - 135;
    this.knobEl.style.setProperty("--a", angle + "deg");
    this.knobEl.setAttribute("aria-valuenow", String(this.value));
  };

  Knob.prototype._render = function () {
    var inner = this.knobEl.querySelector(".sd-knob-inner");
    if (inner) inner.textContent = String(this.value).padStart(2, "0");
  };

  Knob.prototype._press = function () {
    var action = PRESS_ACTIONS[this.index];
    // Dials without a press action do not flash or emit an event.
    if (!action) return;

    var el = this.knobEl;
    // Cancel any in-flight press timer before starting a new one so rapid
    // presses don't race: the previous setTimeout would remove the class the
    // new press just added.
    clearTimeout(this._pressTimer);
    el.classList.remove("press");
    // Force reflow so the class removal takes effect before re-adding.
    void el.offsetWidth;
    el.classList.add("press");
    this._pressTimer = setTimeout(function () { el.classList.remove("press"); }, PRESS_FLASH_MS);

    // Handle local mode transition before pushing to server.
    this.hook._handleLocalDialPress(action);
    this.hook.pushEvent("dial-press", { index: this.index, action: action });
  };

  Knob.prototype.destroy = function () {
    // Cancel any outstanding press animation timer.
    clearTimeout(this._pressTimer);
    this._pressTimer = null;

    // Release pointer capture and clean up dynamic drag listeners in case
    // destroy() is called while a drag is in progress (e.g., mid-patch).
    if (this.isDragging && this._activePid != null) {
      try { this.knobEl.releasePointerCapture(this._activePid); } catch (_) {}
    }
    this._endDrag();

    this.knobEl.removeEventListener("pointerdown", this._onPointerDown);
    this.knobEl.removeEventListener("wheel", this._onWheel);
    this.knobEl.removeEventListener("keydown", this._onKeydown);
  };

  Knob.prototype.snapshotState = function () {
    return { value: this.value };
  };

  Knob.prototype.restoreState = function (state) {
    if (!state) return;
    this.value = state.value;
    this._step(0);
  };

  window.AiurStreamdeckEmulatorHook = {
    mounted() {
      this._knobs = [];
      this._micActive = false;
      this._knobState = null;
      this._keyHandlers = [];
      this._micSegment = null;
      this._onMicDown = null;
      this._onMicUp = null;
      this._mode = "grid";
      this._modeHistory = [];
      // Version counter guards against a patch's beforeUpdate/updated window
      // overwriting a mode change that happened mid-patch (race condition).
      this._modeVersion = 0;

      this._bindKeys();
      this._bindMic();
      this._bindKnobs();
    },

    beforeUpdate() {
      // Capture local state before LiveView patches the DOM, then tear down all
      // bindings. updated() will re-bind and restore — no double-listener risk.
      this._knobState = this._knobs.map(function (k) { return k.snapshotState(); });
      this._pendingMicActive = this._micActive;
      this._pendingMode = this._mode;
      this._pendingModeHistory = this._modeHistory.slice();
      // Record the version so updated() can detect mid-patch mode changes.
      this._pendingModeVersion = this._modeVersion;
      this._destroyKnobs();
      this._unbindKeys();
      this._unbindMic();
    },

    updated() {
      // Re-bind after patch and restore local state so patches don't revert dials.
      this._bindKeys();
      this._bindMic();
      this._bindKnobs();
      if (this._knobState) {
        var state = this._knobState;
        this._knobs.forEach(function (k, i) { k.restoreState(state[i]); });
        this._knobState = null;
      }
      // Restore mode state only if it did not change during the patch window.
      // A mid-patch user action (e.g. a second back press) increments _modeVersion;
      // if the version drifted, respect the user's more-recent intent.
      if (this._pendingMode) {
        if (this._modeVersion === this._pendingModeVersion) {
          this._modeHistory = this._pendingModeHistory || [];
          this._setMode(this._pendingMode, false);
        }
        this._pendingMode = null;
        this._pendingModeHistory = null;
        this._pendingModeVersion = null;
      }
      // Restore mic active state if the user was holding during the patch.
      // Use _restoringMic flag to suppress the redundant server pushEvent —
      // the server already knows mic is active.
      if (this._pendingMicActive) {
        this._restoringMic = true;
        this._setMic(true);
        this._restoringMic = false;
        this._pendingMicActive = false;
      }
    },

    destroyed() {
      this._destroyKnobs();
      this._unbindKeys();
      this._unbindMic();
    },

    _bindKnobs() {
      var self = this;
      var wraps = Array.prototype.slice.call(this.el.querySelectorAll(".sd-knob-wrap"));
      this._knobs = wraps.map(function (wrap, i) { return new Knob(wrap, i, self); });
    },

    _destroyKnobs() {
      this._knobs.forEach(function (k) { k.destroy(); });
      this._knobs = [];
    },

    _bindKeys() {
      var self = this;
      this._keyHandlers = [];
      var keys = Array.prototype.slice.call(this.el.querySelectorAll(".sd-key:not(.is-empty)"));
      keys.forEach(function (key) {
        var timer = null;
        var handler = function () {
          // Cancel any outstanding removal timer so rapid clicks don't race.
          clearTimeout(timer);
          key.classList.remove("is-flashing");
          // Force reflow so the animation restarts on rapid repeat clicks.
          void key.offsetWidth;
          key.classList.add("is-flashing");
          timer = setTimeout(function () { key.classList.remove("is-flashing"); }, 500);

          // Key click in grid mode transitions to cmd view.
          if (self._mode === "grid") {
            self._setMode("cmd");
          }
        };
        key.addEventListener("click", handler);
        self._keyHandlers.push({ el: key, handler: handler, timer: function () { return timer; } });
      });
    },

    _unbindKeys() {
      (this._keyHandlers || []).forEach(function (entry) {
        clearTimeout(entry.timer());
        entry.el.removeEventListener("click", entry.handler);
      });
      this._keyHandlers = [];
    },

    _bindMic() {
      var self = this;
      var mic = this.el.querySelector(".sd-screen-segment .sd-mic");
      if (!mic) {
        mic = this.el.querySelector(".sd-mic");
      }
      // Find the segment that contains the mic span.
      var micSegment = mic ? mic.closest(".sd-screen-segment") : null;
      if (!micSegment) return;

      this._micSegment = micSegment;
      this._onMicDown = function () { self._setMic(true); };
      this._onMicUp = function () { self._setMic(false); };

      micSegment.addEventListener("pointerdown", this._onMicDown);
      micSegment.addEventListener("pointerup", this._onMicUp);
      micSegment.addEventListener("pointerleave", this._onMicUp);
      micSegment.addEventListener("pointercancel", this._onMicUp);
    },

    _unbindMic() {
      var seg = this._micSegment;
      if (!seg) return;
      seg.removeEventListener("pointerdown", this._onMicDown);
      seg.removeEventListener("pointerup", this._onMicUp);
      seg.removeEventListener("pointerleave", this._onMicUp);
      seg.removeEventListener("pointercancel", this._onMicUp);
      this._micSegment = null;
      this._onMicDown = null;
      this._onMicUp = null;
    },

    _setMic(active) {
      if (this._micActive === active) return;
      this._micActive = active;
      var seg = this._micSegment;
      if (!seg) return;
      if (active) {
        seg.classList.add("is-live");
      } else {
        seg.classList.remove("is-live");
      }
      // Skip the server push when restoring across a patch — the server already
      // knows the mic state; a duplicate push would double-fire mic-hold.
      if (!this._restoringMic) {
        this.pushEvent("mic-hold", { active: active });
      }
    },

    // Advance or retreat the mode machine. Called from key click handlers and
    // Knob._press() for local transitions before the server event is pushed.
    _handleLocalDialPress(action) {
      if (action === "back") {
        var prev = this._modeHistory.pop();
        this._setMode(prev !== undefined ? prev : "grid", false);
      } else if (action === "cycle-window") {
        var idx = MODES.indexOf(this._mode);
        var next = MODES[(idx + 1) % MODES.length];
        this._setMode(next);
      }
    },

    // Set the active mode. Updates data-mode on .sd-device and aria-hidden on
    // each data-mode-view panel. Pass pushHistory=false when restoring state.
    _setMode(mode, pushHistory) {
      if (pushHistory !== false && this._mode !== mode) {
        this._modeHistory.push(this._mode);
      }
      this._mode = mode;
      this._modeVersion++;
      var device = this.el.querySelector(".sd-device");
      if (device) device.setAttribute("data-mode", mode);
      var views = Array.prototype.slice.call(this.el.querySelectorAll("[data-mode-view]"));
      views.forEach(function (view) {
        var isActive = view.getAttribute("data-mode-view") === mode;
        view.setAttribute("aria-hidden", isActive ? "false" : "true");
      });
    }
  };
})();
