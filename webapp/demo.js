// "Waypoints" — see docs/DEMO-DESIGN.md for the design rationale. A small
// seeded route: nodes connected by a smooth curve, with points of light
// continuously traveling along it. No vendored library — just a seeded PRNG
// and canvas 2D (see DEMO-DESIGN.md's "Implementation plan" for why).
//
// Entry points, both called from app.js:
//   renderDemo(seed, container)   — live route, seeded from the commit SHA.
//   renderOfflineState(container) — static, desaturated, backend unreachable.
//
// Every tunable is in CONFIG below — nothing else in this file should need
// touching to adjust how the route looks or moves.

const CONFIG = {
  nodeCountRange: [6, 10],    // per-route node count, drawn from the seed
  walkStep: 0.22,             // avg. distance between nodes, fraction of canvas size
  margin: 0.1,                // keep nodes this far from every edge, fraction of canvas size
  curveSamplesPerSegment: 24, // resolution of the smoothed path

  nodeRadius: 5,
  routeLineWidth: 2,

  packetCount: 3,
  packetRadius: 3.5,
  packetSpeed: 0.09,   // fraction of the total path length crossed per second
  packetGlowBlur: 14,

  trailFade: 0.16,     // opacity of the fade-to-background wash each frame; higher = shorter trails

  hueHarmonyOffset: [20, 45], // analogous hue spread either side of the base hue, in degrees

  background: { s: 30, l: 9 },
  route: { s: 35, l: 42, a: 0.55 },
  node: { s: 55, l: 62 },
  packet: { s: 85, l: 68 },
};

