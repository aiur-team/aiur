interface LinePoint {
  x: number;
  y: number;
  on: boolean;
}

interface Line {
  pts: LinePoint[];
  key: number;
  t: number;
}

interface Obstacle {
  cx: number;
  cy: number;
  hx: number;
  hy: number;
  r: number;
}

// Diagonal line field that bends around the logo/wordmark lockup in the hero.
export function createFlowField(): { redraw: () => void } {
  const canvas = document.getElementById("field") as HTMLCanvasElement | null;
  const hero = document.querySelector(".hero") as HTMLElement | null;
  const ctx = canvas?.getContext("2d") ?? null;
  if (!canvas || !hero || !ctx) return { redraw: () => {} };

  const ANGLE = -118 * (Math.PI / 180); // direction of the lines (down-right "\")
  const dir = { x: Math.cos(ANGLE), y: Math.sin(ANGLE) };
  const nrm = { x: -dir.y, y: dir.x }; // perpendicular (spacing axis)
  const SPACING = 23; // px between lines
  const STEP = 7; // sampling step along a line
  const GAP = 9; // snug clearance kept around the lockup
  const FADE = 260; // extra height below the fold the lines extend into (matches #field mask)

  let W = 0;
  let H = 0;
  let DPR = 1;
  let lines: Line[] = [];
  let obstacles: Obstacle[] = [];
  let progress = 1; // entrance progress 0..1

  function roundRectSDF(px: number, py: number, ob: Obstacle): number {
    const qx = Math.abs(px - ob.cx) - (ob.hx - ob.r);
    const qy = Math.abs(py - ob.cy) - (ob.hy - ob.r);
    const ax = Math.max(qx, 0);
    const ay = Math.max(qy, 0);
    return Math.sqrt(ax * ax + ay * ay) + Math.min(Math.max(qx, qy), 0) - ob.r;
  }

  function pointHidden(p: LinePoint): boolean {
    for (const ob of obstacles) {
      if (roundRectSDF(p.x, p.y, ob) < GAP) return true;
    }
    return false;
  }

  function buildObstacles(): void {
    obstacles = [];
    const crect = canvas!.getBoundingClientRect();
    document.querySelectorAll<HTMLElement>(".keepout").forEach((el) => {
      const r = el.getBoundingClientRect();
      if (!r.width) return;
      const isLogo = el.classList.contains("logo");
      const padX = isLogo ? 3 : 9;
      const padY = isLogo ? 1 : 6;
      const hx = r.width / 2 + padX;
      const hy = r.height / 2 + padY;
      obstacles.push({
        cx: r.left - crect.left + r.width / 2,
        cy: r.top - crect.top + r.height / 2,
        hx,
        hy,
        r: Math.min(hx, hy) * (isLogo ? 0.95 : 0.55),
      });
    });
  }

  function buildLines(): void {
    lines = [];
    if (!W || !H) return;
    const cx = W / 2;
    const cy = H / 2;
    const diag = Math.sqrt(W * W + H * H);
    const half = diag / 2 + SPACING;
    const nLines = Math.ceil(diag / SPACING) + 2;
    for (let i = -nLines; i <= nLines; i++) {
      const off = i * SPACING;
      const ax = cx + nrm.x * off;
      const ay = cy + nrm.y * off;
      const pts: LinePoint[] = [];
      for (let t = -half; t <= half; t += STEP) {
        const p: LinePoint = { x: ax + dir.x * t, y: ay + dir.y * t, on: true };
        p.on = !pointHidden(p);
        pts.push(p);
      }
      lines.push({ pts, key: ax + ay, t: 0 });
    }
    let mn = Infinity;
    let mx = -Infinity;
    for (const L of lines) {
      if (L.key < mn) mn = L.key;
      if (L.key > mx) mx = L.key;
    }
    const span = mx - mn || 1;
    for (const L of lines) L.t = (L.key - mn) / span;
  }

  function lineColor(): string {
    return getComputedStyle(document.body).getPropertyValue("--line").trim();
  }

  function draw(): void {
    if (!W) return;
    ctx!.clearRect(0, 0, W, H);
    ctx!.strokeStyle = lineColor();
    ctx!.lineWidth = 1;
    ctx!.lineCap = "round";
    const STAG = 0.32; // fraction of timeline used to stagger lines
    for (const L of lines) {
      let local = (progress - L.t * STAG) / (1 - STAG);
      local = local < 0 ? 0 : local > 1 ? 1 : local;
      if (local <= 0) continue;
      ctx!.globalAlpha = local;
      const pts = L.pts;
      ctx!.beginPath();
      let pen = false;
      for (const p of pts) {
        if (!p.on) {
          pen = false;
          continue;
        }
        if (!pen) {
          ctx!.moveTo(p.x, p.y);
          pen = true;
        } else {
          ctx!.lineTo(p.x, p.y);
        }
      }
      ctx!.stroke();
    }
    ctx!.globalAlpha = 1;
  }

  function resize(): void {
    DPR = Math.min(window.devicePixelRatio || 1, 2);
    W = hero!.clientWidth;
    H = hero!.clientHeight + FADE;
    canvas!.width = W * DPR;
    canvas!.height = H * DPR;
    ctx!.setTransform(DPR, 0, 0, DPR, 0, 0);
    buildObstacles();
    buildLines();
    draw();
  }

  function runEntrance(): void {
    let startTs: number | null = null;
    const DUR = 1500;
    progress = 0;
    function frame(ts: number): void {
      if (startTs === null) startTs = ts;
      const e = (ts - startTs) / DUR;
      progress = e >= 1 ? 1 : 1 - Math.pow(1 - e, 3); // easeOutCubic
      draw();
      if (e < 1) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function start(): void {
    resize();
    if (reduce) {
      progress = 1;
      draw();
    } else {
      runEntrance();
    }
  }

  // fonts can shift wordmark metrics; rebuild after they load
  if (document.fonts?.ready) {
    void document.fonts.ready.then(() => {
      buildObstacles();
      buildLines();
      draw();
    });
  }
  let rzTimer = 0;
  window.addEventListener("resize", () => {
    clearTimeout(rzTimer);
    rzTimer = window.setTimeout(resize, 120);
  });
  window.addEventListener("load", start);
  if (document.readyState === "complete") start();

  return { redraw: draw };
}
