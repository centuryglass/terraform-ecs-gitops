const POLL_INTERVAL_MS = 5000;

function seedFromSha(sha) {
  let hash = 0;
  for (let i = 0; i < sha.length; i++) {
    hash = (hash * 31 + sha.charCodeAt(i)) >>> 0;
  }
  return hash;
}

function formatUptime(totalSeconds) {
  const m = Math.floor(totalSeconds / 60);
  const s = totalSeconds % 60;
  return `${m}m ${s}s`;
}

function showError(message) {
  const banner = document.getElementById("error-banner");
  banner.textContent = message;
  banner.hidden = false;
}

function clearError() {
  document.getElementById("error-banner").hidden = true;
}

async function fetchJSON(path) {
  const res = await fetch(path);
  if (!res.ok) {
    throw new Error(`${path} returned ${res.status}`);
  }
  return res.json();
}

async function loadBuildInfo() {
  try {
    const build = await fetchJSON("/api/build");
    document.getElementById("build-sha").textContent = build.gitSha;
    document.getElementById("build-image-tag").textContent = build.imageTag;
    document.getElementById("build-time").textContent = build.buildTime;
    document.getElementById("build-go-version").textContent = build.goVersion;
    clearError();

    renderDemo(seedFromSha(build.gitSha), document.getElementById("demo-container"));
  } catch (err) {
    showError(
      `Backend unreachable — /api/build failed (${err.message}). ` +
      "The routing chain from the CDN edge through to the backend container isn't working."
    );
    renderOfflineState(document.getElementById("demo-container"));
  }
}

// Platform + fields are static for a container's lifetime, so only rebuild the
// injected rows when they actually change — which also means a rolling deploy
// (new Cloud Run revision / new Fargate task) visibly updates here as traffic
// shifts to the new container.
let lastFieldsKey = "";

function renderPlatformFields(platform, fields) {
  const key = platform + "|" + fields.map((f) => `${f.label}=${f.value}`).join(",");
  if (key === lastFieldsKey) return;
  lastFieldsKey = key;

  document.getElementById("runtime-platform").textContent = platform || "—";

  const list = document.getElementById("runtime-list");
  list.querySelectorAll(".runtime-field").forEach((n) => n.remove());

  const uptimeDt = document.getElementById("runtime-uptime-dt");
  for (const f of fields) {
    const dt = document.createElement("dt");
    dt.className = "runtime-field";
    dt.textContent = f.label;
    const dd = document.createElement("dd");
    dd.className = "runtime-field";
    dd.textContent = f.value || "—";
    list.insertBefore(dt, uptimeDt);
    list.insertBefore(dd, uptimeDt);
  }
}

async function pollRuntimeInfo() {
  try {
    const rt = await fetchJSON("/api/runtime");
    renderPlatformFields(rt.platform, rt.fields || []);
    document.getElementById("runtime-uptime").textContent = formatUptime(rt.uptimeSeconds);
    document.getElementById("runtime-request-count").textContent = rt.requestCount;
    clearError();
  } catch (err) {
    showError(`Backend unreachable — /api/runtime failed (${err.message}).`);
  }
}

loadBuildInfo();
pollRuntimeInfo();
setInterval(pollRuntimeInfo, POLL_INTERVAL_MS);
