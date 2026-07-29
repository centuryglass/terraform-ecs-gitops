#!/usr/bin/env bash
#
# localtest.sh — one command to see Waypoint running locally.
#
# Builds the Go backend, serves the backend + static frontend on a single
# origin (an http-server proxy forwarding /api/* to the backend, so the
# frontend's relative fetches resolve exactly like they do behind CloudFront /
# Firebase Hosting), opens it in a browser, and tears everything down cleanly
# on Ctrl+C.
#
# Usage:
#   scripts/localtest.sh [local|aws|gcp]
#
# The optional argument fakes the platform the backend believes it's on, so you
# can preview each RUNTIME layout. Cloud metadata servers aren't reachable off
# their platform, so `aws`/`gcp` show only the env-derived rows (gcp: Service /
# Revision; aws: Hostname) — Region / Task ID / Instance ID populate only when
# actually deployed there.
#
# Env overrides: BACKEND_PORT (default 8080), FRONTEND_PORT (default 8000).

set -euo pipefail

PLATFORM="${1:-local}"
BACKEND_PORT="${BACKEND_PORT:-8080}"
FRONTEND_PORT="${FRONTEND_PORT:-8000}"

for cmd in go npx curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: required command '$cmd' not found" >&2; exit 1; }
done

REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "error: not inside a git repository" >&2; exit 1; }
cd "$REPO_ROOT"

# Per-platform env for the backend process (see the header note).
backend_env=(PORT="$BACKEND_PORT")
case "$PLATFORM" in
  local) ;;
  gcp)   backend_env+=(K_SERVICE=waypoint-local K_REVISION=waypoint-local-00001-dev) ;;
  aws)   backend_env+=(ECS_CONTAINER_METADATA_URI_V4=http://169.254.170.2/v4/localtest) ;;
  *)     echo "usage: ${0##*/} [local|aws|gcp]" >&2; exit 1 ;;
esac

run_dir="$(mktemp -d)"
bin="$run_dir/waypoint"
backend_log="$run_dir/backend.log"
frontend_log="$run_dir/frontend.log"
backend_pid=""
frontend_pid=""

cleanup() {
  local code=$?
  trap - INT TERM EXIT
  echo
  echo "Shutting down..."
  # http-server runs under npx, so kill its children too before the wrapper.
  [ -n "$frontend_pid" ] && { pkill -P "$frontend_pid" 2>/dev/null || true; kill "$frontend_pid" 2>/dev/null || true; }
  [ -n "$backend_pid" ] && kill "$backend_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$run_dir"
  echo "Done."
  # exit here so a Ctrl+C doesn't fall back through to the "unexpected" message.
  exit "$code"
}
trap cleanup INT TERM EXIT

# wait_up NAME URL PID LOG — poll URL until it answers, or fail if PID dies.
wait_up() {
  local name=$1 url=$2 pid=$3 log=$4
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "error: $name exited during startup. Log:" >&2
      cat "$log" >&2
      return 1
    fi
    curl -sf -o /dev/null "$url" && return 0
    sleep 0.2
  done
  echo "error: $name did not become ready at $url. Log:" >&2
  cat "$log" >&2
  return 1
}

echo "Building backend..."
( cd app && go build -o "$bin" . )

echo "Starting backend (platform=$PLATFORM) on :$BACKEND_PORT ..."
( exec env "${backend_env[@]}" "$bin" ) >"$backend_log" 2>&1 &
backend_pid=$!

echo "Starting frontend proxy on :$FRONTEND_PORT ..."
( cd webapp && exec npx --yes http-server -p "$FRONTEND_PORT" -c-1 --proxy "http://localhost:$BACKEND_PORT" ) >"$frontend_log" 2>&1 &
frontend_pid=$!

url="http://localhost:$FRONTEND_PORT/"
wait_up "backend" "http://localhost:$BACKEND_PORT/healthz" "$backend_pid" "$backend_log"
wait_up "frontend" "$url" "$frontend_pid" "$frontend_log"

echo "Opening $url"
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$url" >/dev/null 2>&1 &
elif command -v open >/dev/null 2>&1; then
  open "$url" >/dev/null 2>&1 &
else
  echo "  (couldn't find a browser opener — open the URL above manually)"
fi

cat <<EOF

  Waypoint is running:
    Frontend : $url
    Backend  : http://localhost:$BACKEND_PORT   (platform=$PLATFORM)
    Logs     : $backend_log
               $frontend_log

  Press Ctrl+C to stop.
EOF

# Stay up until Ctrl+C, or exit early if either service dies.
while kill -0 "$backend_pid" 2>/dev/null && kill -0 "$frontend_pid" 2>/dev/null; do
  sleep 1
done
echo "A service stopped unexpectedly — see the logs above." >&2
