// Placeholder pending the creative pass (docs/APP-SPEC.md §6). Proves the
// seed pipeline works end to end — swap the body of this function for the
// real piece without touching app.js or index.html.
function renderDemo(seed, container) {
  const hue = seed % 360;
  container.style.background = `hsl(${hue}, 55%, 45%)`;
  container.textContent = `seed ${seed}`;
}
