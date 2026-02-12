#!/usr/bin/env bash
#
# Run continuous pull load; Ctrl+C stops all workers cleanly.
# Usage: ./scripts/pull_load.sh [image] [workers]
# Example: ./scripts/pull_load.sh localhost:8080/admin/repo100:1 4
#
IMAGE="${1:-localhost:8080/admin/repo100:1}"
WORKERS="${2:-4}"
PIDS=()

cleanup() {
  echo "Stopping $WORKERS workers..."
  for pid in "${PIDS[@]}"; do kill -9 "$pid" 2>/dev/null; done
  exit 0
}
trap cleanup SIGINT SIGTERM

echo "Pull load: $IMAGE ($WORKERS workers). Ctrl+C to stop."
for ((i=1; i<=WORKERS; i++)); do
  ( while true; do docker pull "$IMAGE" >/dev/null 2>&1; done ) &
  PIDS+=($!)
done
wait
