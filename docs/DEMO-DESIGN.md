# Demo Design

This is the creative brief for `webapp/demo.js` — the visual required by
`docs/APP-SPEC.md` §6 and motivated by `docs/PRIORITIES.md` priority 3. That
document already covers the constraints; this one is the actual design
thinking, so I'm not re-deriving them here beyond a one-line recap:

Seed deterministically from the deployed commit SHA. Keep the call site small
even if a vendored library is large. Coexist with the pipeline panel rather
than replace it — the animation needs to still be visibly running while
uptime/request-count/task-ID tick over on their own poll cycle. If the
backend is unreachable, say so plainly instead of quietly rendering something
that looks fine.

The current `demo.js` (a flat hue panel keyed off the seed) is a placeholder
that exists only to prove the pipeline works. This document is the plan to
replace it with something worth looking at.

---

## The idea I'm recommending: *Waypoints*

A small constellation of nodes, connected by a curved route, with bright
points of light continuously traveling along it — like a transit map that
never stops running.

**Why this idea specifically, not just "a nice generative piece":** the
repository's actual subject is a routed path — CloudFront to ALB to a task,
traffic moving through hops that either work or don't. A route map with
traffic flowing across it isn't decoration bolted onto the pipeline panel; it
is the pipeline panel, restated as a diagram instead of a table. `§6` already
makes this move once — the seed proves the routing chain is intact the same
way `/api/runtime` does. A visual that's *literally a small route* pushes
that idea one step further instead of sitting next to it as an unrelated
centerpiece. And it gives the app's name somewhere to land: it isn't called
Waypoint because the word sounded good.

**Concrete shape of it:**

- From the seed, derive a node count (roughly 6–10) and place them with a
  seeded random walk across the canvas rather than a uniform scatter — a walk
  produces a path that already reads as a route before any line is drawn,
  where scattered points read as noise.
- Connect the nodes in sequence with smooth curves (quadratic/Catmull-Rom
  through each point, not straight segments — straight segments read as a
  wireframe, curves read as a route).
- A handful of bright points ("packets") travel along the full path on a
  loop, at a seeded speed and spacing. This is the part that has to never
  stop moving — it's the visual evidence, next to the polling pipeline panel,
  that something is alive right now, not a static image that happened to be
  generated once at build time.
- Palette: a base hue from the seed plus one or two harmonics (analogous or
  split-complementary, chosen deterministically from the same seed) rather
  than a single flat color — the current placeholder's single-hue background
  is exactly what this should stop looking like.
- Subtle background drift (low-amplitude noise-driven particles or a soft
  gradient wash) for atmosphere, kept faint enough that the route stays the
  clear subject.

**On failure:** right now `app.js` only calls `renderDemo` on a successful
`/api/build`, and otherwise leaves the container an empty box — that's not
actually "saying so plainly," it's just silently blank. Plan: give the
container an explicit broken-route state for this case — e.g. the same node
layout rendered once, statically, in a single desaturated color with the
connecting path drawn dashed/interrupted instead of solid, no packets moving.
Broken infrastructure should look visibly broken, not absent.

---

## Other directions I considered

Presented with real detail, not just discarded one-liners, since the point
of a brainstorm is to make the rejection reasons visible too.

### A. Raymarched solid (Three.js)
A slowly rotating SDF blob — geometry, subdivision, material, and palette
derived from the seed, rendered via a fragment shader in a single template
literal. This is the most visually impressive option per unit of code, and
Three.js is the library `§6` name-drops first. I'd pick this over *Waypoints*
if the goal were "most striking single object," but it's generic in a way
*Waypoints* isn't — a rotating seeded blob doesn't say anything about *this*
repository specifically, it would look the same bolted onto any other
project's fixture page. Worth keeping in mind as the fallback if *Waypoints*
turns out to read as too subtle once it's actually on screen.

