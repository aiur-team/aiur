export function createFlowField(canvas, opts = {}) {
    const host = opts.host ?? canvas.parentElement;
    const ctx = canvas.getContext('2d');
    if (!host || !ctx)
        throw new Error('Flow field requires a host and a 2D canvas context');
    canvas.setAttribute('aria-hidden', 'true');
    const ANGLE = (opts.angleDeg ?? -118) * (Math.PI / 180);
    const dir = { x: Math.cos(ANGLE), y: Math.sin(ANGLE) };
    const nrm = { x: -dir.y, y: dir.x };
    const SPACING = opts.spacing ?? 23;
    const STEP = opts.step ?? 7;
    const GAP = opts.gap ?? 9;
    const FADE = opts.fade ?? 260;
    if (SPACING <= 0 || STEP <= 0)
        throw new Error('Flow field spacing and step must be positive');
    if (opts.fade !== undefined)
        canvas.style.setProperty('--aiur-field-fade', `${FADE}px`);
    const hugSelector = opts.hug ?? '.aiur-hug, .hug';
    const selector = `${opts.keepouts ?? '.aiur-keepout, .keepout'}, ${hugSelector}`;
    const entranceMs = matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : (opts.entranceMs ?? 1500);
    let W = 0;
    let H = 0;
    let lines = [];
    let obstacles = [];
    let keepouts = [];
    let progress = entranceMs > 0 ? 0 : 1;
    let destroyed = false;
    let frame = 0;
    let dirty = false;
    let started;
    const observer = new ResizeObserver(() => schedule(true));
    const mutations = new MutationObserver(() => { collect(); schedule(true); });
    function collect() {
        const next = Array.from(host.querySelectorAll(selector));
        for (const el of keepouts)
            if (!next.includes(el))
                observer.unobserve(el);
        for (const el of next)
            if (!keepouts.includes(el))
                observer.observe(el);
        keepouts = next;
    }
    function schedule(rebuild = false) {
        if (destroyed)
            return;
        dirty || (dirty = rebuild);
        if (!frame)
            frame = requestAnimationFrame(update);
    }
    function update(ts) {
        frame = 0;
        if (destroyed)
            return;
        if (dirty) {
            dirty = false;
            resize();
        }
        if (progress < 1) {
            started ?? (started = ts);
            const elapsed = Math.min(1, (ts - started) / entranceMs);
            progress = 1 - Math.pow(1 - elapsed, 3);
        }
        draw();
        if (progress < 1)
            schedule();
    }
    function roundRectSDF(px, py, ob) {
        const qx = Math.abs(px - ob.cx) - (ob.hx - ob.r);
        const qy = Math.abs(py - ob.cy) - (ob.hy - ob.r);
        const ax = Math.max(qx, 0);
        const ay = Math.max(qy, 0);
        return Math.sqrt(ax * ax + ay * ay) + Math.min(Math.max(qx, qy), 0) - ob.r;
    }
    function pointHidden(p) {
        for (const ob of obstacles) {
            if (roundRectSDF(p.x, p.y, ob) < GAP)
                return true;
        }
        return false;
    }
    function lineRects(element) {
        const range = document.createRange();
        range.selectNodeContents(element);
        const byLine = new Map();
        for (const rect of Array.from(range.getClientRects())) {
            if (!rect.width)
                continue;
            const key = Math.round(rect.top);
            const seen = byLine.get(key);
            byLine.set(key, seen
                ? new DOMRect(Math.min(seen.left, rect.left), Math.min(seen.top, rect.top), Math.max(seen.right, rect.right) - Math.min(seen.left, rect.left), Math.max(seen.bottom, rect.bottom) - Math.min(seen.top, rect.top))
                : rect);
        }
        return [...byLine.values()];
    }
    function buildObstacles() {
        obstacles = [];
        const crect = canvas.getBoundingClientRect();
        for (const el of keepouts) {
            const hugging = el.matches(hugSelector);
            const rects = hugging ? lineRects(el) : [el.getBoundingClientRect()];
            const isLogo = !hugging && el.matches(opts.logoSelector ?? '.aiur-lockup__logo, .logo');
            for (const rect of rects) {
                if (!rect.width || !rect.height)
                    continue;
                const hx = rect.width / 2 + (isLogo ? 3 : 9);
                const hy = rect.height / 2 + (isLogo ? 1 : 6);
                obstacles.push({
                    cx: rect.left - crect.left + rect.width / 2,
                    cy: rect.top - crect.top + rect.height / 2,
                    hx, hy, r: Math.min(hx, hy) * (isLogo ? 0.95 : 0.55),
                });
            }
        }
    }
    function buildLines() {
        lines = [];
        if (!W || !H)
            return;
        const cx = W / 2;
        const cy = H / 2;
        const diag = Math.sqrt(W * W + H * H);
        const half = diag / 2 + SPACING;
        const nLines = Math.ceil(diag / SPACING) + 2;
        for (let i = -nLines; i <= nLines; i++) {
            const off = i * SPACING;
            const ax = cx + nrm.x * off;
            const ay = cy + nrm.y * off;
            const pts = [];
            for (let t = -half; t <= half; t += STEP) {
                const p = { x: ax + dir.x * t, y: ay + dir.y * t, on: true };
                p.on = !pointHidden(p);
                pts.push(p);
            }
            lines.push({ pts, key: ax + ay, t: 0 });
        }
        let mn = Infinity;
        let mx = -Infinity;
        for (const L of lines) {
            if (L.key < mn)
                mn = L.key;
            if (L.key > mx)
                mx = L.key;
        }
        const span = mx - mn || 1;
        for (const L of lines)
            L.t = (L.key - mn) / span;
    }
    function lineColor() {
        return getComputedStyle(canvas).getPropertyValue("--aiur-color-field-line").trim();
    }
    function draw() {
        if (destroyed || !W)
            return;
        ctx.clearRect(0, 0, W, H);
        ctx.strokeStyle = lineColor();
        ctx.lineWidth = 1;
        ctx.lineCap = "round";
        const STAG = 0.32; // fraction of timeline used to stagger lines
        for (const L of lines) {
            let local = (progress - L.t * STAG) / (1 - STAG);
            local = local < 0 ? 0 : local > 1 ? 1 : local;
            if (local <= 0)
                continue;
            ctx.globalAlpha = local;
            const pts = L.pts;
            ctx.beginPath();
            let pen = false;
            for (const p of pts) {
                if (!p.on) {
                    pen = false;
                    continue;
                }
                if (!pen) {
                    ctx.moveTo(p.x, p.y);
                    pen = true;
                }
                else {
                    ctx.lineTo(p.x, p.y);
                }
            }
            ctx.stroke();
        }
        ctx.globalAlpha = 1;
    }
    function resize() {
        const DPR = Math.min(window.devicePixelRatio || 1, 2);
        W = host.clientWidth;
        H = host.clientHeight + FADE;
        if (canvas.width !== W * DPR || canvas.height !== H * DPR) {
            canvas.width = W * DPR;
            canvas.height = H * DPR;
        }
        ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
        buildObstacles();
        buildLines();
    }
    const rebuild = () => schedule(true);
    const redraw = () => schedule();
    collect();
    observer.observe(host);
    mutations.observe(host, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
    document.addEventListener('aiur:themechange', redraw);
    document.addEventListener('aiur:layoutchange', rebuild);
    window.addEventListener('resize', rebuild);
    void document.fonts?.ready.then(rebuild);
    schedule(true);
    return {
        redraw,
        rebuild,
        debug: () => ({ obstacles: canvas.hasAttribute('data-aiur-debug') ? obstacles.map(ob => ({ ...ob })) : [] }),
        destroy() {
            if (destroyed)
                return;
            destroyed = true;
            cancelAnimationFrame(frame);
            frame = 0;
            observer.disconnect();
            mutations.disconnect();
            document.removeEventListener('aiur:themechange', redraw);
            document.removeEventListener('aiur:layoutchange', rebuild);
            window.removeEventListener('resize', rebuild);
            ctx.clearRect(0, 0, W, H);
            obstacles = [];
            lines = [];
        },
    };
}
