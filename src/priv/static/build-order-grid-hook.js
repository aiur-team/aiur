// Build Order grid hook: draws dependency edges between grid cards and owns
// zoom / pan / fit. Zoom is a CSS transform scale on the scale wrapper; pan is
// native viewport scroll. Zoom/pan state lives on the hook instance (and is
// mirrored to sessionStorage) and is ALWAYS re-applied in `updated()` — it is
// never reset on a data refresh, so background provider updates cannot snap the
// view back to 100%.
(function () {
  "use strict";

  var MIN_ZOOM = 0.1;
  var MAX_ZOOM = 1.6;
  var ZOOM_STEP = 0.1;

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  function round2(value) {
    return Math.round(value * 100) / 100;
  }

  function Grid(el) {
    this.el = el;
    this.scale = 1;
    this.storageKey = "aiur-bo-grid:" + (el.getAttribute("data-bo-grid-key") || el.id || "default");
    this.onZoomClick = this.onZoomClick.bind(this);
    this.onWheel = this.onWheel.bind(this);
    this.onKeydown = this.onKeydown.bind(this);
    this.onPointerDown = this.onPointerDown.bind(this);
    this.onPointerMove = this.onPointerMove.bind(this);
    this.onPointerUp = this.onPointerUp.bind(this);
    this.onPointerOver = this.onPointerOver.bind(this);
    this.onPointerOut = this.onPointerOut.bind(this);
    this.onClick = this.onClick.bind(this);
    this.scheduleDraw = this.scheduleDraw.bind(this);
    this.onResize = this.onResize.bind(this);
    this.activeId = null; // card whose dependencies are currently highlighted
    this.pinnedId = null; // when set, the highlight is locked and hover is frozen
  }

  Grid.prototype.capture = function () {
    var q = this.el.querySelector.bind(this.el);
    this.viewport = q("[data-bo-grid-viewport]");
    this.scaleEl = q("[data-bo-grid-scale]");
    this.stage = q("[data-bo-grid-stage]");
    this.body = q("[data-bo-grid-body]");
    this.edgesSvg = q("[data-bo-grid-edges]");
    this.readout = q("[data-bo-zoom-level]");
    this.announce = q("[data-bo-grid-announce]");
    this.zoomButtons = Array.prototype.slice.call(this.el.querySelectorAll("[data-bo-zoom]"));
  };

  Grid.prototype.mount = function () {
    this.capture();
    if (!this.viewport || !this.scaleEl) return;

    var stored = this.restoreScale();
    this.scale = stored == null ? 1 : stored;
    this.autoFit = true; // always fit the whole grid to width on page load

    this.zoomButtons.forEach(function (button) {
      button.addEventListener("click", this.onZoomClick);
    }, this);
    this.viewport.addEventListener("wheel", this.onWheel, { passive: false });
    this.viewport.addEventListener("keydown", this.onKeydown);
    this.viewport.addEventListener("pointerdown", this.onPointerDown);
    this.el.addEventListener("pointerover", this.onPointerOver);
    this.el.addEventListener("pointerout", this.onPointerOut);
    this.el.addEventListener("click", this.onClick);

    if (typeof ResizeObserver === "function") {
      this.observer = new ResizeObserver(this.onResize);
      this.observer.observe(this.body);
      this.observer.observe(this.viewport);
    }
    if (typeof window !== "undefined") {
      window.addEventListener("resize", this.onResize);
    }

    this.applyTransform();
    this.scheduleDraw();
    this.maybeAutoFit();
  };

  // Redraw edges on layout change, and — on first load only — fit to width once
  // the viewport has a real (non-transient) width. Fitting from the resize
  // observer avoids locking a tiny scale measured before layout settled.
  Grid.prototype.onResize = function () {
    this.scheduleDraw();
    this.maybeAutoFit();
  };

  Grid.prototype.maybeAutoFit = function () {
    if (!this.autoFit) return;
    if (!this.viewport || this.viewport.clientWidth < 320) return;
    this.fit(); // clears autoFit via setZoom
  };

  // Re-applied on every LiveView patch: heal any transform the DOM patch may
  // have dropped, and redraw edges against the freshly rendered cards. Zoom/pan
  // are intentionally preserved — never reset here.
  Grid.prototype.refresh = function () {
    this.capture();
    if (!this.viewport || !this.scaleEl) return;
    this.applyTransform();
    this.scheduleDraw();
  };

  Grid.prototype.destroy = function () {
    if (this.observer) this.observer.disconnect();
    if (typeof window !== "undefined") window.removeEventListener("resize", this.onResize);
  };

  // --- zoom -----------------------------------------------------------------

  Grid.prototype.setZoom = function (next) {
    this.autoFit = false;
    this.scale = clamp(round2(next), MIN_ZOOM, MAX_ZOOM);
    this.storeScale();
    this.applyTransform();
    this.scheduleDraw();
    if (this.announce) this.announce.textContent = "Zoom " + Math.round(this.scale * 100) + "%";
  };

  Grid.prototype.onZoomClick = function (event) {
    var action = event.currentTarget.getAttribute("data-bo-zoom");
    if (action === "in") this.setZoom(this.scale + ZOOM_STEP);
    else if (action === "out") this.setZoom(this.scale - ZOOM_STEP);
    else if (action === "fit") this.fit();
  };

  Grid.prototype.onWheel = function (event) {
    if (!(event.ctrlKey || event.metaKey)) return;
    event.preventDefault();
    this.setZoom(this.scale + (event.deltaY < 0 ? ZOOM_STEP : -ZOOM_STEP));
  };

  Grid.prototype.onKeydown = function (event) {
    // Enter/Space on a focused, openable card opens its ticket context.
    var card = event.target.closest && event.target.closest('[data-bo-card][role="button"]');
    if (card && (event.key === "Enter" || event.key === " ")) {
      event.preventDefault();
      card.click();
      return;
    }
    if (event.target !== this.viewport) return;
    if (event.key === "+" || event.key === "=") {
      event.preventDefault();
      this.setZoom(this.scale + ZOOM_STEP);
    } else if (event.key === "-" || event.key === "_") {
      event.preventDefault();
      this.setZoom(this.scale - ZOOM_STEP);
    } else if (event.key === "0") {
      event.preventDefault();
      this.setZoom(1);
    }
  };

  // Fit the full grid WIDTH into the viewport so a zoom-out shows every epic
  // column edge to edge; height overflows to vertical scroll.
  Grid.prototype.fit = function () {
    var vw = this.viewport.clientWidth - 8;
    var sw = this.stage.offsetWidth;
    if (sw <= 0) return;
    this.viewport.scrollLeft = 0;
    this.viewport.scrollTop = 0;
    // Floor so a fit can never collapse the graph to an unreadable sliver.
    this.setZoom(Math.max(0.4, Math.min(1, vw / sw)));
  };

  Grid.prototype.applyTransform = function () {
    var s = this.scale;
    // Scale the stage (not the scroll layer) and size the scroll layer to the
    // SCALED content. A CSS transform leaves the layout box unscaled, so without
    // this the viewport would scroll far past the visible graph.
    var target = this.stage || this.scaleEl;
    target.style.transformOrigin = "0 0";
    target.style.transform = "scale(" + s + ")";
    if (this.scaleEl && this.stage) {
      this.scaleEl.style.width = Math.ceil(this.stage.offsetWidth * s) + "px";
      this.scaleEl.style.height = Math.ceil(this.stage.offsetHeight * s) + "px";
    }
    if (this.readout) this.readout.textContent = Math.round(s * 100) + "%";
    this.zoomButtons.forEach(function (button) {
      var action = button.getAttribute("data-bo-zoom");
      if (action === "in") button.disabled = s >= MAX_ZOOM;
      else if (action === "out") button.disabled = s <= MIN_ZOOM;
    }, this);
  };

  Grid.prototype.restoreScale = function () {
    try {
      var stored = parseFloat(window.sessionStorage.getItem(this.storageKey));
      if (!isNaN(stored)) return clamp(stored, MIN_ZOOM, MAX_ZOOM);
    } catch (_error) {}
    return null;
  };

  Grid.prototype.storeScale = function () {
    try {
      window.sessionStorage.setItem(this.storageKey, String(this.scale));
    } catch (_error) {}
  };

  // --- pan (native scroll drag) ---------------------------------------------

  Grid.prototype.onPointerDown = function (event) {
    if (event.button !== 0) return;
    if (event.target.closest("button, a, [data-bo-card]")) return;
    this.drag = {
      x: event.clientX,
      y: event.clientY,
      left: this.viewport.scrollLeft,
      top: this.viewport.scrollTop
    };
    this.viewport.setPointerCapture(event.pointerId);
    this.viewport.classList.add("is-grabbing");
    this.viewport.addEventListener("pointermove", this.onPointerMove);
    this.viewport.addEventListener("pointerup", this.onPointerUp);
    this.viewport.addEventListener("pointercancel", this.onPointerUp);
  };

  Grid.prototype.onPointerMove = function (event) {
    if (!this.drag) return;
    this.viewport.scrollLeft = this.drag.left - (event.clientX - this.drag.x);
    this.viewport.scrollTop = this.drag.top - (event.clientY - this.drag.y);
  };

  Grid.prototype.onPointerUp = function (event) {
    this.drag = null;
    this.viewport.classList.remove("is-grabbing");
    try {
      this.viewport.releasePointerCapture(event.pointerId);
    } catch (_error) {}
    this.viewport.removeEventListener("pointermove", this.onPointerMove);
    this.viewport.removeEventListener("pointerup", this.onPointerUp);
    this.viewport.removeEventListener("pointercancel", this.onPointerUp);
  };

  // --- edges ----------------------------------------------------------------

  Grid.prototype.scheduleDraw = function () {
    if (this.drawScheduled) return;
    this.drawScheduled = true;
    var self = this;
    (window.requestAnimationFrame || function (fn) { return setTimeout(fn, 16); })(function () {
      self.drawScheduled = false;
      self.drawEdges();
    });
  };

  Grid.prototype.edgeData = function () {
    return Array.prototype.slice.call(this.el.querySelectorAll("[data-bo-grid-edge-data] [data-bo-edge-source]"));
  };

  Grid.prototype.cardBox = function (id, bodyRect) {
    var card = this.body.querySelector('[data-bo-card="' + cssEscape(id) + '"]');
    if (!card) return null;
    var rect = card.getBoundingClientRect();
    var scale = this.scale || 1;
    return {
      el: card,
      x: (rect.left - bodyRect.left) / scale,
      y: (rect.top - bodyRect.top) / scale,
      w: rect.width / scale,
      h: rect.height / scale
    };
  };

  Grid.prototype.drawEdges = function () {
    if (!this.edgesSvg || !this.body) return;
    var width = this.body.offsetWidth;
    var height = this.body.offsetHeight;
    this.edgesSvg.setAttribute("width", width);
    this.edgesSvg.setAttribute("height", height);
    this.edgesSvg.setAttribute("viewBox", "0 0 " + width + " " + height);

    var bodyRect = this.body.getBoundingClientRect();
    var edges = this.edgeData();
    var parts = [];
    this.edgeIndex = {};

    for (var i = 0; i < edges.length; i++) {
      var node = edges[i];
      var sourceId = node.getAttribute("data-bo-edge-source");
      var targetId = node.getAttribute("data-bo-edge-target");
      var state = node.getAttribute("data-bo-edge-state") || "blocking";
      var s = this.cardBox(sourceId, bodyRect);
      var t = this.cardBox(targetId, bodyRect);
      if (!s || !t) continue;

      var x1 = s.x + s.w / 2;
      var y1 = s.y + s.h;
      var x2 = t.x + t.w / 2;
      var y2 = t.y;
      var dy = Math.max(24, Math.abs(y2 - y1) * 0.45);
      var d = "M " + x1 + " " + y1 + " C " + x1 + " " + (y1 + dy) + ", " + x2 + " " + (y2 - dy) + ", " + x2 + " " + y2;

      parts.push('<path class="bo-edge is-' + state + '" data-from="' + escapeAttr(sourceId) +
        '" data-to="' + escapeAttr(targetId) + '" d="' + d + '"/>');
      parts.push('<circle class="bo-edge-dot is-' + state + '" cx="' + x2 + '" cy="' + y2 + '" r="2.4"/>');

      (this.edgeIndex[sourceId] = this.edgeIndex[sourceId] || []).push(i);
      (this.edgeIndex[targetId] = this.edgeIndex[targetId] || []).push(i);
    }

    this.edgesSvg.innerHTML = parts.join("");
    this.edgePaths = Array.prototype.slice.call(this.edgesSvg.querySelectorAll(".bo-edge"));
    this.buildAdjacency();
    this.reapplyHighlight();
  };

  // Forward (blocker → blocked) and reverse adjacency for transitive highlight.
  Grid.prototype.buildAdjacency = function () {
    this.fwd = {};
    this.rev = {};
    (this.edgePaths || []).forEach(function (path) {
      var f = path.getAttribute("data-from");
      var t = path.getAttribute("data-to");
      (this.fwd[f] = this.fwd[f] || []).push(t);
      (this.rev[t] = this.rev[t] || []).push(f);
    }, this);
  };

  // --- hover highlight + pin ------------------------------------------------
  //
  // Hover uses pointerover with a "same card" guard so moving between a card's
  // own children never clears + re-sets the highlight (which caused flicker).
  // Clicking a card's blocks tag ([data-bo-pin]) locks the current highlight;
  // while locked, hover is frozen and only a real card click (which opens the
  // ticket modal) or clicking the tag again clears it.

  Grid.prototype.onPointerOver = function (event) {
    var card = event.target.closest("[data-bo-card]");
    this.setHover(card ? card.getAttribute("data-bo-card") : null);
  };

  Grid.prototype.onPointerOut = function (event) {
    // Only clear when the pointer genuinely leaves the grid; moving between
    // elements inside the grid is handled by pointerover.
    if (event.relatedTarget && this.el.contains(event.relatedTarget)) return;
    this.setHover(null);
  };

  Grid.prototype.setHover = function (id) {
    if (this.pinnedId) return; // frozen while a highlight is pinned
    if (id === this.activeId) return; // same card → no-op, prevents flicker
    this.activeId = id;
    this.applyHighlight(id);
  };

  Grid.prototype.onClick = function (event) {
    var pin = event.target.closest("[data-bo-pin]");
    if (pin) {
      // The blocks tag: pin/unpin the highlight instead of opening the modal.
      event.preventDefault();
      event.stopPropagation();
      var pinCard = pin.closest("[data-bo-card]");
      if (pinCard) this.togglePin(pinCard.getAttribute("data-bo-card"));
      return;
    }
    // A normal card click opens its ticket modal — that cancels any pin.
    if (this.pinnedId && event.target.closest("[data-bo-card]")) this.clearPin();
  };

  Grid.prototype.togglePin = function (id) {
    if (this.pinnedId === id) {
      this.clearPin();
      return;
    }
    this.pinnedId = id;
    this.activeId = id;
    this.applyHighlight(id);
    this.markPinned(id);
  };

  Grid.prototype.clearPin = function () {
    this.pinnedId = null;
    this.markPinned(null);
    this.activeId = null;
    this.applyHighlight(null);
  };

  // Pinned also toggles `is-locked` on the grid root so CSS can fade every
  // card that is not part of the locked dependency chain.
  Grid.prototype.markPinned = function (id) {
    this.el.classList.toggle("is-locked", !!id);
    if (!this.body) return;
    var cards = this.body.querySelectorAll("[data-bo-card]");
    Array.prototype.forEach.call(cards, function (card) {
      card.classList.toggle("is-pinned", card.getAttribute("data-bo-card") === id);
    });
  };

  Grid.prototype.applyHighlight = function (id) {
    // Full transitive dependency chain, but keyed by HOP DISTANCE from the
    // source: 0 = source, 1 = direct blocker/blocked, >=2 = indirect. Reverse
    // edges reach ancestors, forward edges reach descendants (directional, so it
    // never collapses to the whole graph). Distance drives a lighter highlight
    // so direct dependencies read stronger than transitive ones.
    var dist = {};
    if (id) {
      dist[id] = 0;
      bfsDistance(id, this.fwd || {}, dist);
      bfsDistance(id, this.rev || {}, dist);
    }

    if (this.edgePaths) {
      this.edgePaths.forEach(function (path) {
        var f = path.getAttribute("data-from");
        var t = path.getAttribute("data-to");
        var inChain = id && dist[f] != null && dist[t] != null;
        // A "direct" edge touches the source itself; everything deeper is far.
        var direct = inChain && (f === id || t === id);
        path.classList.toggle("is-hl", !!(inChain && direct));
        path.classList.toggle("is-hl-far", !!(inChain && !direct));
        path.classList.toggle("is-dim", !!id && !inChain);
      });
    }

    if (!this.body) return;
    var cards = this.body.querySelectorAll("[data-bo-card]");
    Array.prototype.forEach.call(cards, function (card) {
      var cid = card.getAttribute("data-bo-card");
      var d = dist[cid];
      card.classList.toggle("is-hl-source", cid === id);
      card.classList.toggle("is-hl-linked", d === 1);
      card.classList.toggle("is-hl-indirect", d >= 2);
    });
  };

  // Re-apply the current highlight after edges are (re)drawn — a LiveView patch
  // replaces card DOM and drops the classes, so a pinned/hovered state would
  // otherwise vanish on the next background refresh.
  Grid.prototype.reapplyHighlight = function () {
    var id = this.pinnedId || this.activeId;
    if (!id) return;
    this.applyHighlight(id);
    if (this.pinnedId) this.markPinned(this.pinnedId);
  };

  // --- utils ----------------------------------------------------------------

  // Record each node reachable from `start` via `adj` ({id: [ids]}) with its
  // shortest hop distance, written into the shared `dist` map.
  function bfsDistance(start, adj, dist) {
    var queue = [start];
    var head = 0;
    while (head < queue.length) {
      var node = queue[head++];
      var d = dist[node];
      var neighbours = adj[node] || [];
      for (var i = 0; i < neighbours.length; i++) {
        var next = neighbours[i];
        if (dist[next] == null || dist[next] > d + 1) {
          dist[next] = d + 1;
          queue.push(next);
        }
      }
    }
  }

  function cssEscape(value) {
    if (window.CSS && window.CSS.escape) return window.CSS.escape(value);
    return String(value).replace(/["\\\]]/g, "\\$&");
  }

  function escapeAttr(value) {
    return String(value).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
  }

  window.AiurBuildOrderGridHook = {
    mounted: function () {
      this.grid = new Grid(this.el);
      this.grid.mount();
    },
    updated: function () {
      if (this.grid) this.grid.refresh();
    },
    destroyed: function () {
      if (this.grid) this.grid.destroy();
    }
  };
})();
