// Shared time-chart brush: it owns only the local rubber-band rectangle and
// sends the selected axis domain on release. LiveView owns the domain itself,
// so refreshes and theme changes cannot reset a zoomed chart.
(function () {
  "use strict";

  var MIN_SPAN_PX = 12;
  var SVG_NS = "http://www.w3.org/2000/svg";

  function number(value) {
    var parsed = Number(value);
    return isFinite(parsed) ? parsed : null;
  }

  function Brush(hook) {
    this.hook = hook;
    this.el = hook.el;
    this.onPointerDown = this.onPointerDown.bind(this);
    this.onPointerMove = this.onPointerMove.bind(this);
    this.onPointerUp = this.onPointerUp.bind(this);
    this.onPointerCancel = this.onPointerCancel.bind(this);
  }

  Brush.prototype.capture = function () {
    this.svg = this.el.querySelector('svg[data-time-brush="true"]');
    this.target = this.svg && this.svg.querySelector('[data-time-brush="true"]');
  };

  Brush.prototype.mount = function () {
    this.capture();
    this.el.addEventListener("pointerdown", this.onPointerDown);
  };

  Brush.prototype.updated = function () {
    this.clearSelection();
    this.capture();
  };

  Brush.prototype.destroy = function () {
    this.clearSelection();
    this.el.removeEventListener("pointerdown", this.onPointerDown);
  };

  Brush.prototype.onPointerDown = function (event) {
    if (event.button !== 0 || event.target !== this.target) return;

    var start = this.chartX(event);
    if (start == null) return;

    event.preventDefault();
    this.drag = { pointerId: event.pointerId, start: start, current: start };
    this.selection = document.createElementNS(SVG_NS, "rect");
    this.selection.setAttribute("class", "an-time-brush-selection");
    this.selection.setAttribute("fill", "var(--accent)");
    this.selection.setAttribute("fill-opacity", "0.16");
    this.selection.setAttribute("stroke", "var(--accent)");
    this.selection.setAttribute("stroke-width", "1");
    this.selection.setAttribute("pointer-events", "none");
    this.svg.appendChild(this.selection);
    this.drawSelection();
    this.el.setPointerCapture(event.pointerId);
    this.el.addEventListener("pointermove", this.onPointerMove);
    this.el.addEventListener("pointerup", this.onPointerUp);
    this.el.addEventListener("pointercancel", this.onPointerCancel);
  };

  Brush.prototype.onPointerMove = function (event) {
    if (!this.drag || event.pointerId !== this.drag.pointerId) return;
    var current = this.chartX(event);
    if (current == null) return;
    this.drag.current = current;
    this.drawSelection();
  };

  Brush.prototype.onPointerUp = function (event) {
    if (!this.drag || event.pointerId !== this.drag.pointerId) return;
    var drag = this.drag;
    var current = this.chartX(event);
    if (current != null) drag.current = current;
    var width = Math.abs(drag.current - drag.start);
    var domain = this.domainFor(drag.start, drag.current);
    this.clearSelection();

    if (width >= MIN_SPAN_PX && domain) {
      this.hook.pushEvent("time-domain", { t0: domain[0], t1: domain[1] });
    }
  };

  Brush.prototype.onPointerCancel = function (event) {
    if (this.drag && event.pointerId === this.drag.pointerId) this.clearSelection();
  };

  Brush.prototype.clearSelection = function () {
    if (this.selection && this.selection.parentNode) this.selection.parentNode.removeChild(this.selection);
    this.selection = null;
    this.drag = null;
    this.el.removeEventListener("pointermove", this.onPointerMove);
    this.el.removeEventListener("pointerup", this.onPointerUp);
    this.el.removeEventListener("pointercancel", this.onPointerCancel);
  };

  Brush.prototype.chartX = function (event) {
    if (!this.svg || !this.target) return null;
    var point = this.svg.createSVGPoint();
    point.x = event.clientX;
    point.y = event.clientY;
    var matrix = this.svg.getScreenCTM();
    if (!matrix) return null;
    var x = point.matrixTransform(matrix.inverse()).x;
    var left = number(this.target.getAttribute("x"));
    var width = number(this.target.getAttribute("width"));
    if (left == null || width == null) return null;
    return Math.max(left, Math.min(left + width, x));
  };

  Brush.prototype.drawSelection = function () {
    if (!this.selection || !this.drag || !this.target) return;
    var left = Math.min(this.drag.start, this.drag.current);
    var width = Math.abs(this.drag.current - this.drag.start);
    this.selection.setAttribute("x", left);
    this.selection.setAttribute("y", this.target.getAttribute("y"));
    this.selection.setAttribute("width", width);
    this.selection.setAttribute("height", this.target.getAttribute("height"));
  };

  Brush.prototype.domainFor = function (start, finish) {
    if (!this.svg || !this.target) return null;
    var t0 = number(this.svg.getAttribute("data-time-start"));
    var t1 = number(this.svg.getAttribute("data-time-end"));
    var left = number(this.target.getAttribute("x"));
    var width = number(this.target.getAttribute("width"));
    if (t0 == null || t1 == null || left == null || !width || t1 <= t0) return null;

    var project = function (x) { return Math.round(t0 + ((x - left) / width) * (t1 - t0)); };
    return [Math.min(project(start), project(finish)), Math.max(project(start), project(finish))];
  };

  window.AiurTimeBrushHook = {
    createLiveViewHook: function () {
      return {
        mounted: function () {
          this.timeBrush = new Brush(this);
          this.timeBrush.mount();
        },
        updated: function () {
          this.timeBrush.updated();
        },
        destroyed: function () {
          this.timeBrush.destroy();
        }
      };
    }
  };
})();