### B. Flow field / reaction-diffusion (p5.js)
Particles drifting through a Perlin noise field, or a reaction-diffusion
texture evolving over time. This is the most stylistically native fit for
the "Are We Art Yet?" / creative-coding lineage `docs/PRIORITIES.md` names —
p5.js is closer to that community's own toolkit than Three.js or raw canvas
are. I still didn't pick it, because a flow field is abstract in a way that
doesn't connect back to the app's subject the way a route does — it's a
beautiful field with no reason to be *this* app's field. If the route-map
idea reads as too literal once built, this is the direction I'd pivot to
first, and it would compose reasonably well with the *Waypoints* node
placement — noise-driven drift as the background texture, nodes and packets
layered on top, is a plausible hybrid rather than an either/or.

### C. Physics settling scene (Matter.js)
A small rigid-body assembly — nodes as circles, routes as constraint links —
dropped and left to settle into a stable arrangement, seeded per deploy. The
spec calls out "motion that resolves rather than loops" as unusual and worth
doing. It's thematically close to *Waypoints* (still nodes and connections)
but Matter.js is the heaviest dependency of the options here for what it
actually buys, and a scene that finishes settling and then sits still works
against the "still visibly alive" requirement once the physics stops —
it would need an artificial reason to keep moving (periodic jostles), which
starts to feel bolted on rather than motivated.

### D. Plain-canvas demoscene effect (tunnel, plasma, starfield)
Classic effects, no library at all, genuinely striking in forty lines per the
spec's own pitch. I like this register a lot, but a tunnel or starfield is
generic in the same way option A is — it's a great demoscene effect, not a
statement about routing or waypoints specifically. Where this idea survives:
*Waypoints* itself doesn't actually need a vendored library (see below), so
in a sense this direction won.

---

## Implementation plan

**Library: none.** *Waypoints* is 2D vector graphics, a seeded PRNG, and
optionally a cheap noise function for the background drift — none of that
needs Three.js/p5.js/Matter.js. Skipping the vendored library sidesteps a
whole decision (which library, which version, licensing, pinning) and keeps
`webapp/` a flat set of files with nothing to `vendor/`. This is a deliberate
choice, not the default — if the on-screen result reads as flat or the
background texture wants real Perlin noise, p5.js (option B) is the
documented fallback and the node/packet logic mostly carries over.

**Determinism:** `Math.random()` isn't seedable, so `demo.js` needs its own
tiny PRNG (mulberry32 or splitmix32, ~5 lines) initialized from the numeric
seed `app.js` already computes from the commit SHA. Every node position,
palette choice, and packet speed is drawn from that single seeded stream, in
a fixed order, so the same commit always produces the same route.

**Loop structure:**
1. Seed the PRNG.
2. Generate node positions via seeded random walk.
3. Build the smooth path through them (cache the curve, don't recompute per
   frame).
4. Derive the palette (base hue + harmonics) from the seed.
5. `requestAnimationFrame` loop: advance each packet's position along the
   cached path by seeded speed, redraw background wash + path + nodes +
   packets each frame.
6. Respect `prefers-reduced-motion`: freeze packets in place (still show the
   route, just not animated) rather than ignoring the setting entirely —
   cheap to add, and it's the kind of detail worth having in a portfolio
   piece.

**Contract stays the same as the current stub:** one entry point,
`renderDemo(seed, container)`, called from `app.js` exactly as it is today.
The failure-state rendering (dashed/interrupted route) needs a second small
export or a sentinel argument — `app.js` will need a one-line change to call
it on the `/api/build` failure path instead of leaving the container empty.

**Rough sequence:**
1. PRNG + seeded node/path generation, static render (no animation yet) —
   confirms the layout looks right and is stable across reloads for the same
   seed.
2. Palette derivation, replace the placeholder's flat-hue background.
3. Packet animation loop.
4. Failure state.
5. `prefers-reduced-motion` handling.
6. Cross-check at a few different seed values (different commit SHAs) to
   make sure the range of generated layouts stays visually coherent — no
   seed should produce an empty or degenerate-looking route.

---

## Open questions before I start building

- Does the route-map metaphor actually land, or would it read as too subtle
  / too much like a generic node graph once it's on screen? I'm confident in
  the reasoning; I haven't seen it rendered yet.
- Any palette preference (warm/cool bias, dark background vs. light), or
  should the palette itself stay fully seed-derived with no fixed anchor?
- Packet count/speed — subtle background detail, or something bold enough to
  draw the eye first? Changes how loud the rest of the panel should be.