function mulberry32(seed) {
  let state = seed >>> 0;
  return function random() {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

// A seeded random walk, clamped to stay inside the canvas with a margin.
// Reads as a wandering route immediately, before any line connects the
// dots — a uniform scatter of the same points would just read as noise.
function generateNodes(random, count) {
  const nodes = [];
  let x = 0.5;
  let y = 0.5;
  for (let i = 0; i < count; i++) {
    const angle = random() * Math.PI * 2;
    x = clamp(x + Math.cos(angle) * CONFIG.walkStep, CONFIG.margin, 1 - CONFIG.margin);
    y = clamp(y + Math.sin(angle) * CONFIG.walkStep, CONFIG.margin, 1 - CONFIG.margin);
    nodes.push({ x, y });
  }
  return nodes;
}

function catmullRomPoint(p0, p1, p2, p3, t) {
  const t2 = t * t;
  const t3 = t2 * t;
  return {
    x:
      0.5 *
      (2 * p1.x +
        (p2.x - p0.x) * t +
        (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
        (3 * p1.x - p0.x - 3 * p2.x + p3.x) * t3),
    y:
      0.5 *
      (2 * p1.y +
        (p2.y - p0.y) * t +
        (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
        (3 * p1.y - p0.y - 3 * p2.y + p3.y) * t3),
  };
}

function distance(a, b) {
  return Math.hypot(b.x - a.x, b.y - a.y);
}

// Samples a Catmull-Rom spline through `nodes` (normalized 0..1 coordinates)
// into a dense polyline with cumulative arc lengths attached, so drawing and
// constant-speed packet travel can both treat the route as flat distance
// along a line rather than a parametric curve.
function buildPath(nodes) {
  const points = [];
  const segments = nodes.length - 1;

  for (let i = 0; i < segments; i++) {
    const p0 = nodes[Math.max(i - 1, 0)];
    const p1 = nodes[i];
    const p2 = nodes[i + 1];
    const p3 = nodes[Math.min(i + 2, nodes.length - 1)];

    for (let s = 0; s < CONFIG.curveSamplesPerSegment; s++) {
      points.push(catmullRomPoint(p0, p1, p2, p3, s / CONFIG.curveSamplesPerSegment));
    }
  }
  points.push(nodes[nodes.length - 1]);

  let total = 0;
  const distances = [0];
  for (let i = 1; i < points.length; i++) {
    total += distance(points[i - 1], points[i]);
    distances.push(total);
  }

  return { points, distances, totalLength: total };
}

// Finds the point at `targetDistance` along a path built by buildPath(),
// wrapping around so packets can loop indefinitely.
function pointAtDistance(path, targetDistance) {
  const { points, distances, totalLength } = path;
  const d = ((targetDistance % totalLength) + totalLength) % totalLength;

  let lo = 0;
  let hi = distances.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (distances[mid] < d) lo = mid + 1;
    else hi = mid;
  }
  const i = Math.max(lo, 1);
  const segmentT = (d - distances[i - 1]) / (distances[i] - distances[i - 1] || 1);
  const a = points[i - 1];
  const b = points[i];
  return { x: a.x + (b.x - a.x) * segmentT, y: a.y + (b.y - a.y) * segmentT };
}

// Analogous harmony (small hue offsets) rather than complementary — keeps
// every seed landing on a palette that reads as cohesive instead of clashing.
function derivePalette(random, seed) {
  const baseHue = seed % 360;
  const [minOffset, maxOffset] = CONFIG.hueHarmonyOffset;
  const spread = () => minOffset + random() * (maxOffset - minOffset);
  return {
    background: baseHue,
    route: (baseHue + spread()) % 360,
    node: (baseHue - spread() + 360) % 360,
    packet: (baseHue + spread() * (random() < 0.5 ? 1 : -1) + 360) % 360,
  };
}

function hsl(style, hue, alphaOverride) {
  const a = alphaOverride ?? style.a;
  return a === undefined ? `hsl(${hue}, ${style.s}%, ${style.l}%)` : `hsla(${hue}, ${style.s}%, ${style.l}%, ${a})`;
}

function tracePath(ctx, path, w, h) {
  ctx.beginPath();
  ctx.moveTo(path.points[0].x * w, path.points[0].y * h);
  for (let i = 1; i < path.points.length; i++) {
    ctx.lineTo(path.points[i].x * w, path.points[i].y * h);
  }
  ctx.stroke();
}

function drawNodes(ctx, nodes, color, w, h) {
  ctx.fillStyle = color;
  for (const node of nodes) {
    ctx.beginPath();
    ctx.arc(node.x * w, node.y * h, CONFIG.nodeRadius, 0, Math.PI * 2);
    ctx.fill();
  }
}

function drawPackets(ctx, path, packets, color, w, h) {
  ctx.fillStyle = color;
  ctx.shadowColor = color;
  ctx.shadowBlur = CONFIG.packetGlowBlur;
  for (const packet of packets) {
    const p = pointAtDistance(path, packet.offset * path.totalLength);
    ctx.beginPath();
    ctx.arc(p.x * w, p.y * h, CONFIG.packetRadius, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.shadowBlur = 0;
}

// Sizes the canvas backing store for the display's pixel density and scales
// the context to match, so all drawing after this uses CSS-pixel coordinates
// (the `w`/`h` values callers pass around) rather than device pixels.
function sizeCanvas(canvas, container) {
  const dpr = window.devicePixelRatio || 1;
  const rect = container.getBoundingClientRect();
  canvas.width = rect.width * dpr;
  canvas.height = rect.height * dpr;
  canvas.style.width = `${rect.width}px`;
  canvas.style.height = `${rect.height}px`;
  canvas.getContext("2d").setTransform(dpr, 0, 0, dpr, 0, 0);
  return { width: rect.width, height: rect.height };
}

function mountCanvas(container) {
  container.innerHTML = "";
  const canvas = document.createElement("canvas");
  container.appendChild(canvas);
  return canvas;
}

// renderDemo/renderOfflineState may each be called more than once (a later
// build load, a resize-driven remount), so any previous animation loop and
// listener needs tearing down first or they'd silently pile up.
function stopPreviousRender(container) {
  if (container.__waypointsCleanup) {
    container.__waypointsCleanup();
    container.__waypointsCleanup = null;
  }
}

function renderDemo(seed, container) {
  stopPreviousRender(container);
  container.setAttribute("aria-label", "Generative route, seeded from the deployed commit");

  const canvas = mountCanvas(container);
  const ctx = canvas.getContext("2d");
  let size = sizeCanvas(canvas, container);

  const random = mulberry32(seed);
  const nodeCount = Math.round(
    CONFIG.nodeCountRange[0] + random() * (CONFIG.nodeCountRange[1] - CONFIG.nodeCountRange[0])
  );
  const nodes = generateNodes(random, nodeCount);
  const path = buildPath(nodes);
  const palette = derivePalette(random, seed);
  const packets = Array.from({ length: CONFIG.packetCount }, (_, i) => ({
    offset: i / CONFIG.packetCount,
  }));

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function draw(dt) {
    const { width, height } = size;

    ctx.fillStyle = hsl(CONFIG.background, palette.background, CONFIG.trailFade);
    ctx.fillRect(0, 0, width, height);

    ctx.strokeStyle = hsl(CONFIG.route, palette.route);
    ctx.lineWidth = CONFIG.routeLineWidth;
    tracePath(ctx, path, width, height);

    drawNodes(ctx, nodes, hsl(CONFIG.node, palette.node), width, height);

    if (!reduceMotion) {
      for (const packet of packets) {
        packet.offset = (packet.offset + dt * CONFIG.packetSpeed) % 1;
      }
    }
    drawPackets(ctx, path, packets, hsl(CONFIG.packet, palette.packet), width, height);
  }

  const resizeHandler = () => {
    size = sizeCanvas(canvas, container);
    if (reduceMotion) draw(0);
  };
  window.addEventListener("resize", resizeHandler);

  if (reduceMotion) {
    draw(0);
    container.__waypointsCleanup = () => window.removeEventListener("resize", resizeHandler);
    return;
  }

  let raf = null;
  let lastTime = performance.now();
  function frame(now) {
    draw((now - lastTime) / 1000);
    lastTime = now;
    raf = requestAnimationFrame(frame);
  }
  raf = requestAnimationFrame(frame);

  container.__waypointsCleanup = () => {
    cancelAnimationFrame(raf);
    window.removeEventListener("resize", resizeHandler);
  };
}

// A static, desaturated version of the same route shape (fixed seed, so it's
// consistent rather than different on every failed load) with the path
// drawn dashed instead of solid and no packets moving. Broken infrastructure
// should look visibly broken, not just an empty box.
function renderOfflineState(container) {
  stopPreviousRender(container);
  container.setAttribute("aria-label", "Backend unreachable — route unavailable");

  const canvas = mountCanvas(container);
  const ctx = canvas.getContext("2d");
  const { width, height } = sizeCanvas(canvas, container);

  const random = mulberry32(0);
  const nodes = generateNodes(random, CONFIG.nodeCountRange[0]);
  const path = buildPath(nodes);

  ctx.fillStyle = "hsl(0, 0%, 8%)";
  ctx.fillRect(0, 0, width, height);

  ctx.setLineDash([6, 8]);
  ctx.strokeStyle = "hsla(0, 0%, 55%, 0.5)";
  ctx.lineWidth = CONFIG.routeLineWidth;
  tracePath(ctx, path, width, height);
  ctx.setLineDash([]);

  drawNodes(ctx, nodes, "hsl(0, 0%, 40%)", width, height);
}
