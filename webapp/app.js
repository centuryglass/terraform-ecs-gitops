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
      "The routing chain from CloudFront through to the ECS task isn't working."
    );
    renderOfflineState(document.getElementById("demo-container"));
  }
}

async function pollRuntimeInfo() {
  try {
    const rt = await fetchJSON("/api/runtime");
    document.getElementById("runtime-task-id").textContent = rt.taskId || "n/a (local)";
    document.getElementById("runtime-az").textContent = rt.availabilityZone || "n/a (local)";
    document.getElementById("runtime-hostname").textContent = rt.hostname;
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
