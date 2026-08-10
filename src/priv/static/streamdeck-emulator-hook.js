// Stream Deck emulator interaction hook.
//
// Authority model: dial gestures are local-first, while fleet page, log
// offsets, and screen mode are server-authoritative. The hook pushes one
// coarse event per gesture step and LiveView clamps the resulting state to
// real bounds.
//
// Patch-survival pattern follows #1306: state is captured in beforeUpdate and
// restored in updated, so LiveView re-renders cannot revert local interaction.
// Key/mic event bindings are torn down in beforeUpdate and rebuilt in updated
// to avoid duplicate-listener accumulation across patches.
//
// Mode machine (server-authoritative):
//   grid → (key click) → cmd → (cycle-window) → logs
//   logs → (back) → cmd → (back) → grid
(function () {
  "use strict";

  var PRESS_THRESHOLD_DEG = 8;
  var PRESS_FLASH_MS = 160;
  var WHEEL_STEP = 4;
  var KEY_STEP = 4;
  // 270-degree physical sweep maps to full [0..100] range.
  var DRAG_DIVISOR = 2.7;

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
    this.preciseValue = this.value;
    this.isDragging = false;
    this.dragAngle = 0;
    this.accumulatedDeg = 0;
    this.netDeltaDeg = 0;
    this.visualAngle = parseFloat(this.knobEl.style.getPropertyValue("--a"));
    if (!Number.isFinite(this.visualAngle)) this.visualAngle = (this.value / 100) * 270 - 135;
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
    this.hook._pendingPageDialValue = null;
    this.knobEl.setPointerCapture(e.pointerId);
    this._activePid = e.pointerId;
    var c = this._centre();
    this.dragAngle = angleDeg(c.x, c.y, e.clientX, e.clientY);
    this.accumulatedDeg = 0;
    this.netDeltaDeg = 0;
    this.isDragging = true;

    this._bindDragListeners();
  };

  // Listen above the patched subtree so an active gesture survives replacement
  // of the knob element. Pointer capture still keeps normal browser delivery
  // semantics, while the document listener is the durable release path.
  Knob.prototype._bindDragListeners = function () {
    document.addEventListener("pointermove", this._onPointerMove);
    document.addEventListener("pointerup", this._onPointerUp);
    document.addEventListener("pointercancel", this._onPointerCancel);
  };

  Knob.prototype._unbindDragListeners = function () {
    document.removeEventListener("pointermove", this._onPointerMove);
    document.removeEventListener("pointerup", this._onPointerUp);
    document.removeEventListener("pointercancel", this._onPointerCancel);
  };

  Knob.prototype._onPointerMove = function (e) {
    if (!this.isDragging) return;
    if (this._activePid != null && e.pointerId !== this._activePid) return;
    var c = this._centre();
    var newAngle = angleDeg(c.x, c.y, e.clientX, e.clientY);
    var delta = normaliseWrap(newAngle - this.dragAngle);
    this.dragAngle = newAngle;
    this.accumulatedDeg += Math.abs(delta);
    this.netDeltaDeg += delta;
    this._step(delta / DRAG_DIVISOR, false);
  };

  Knob.prototype._onPointerUp = function (e) {
    if (!this.isDragging) return;
    if (this._activePid != null && e.pointerId !== this._activePid) return;
    var accumulatedDeg = this.accumulatedDeg;
    var netDeltaDeg = this.netDeltaDeg;
    this._endDrag();
    if (accumulatedDeg < PRESS_THRESHOLD_DEG) {
      this._press();
    } else {
      // Keep the gesture local until release, then commit its final value once.
      // Press detection uses absolute travel. Log scrolling needs signed net
      // movement for both transcript (A) and event (D) dials, while grid dial D
      // retains absolute accumulation so back-and-forth travel still commits
      // its final logical value.
      var signedCommit = this.index === 0 || (this.index === 3 && this.hook._mode === "logs");
      var commitDelta = signedCommit ? netDeltaDeg : accumulatedDeg;
      this.hook._handleDialStep(this.index, commitDelta);
    }
  };

  // A cancelled gesture is never a press — only reset drag state.
  Knob.prototype._onPointerCancel = function (e) {
    if (!this.isDragging) return;
    if (this._activePid != null && e.pointerId !== this._activePid) return;
    this._endDrag();
  };

  Knob.prototype._endDrag = function () {
    this._unbindDragListeners();
    if (this._activePid != null) {
      try { this.knobEl.releasePointerCapture(this._activePid); } catch (_) {}
    }
    this.isDragging = false;
    this._activePid = null;
    this.netDeltaDeg = 0;
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

  Knob.prototype._step = function (delta, notify) {
    if (notify !== false && this.index === 3) this.hook._pendingPageDialValue = null;
    var previousPreciseValue = this.preciseValue;
    this.preciseValue = clamp(this.preciseValue + delta, 0, 100);
    var appliedDelta = this.preciseValue - previousPreciseValue;
    this.value = clamp(Math.round(this.preciseValue), 0, 100);
    this._render();
    // Apply relative input to the retained physical marker. Programmatic
    // logical sync may intentionally leave the marker at a different angle.
    this.visualAngle = clamp(this.visualAngle + (appliedDelta * 270) / 100, -135, 135);
    this.knobEl.style.setProperty("--a", this.visualAngle + "deg");
    this.knobEl.setAttribute("aria-valuenow", String(this.value));
    if (notify !== false) this.hook._handleDialStep(this.index, delta);
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

  Knob.prototype.destroy = function (preserveDrag) {
    // Cancel any outstanding press animation timer.
    clearTimeout(this._pressTimer);
    this._pressTimer = null;

    // Release pointer capture and clean up dynamic drag listeners in case
    // destroy() is called while a drag is in progress (e.g., mid-patch).
    if (this.isDragging && this._activePid != null && !preserveDrag) {
      try { this.knobEl.releasePointerCapture(this._activePid); } catch (_) {}
    }
    if (preserveDrag && this.isDragging) {
      this._unbindDragListeners();
    } else {
      this._endDrag();
    }

    this.knobEl.removeEventListener("pointerdown", this._onPointerDown);
    this.knobEl.removeEventListener("wheel", this._onWheel);
    this.knobEl.removeEventListener("keydown", this._onKeydown);
  };

  Knob.prototype.snapshotState = function () {
    return {
      value: this.value,
      preciseValue: this.preciseValue,
      visualAngle: this.visualAngle,
      drag: this.isDragging ? {
        pointerId: this._activePid,
        dragAngle: this.dragAngle,
        accumulatedDeg: this.accumulatedDeg,
        netDeltaDeg: this.netDeltaDeg
      } : null
    };
  };

  Knob.prototype.restoreState = function (state) {
    if (!state) return;
    this.preciseValue = Number.isFinite(state.preciseValue) ? state.preciseValue : state.value;
    this.value = clamp(Math.round(this.preciseValue), 0, 100);
    this._render();
    this.knobEl.setAttribute("aria-valuenow", String(this.value));
    this.visualAngle = Number.isFinite(state.visualAngle) ? state.visualAngle : (this.value / 100) * 270 - 135;
    this.knobEl.style.setProperty("--a", this.visualAngle + "deg");
    if (state.drag) {
      this.isDragging = true;
      this._activePid = state.drag.pointerId;
      this.dragAngle = state.drag.dragAngle;
      this.accumulatedDeg = state.drag.accumulatedDeg;
      this.netDeltaDeg = state.drag.netDeltaDeg;
      this._bindDragListeners();
    }
  };

  Knob.prototype._setLogicalValue = function (value) {
    this.preciseValue = clamp(value, 0, 100);
    this.value = clamp(Math.round(this.preciseValue), 0, 100);
    this._render();
    this.knobEl.setAttribute("aria-valuenow", String(this.value));
  };

  window.AiurStreamdeckEmulatorHook = {
    mounted() {
      this._knobs = [];
      this._micActive = false;
      this._knobState = null;
      this._keyHandlers = [];
      this._flashingCommand = null;
      this._flashTimer = null;
      this._micKey = null;
      this._onMicDown = null;
      this._onMicUp = null;
      this._mode = "grid";
      this._modeHistory = [];
      this._pendingPageDialValue = null;
      // Version counter guards against a patch's beforeUpdate/updated window
      // overwriting a mode change that happened mid-patch (race condition).
      this._modeVersion = 0;

      this._bindKeys();
      this._bindCommandKeys();
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
      this._destroyKnobs(true);
      this._unbindKeys();
      this._unbindCommandKeys();
    },

    updated() {
      // Re-bind after patch and restore local state so patches don't revert dials.
      this._bindKeys();
      this._bindCommandKeys();
      this._bindKnobs();
      if (this._knobState) {
        var state = this._knobState;
        this._knobs.forEach(function (k, i) { k.restoreState(state[i]); });
        this._knobState = null;
      }
      var serverPageDialValue = this._syncPageKnob();
      if (this._pendingPageDialValue !== null) {
        if (serverPageDialValue === this._pendingPageDialValue) {
          // The authoritative patch acknowledged the optimistic page cycle.
          // Retire it so a later fleet/status patch can move the dial again.
          this._pendingPageDialValue = null;
        } else if (this._knobs[3]) {
          // An unrelated patch arrived first. Preserve the optimistic value
          // until the matching page-cycle acknowledgement is rendered.
          this._knobs[3]._setLogicalValue(this._pendingPageDialValue);
        }
      }
      // Keep the server-rendered mode authoritative after every patch. A command
      // click initiated by LiveView can advance the mode independently.
      if (this._pendingMode) {
        var device = this.el.querySelector(".sd-device");
        var serverMode = device && device.getAttribute("data-mode");
        if (serverMode && serverMode !== this._pendingMode) {
          this._modeHistory = [];
          this._setMode(serverMode, false);
        } else if (this._modeVersion === this._pendingModeVersion) {
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
        if (this._micKey) {
          this._restoringMic = true;
          this._setMic(true);
          this._restoringMic = false;
        } else {
          // A mode transition removed the held Mic key. Its eventual pointerup
          // cannot reach the detached node, so clear the server state now
          // rather than restoring a hold that can no longer be released.
          this._micActive = false;
          this.pushEvent("mic-hold", { active: false });
        }
        this._pendingMicActive = false;
      }
    },

    destroyed() {
      this._destroyKnobs();
      this._unbindKeys();
      this._unbindCommandKeys();
    },

    _bindKnobs() {
      var self = this;
      var wraps = Array.prototype.slice.call(this.el.querySelectorAll(".sd-knob-wrap"));
      this._knobs = wraps.map(function (wrap, i) { return new Knob(wrap, i, self); });
    },

    _destroyKnobs(preserveDrag) {
      this._knobs.forEach(function (k) { k.destroy(preserveDrag); });
      this._knobs = [];
    },

    _handleDialStep(index, delta) {
      if (!delta) return;
      var dial = this._knobs && this._knobs[index];
      var value = dial ? dial.value : 0;
      if (this._mode === "grid" && index === 3) {
        this._requestGridPage(value);
      } else if (this._mode === "logs" && index === 3) {
        this.pushEvent("logs-scroll", { axis: "events", delta: delta > 0 ? 1 : -1 });
      } else if (this._mode === "logs" && index === 0) {
        this.pushEvent("logs-scroll", { axis: "transcript", delta: delta > 0 ? 1 : -1 });
      }
    },

    _requestGridPage(value) {
      if (!Number.isFinite(value)) return;
      this.pushEvent("grid-page", { value: clamp(value, 0, 100) });
    },

    _syncPageKnob() {
      var keys = this.el.querySelector("#sd-keys");
      var knob = this._knobs && this._knobs[3];
      if (!keys || !knob) return null;
      var value = parseInt(keys.getAttribute("data-grid-dial-value") || "0", 10);
      if (!Number.isFinite(value)) return null;
      knob._setLogicalValue(value);
      return value;
    },

    _bindKeys() {
      var self = this;
      this._keyHandlers = [];
      // Both key grids bind here: #sd-keys carries the agent keys (and, in cmd
      // mode, the command keys) and #sd-log-keys carries the eight logs keys.
      // Scoping to the two grids keeps stray .sd-key markup elsewhere in the
      // device out of the agent key-press path.
      var keys = Array.prototype.slice.call(
        this.el.querySelectorAll("#sd-keys .sd-key:not(.is-empty), #sd-log-keys .sd-key:not(.is-empty)")
      );
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

          var logEventIndex = key.getAttribute("data-log-event-index");

          // Log keys index the flattened transcript instead of selecting an
          // agent. The server owns the resulting transcript offset.
          // `data-log-event-index` is authoritative on its own; the
          // client-tracked `_mode` only reconciles at the end of updated(),
          // so gating on it would silently drop a click while it lagged.
          if (logEventIndex !== null) {
            self.pushEvent("log-key-select", { index: Number(logEventIndex) });
            return;
          }

          var identifier = key.getAttribute("data-streamdeck-identifier");
          if (identifier) {
            self.pushEvent("key-press", { identifier: identifier });
          }
        };
        var keydownHandler = function (event) {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            handler();
          }
        };
        key.addEventListener("click", handler);
        key.addEventListener("keydown", keydownHandler);
        self._keyHandlers.push({ el: key, handler: handler, keydownHandler: keydownHandler, timer: function () { return timer; } });
      });
    },

    _unbindKeys() {
      (this._keyHandlers || []).forEach(function (entry) {
        clearTimeout(entry.timer());
        entry.el.removeEventListener("click", entry.handler);
        entry.el.removeEventListener("keydown", entry.keydownHandler);
      });
      this._keyHandlers = [];
    },

    _bindCommandKeys() {
      var self = this;
      this._commandHandlers = [];
      var keys = Array.prototype.slice.call(this.el.querySelectorAll("[data-streamdeck-command]"));
      keys.forEach(function (key) {
        var command = key.getAttribute("data-streamdeck-command");
        if (command === "mic") {
          self._micKey = key;
          self._onMicDown = function () { self._setMic(true); };
          self._onMicUp = function () { self._setMic(false); };
          key.addEventListener("pointerdown", self._onMicDown);
          key.addEventListener("pointerup", self._onMicUp);
          key.addEventListener("pointerleave", self._onMicUp);
          key.addEventListener("pointercancel", self._onMicUp);
          return;
        }

        if (self._flashingCommand === command) key.classList.add("is-flashing");
        var handler = function () {
          clearTimeout(self._flashTimer);
          self._flashingCommand = command;
          key.classList.remove("is-flashing");
          void key.offsetWidth;
          key.classList.add("is-flashing");
          self._flashTimer = setTimeout(function () {
            var active = self.el.querySelector('[data-streamdeck-command="' + command + '"]');
            if (active) active.classList.remove("is-flashing");
            self._flashingCommand = null;
            self._flashTimer = null;
          }, 500);
          var push = function () {
            self.pushEvent("command-press", { command: command, identifier: key.getAttribute("data-streamdeck-identifier") });
          };
          // Logs replaces the command keys, so leave its flash visible before
          // asking the server-authoritative mode machine to enter logs.
          if (command === "logs") setTimeout(push, 500);
          else push();
        };
        key.addEventListener("click", handler);
        self._commandHandlers.push({ el: key, handler: handler });
      });
    },

    _unbindCommandKeys() {
      (this._commandHandlers || []).forEach(function (entry) {
        entry.el.removeEventListener("click", entry.handler);
      });
      this._commandHandlers = [];
      var key = this._micKey;
      if (!key) return;
      key.removeEventListener("pointerdown", this._onMicDown);
      key.removeEventListener("pointerup", this._onMicUp);
      key.removeEventListener("pointerleave", this._onMicUp);
      key.removeEventListener("pointercancel", this._onMicUp);
      this._micKey = null;
      this._onMicDown = null;
      this._onMicUp = null;
    },

    _setMic(active) {
      if (this._micActive === active) return;
      this._micActive = active;
      // The held state renders as .sd-mic-key.mic-live on the key, not on the
      // face the pointer handlers are bound to. Toggling it here on the same
      // element the server renders it on keeps the optimistic class and the
      // patched one identical, so the pulse starts on pointerdown rather than
      // a round trip later.
      var key = this._micKey && this._micKey.closest(".sd-mic-key");
      if (!key) return;
      if (active) {
        key.classList.add("mic-live");
      } else {
        key.classList.remove("mic-live");
      }
      // Skip the server push when restoring across a patch — the server already
      // knows the mic state; a duplicate push would double-fire mic-hold.
      if (!this._restoringMic) {
        this.pushEvent("mic-hold", { active: active });
      }
    },

    // Grid page cycling remains optimistic; all mode transitions wait for the
    // server-rendered data-mode so the active panel is never temporarily absent.
    _handleLocalDialPress(action) {
      if (action === "cycle-window" && this._mode === "grid") {
        this._requestGridWindowCycle();
      }
    },

    _requestGridWindowCycle() {
      var keys = this.el.querySelector("#sd-keys");
      var dial = this._knobs && this._knobs[3];
      if (keys && dial) {
        var total = parseInt(keys.getAttribute("data-grid-total") || "0", 10);
        var windows = parseInt(keys.getAttribute("data-grid-page-count") || "1", 10);
        var page = parseInt(keys.getAttribute("data-grid-page") || "0", 10);
        var maxOffset = Math.max(0, Math.ceil(total / 2) - 4);
        var nextPage = (page + 1) % Math.max(windows, 1);
        var offset = Math.min(nextPage * 4, maxOffset);
        var value = maxOffset === 0 ? 0 : Math.round((offset / maxOffset) * 100);
        // A page cycle changes logical value, not the physical marker.
        this._pendingPageDialValue = value;
        dial._setLogicalValue(value);
      }
      this.pushEvent("grid-page", { action: "cycle" });
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
