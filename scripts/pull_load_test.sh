#!/usr/bin/env bash
#
# Pull load test for local Quay (make local-dev-up).
# Mirrors quay-performance-scripts env vars and behavior for the pull phase.
# See: https://github.com/quay/quay-performance-scripts (deploy/test.job.yaml, RUN/PUSH_PULL phases)
#
# Prerequisites:
#   - Quay running, images already pushed (e.g. via push_100_layer_image.sh)
#   - docker login <QUAY_HOST>
#
# Env vars (same style as quay-performance-scripts):
#   QUAY_HOST     - Registry host (default: localhost:8080)
#   QUAY_ORG      - Org or user namespace (default: admin). Use with PULL_REPO_PREFIX.
#   PULL_REPO_PREFIX - Repo name without host (default: repo100). Full repo = QUAY_HOST/QUAY_ORG/PULL_REPO_PREFIX
#   LOAD_REPO     - Override: full repo as host/org/repo (e.g. localhost:8080/admin/repo100). Overrides QUAY_ORG + PULL_REPO_PREFIX.
#   START / END   - Tag range to pull (default START=1 END=5). Images pulled: :START through :END.
#   TARGET_HIT_SIZE  - Total number of pull operations (default: 0 = run forever until Ctrl+C).
#   CONCURRENCY   - Number of parallel pull workers (default: 2).
#   RATE          - Delay in seconds between starting each worker's next pull (default: 0).
#
# Usage:
#   # Pull 100 times total, 4 workers, from admin/repo100 tags 1-5
#   TARGET_HIT_SIZE=100 CONCURRENCY=4 START=1 END=5 QUAY_ORG=admin PULL_REPO_PREFIX=repo100 ./scripts/pull_load_test.sh
#
#   # Same using LOAD_REPO (like your push script)
#   TARGET_HIT_SIZE=100 CONCURRENCY=4 START=1 END=5 LOAD_REPO="localhost:8080/admin/repo100" ./scripts/pull_load_test.sh
#
#   # Run forever (Ctrl+C to stop)
#   CONCURRENCY=4 START=1 END=5 LOAD_REPO="localhost:8080/admin/repo100" ./scripts/pull_load_test.sh
#
set -e

QUAY_HOST="${QUAY_HOST:-localhost:8080}"
QUAY_ORG="${QUAY_ORG:-admin}"
PULL_REPO_PREFIX="${PULL_REPO_PREFIX:-repo100}"
START="${START:-1}"
END="${END:-5}"
TARGET_HIT_SIZE="${TARGET_HIT_SIZE:-0}"
CONCURRENCY="${CONCURRENCY:-2}"
RATE="${RATE:-0}"

if [[ -n "${LOAD_REPO}" ]]; then
  # LOAD_REPO = "localhost:8080/admin/repo100"
  REPO_FULL="${LOAD_REPO}"
else
  REPO_FULL="${QUAY_HOST}/${QUAY_ORG}/${PULL_REPO_PREFIX}"
fi

# Prefer docker
if command -v docker &>/dev/null; then
  ENGINE=docker
elif command -v podman &>/dev/null; then
  ENGINE=podman
else
  echo "Error: need docker or podman" >&2
  exit 1
fi

PIDS=()
STOP=0

cleanup() {
  STOP=1
  echo ""
  echo "Stopping $CONCURRENCY workers..."
  for pid in "${PIDS[@]}"; do kill -9 "$pid" 2>/dev/null; done
  wait 2>/dev/null || true
  exit 0
}
trap cleanup SIGINT SIGTERM

echo "Pull load test (quay-performance-scripts style)"
echo "  Repo: $REPO_FULL"
echo "  Tags: $START..$END"
echo "  Concurrency: $CONCURRENCY"
echo "  Target hits: ${TARGET_HIT_SIZE:-unlimited}"
echo "  Engine: $ENGINE"
echo ""

# Per-worker pull limit (when TARGET_HIT_SIZE > 0). Divide work so total ≈ TARGET_HIT_SIZE.
PER_WORKER=0
[[ $TARGET_HIT_SIZE -gt 0 ]] && PER_WORKER=$(( (TARGET_HIT_SIZE + CONCURRENCY - 1) / CONCURRENCY ))

worker() {
  local id=$1
  local limit=$2
  local count=0
  local tag
  while [[ $STOP -eq 0 ]]; do
    [[ $limit -gt 0 && $count -ge $limit ]] && break
    tag=$(( START + (count % (END - START + 1)) ))
    "$ENGINE" pull "${REPO_FULL}:${tag}" >/dev/null 2>&1 || true
    (( count++ )) || true
    [[ $RATE -gt 0 ]] && sleep "$RATE"
  done
}

if [[ $TARGET_HIT_SIZE -gt 0 ]]; then
  echo "Running $TARGET_HIT_SIZE pulls (may take a while for large images)..."
  START_TIME=$(date +%s)
  for ((i=1; i<=CONCURRENCY; i++)); do
    worker $i $PER_WORKER &
    PIDS+=($!)
  done
  wait 2>/dev/null || true
  END_TIME=$(date +%s)
  ELAPSED=$(( END_TIME - START_TIME ))
  echo "Completed ~$TARGET_HIT_SIZE pulls in ${ELAPSED}s (concurrency=$CONCURRENCY)"
  [[ $ELAPSED -gt 0 ]] && echo "Throughput: $(( TARGET_HIT_SIZE / ELAPSED )) pulls/sec"
else
  echo "Running until Ctrl+C..."
  for ((i=1; i<=CONCURRENCY; i++)); do
    ( worker $i 0 ) &
    PIDS+=($!)
  done
  wait
fi
