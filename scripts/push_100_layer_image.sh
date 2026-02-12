#!/usr/bin/env bash
#
# Push image(s) with N layers to local Quay (make local-dev-up).
# Compatible with quay-performance-scripts style env vars (START, END, LAYERS, LOAD_REPO, IMAGES).
#
# Prerequisites:
#   1. Quay running: make local-dev-up
#   2. Login: docker login localhost:8080  (use same host as in LOAD_REPO)
#   3. Insecure registry: add that host to Docker daemon.json / Podman registries.conf
#
# Usage (positional, single image):
#   ./scripts/push_100_layer_image.sh [ORG/REPO] [TAG]
#   Example: ./scripts/push_100_layer_image.sh admin/100layer-test latest
#
# Usage (env vars, like performance-scripts — multiple images):
#   START=1 END=2 LAYERS=5 LOAD_REPO="localhost:8080/perftest/my-repo" \
#   IMAGES="quay.io/clair-load-test/mysql:8.0.25" \
#   ./scripts/push_100_layer_image.sh
#
# Env vars:
#   LOAD_REPO   - Full repo (host/org/repo), e.g. localhost:8080/perftest/my-repo
#   START       - First image index (default: 1)
#   END         - Last image index inclusive (default: 1). With START=1 END=2, pushes 2 images tagged :1 and :2
#   LAYERS      - Number of layers per image (default: 100)
#   IMAGES      - Base image for FROM (default: alpine:3.19), e.g. quay.io/clair-load-test/mysql:8.0.25
#   RATE        - Optional delay in seconds between image pushes (default: 0)
#   QUAY_HOST   - Override registry host (used only if LOAD_REPO not set)
#

set -e

# Prefer docker; else podman
if command -v docker &>/dev/null; then
  ENGINE=docker
elif command -v podman &>/dev/null; then
  ENGINE=podman
else
  echo "Error: need docker or podman in PATH" >&2
  exit 1
fi

# --- Resolve LOAD_REPO vs positional args ---
if [[ -n "${LOAD_REPO}" ]]; then
  # LOAD_REPO = "localhost:8080/perftest/my-repo" -> QUAY_HOST + REPO_PATH
  QUAY_HOST="${QUAY_HOST:-${LOAD_REPO%%/*}}"
  REPO_PATH="${LOAD_REPO#*/}"
  START="${START:-1}"
  END="${END:-1}"
  NUM_LAYERS="${LAYERS:-100}"
  BASE_IMAGE="${IMAGES:-alpine:3.19}"
  RATE="${RATE:-0}"
  MULTI_IMAGE=1
else
  QUAY_HOST="${QUAY_HOST:-localhost:8080}"
  REPO_PATH="${1:-admin/100layer-test}"
  SINGLE_TAG="${2:-latest}"
  START=1
  END=1
  NUM_LAYERS="${NUM_LAYERS:-${LAYERS:-100}}"
  BASE_IMAGE="${IMAGES:-alpine:3.19}"
  RATE=0
  MULTI_IMAGE=0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Check registry reachable
HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${QUAY_HOST}/v2/" 2>/dev/null)" || true
if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "401" ]]; then
  echo "Error: Cannot reach Quay at http://${QUAY_HOST}/v2/ (got: ${HTTP_CODE:-connection failed})" >&2
  echo "  - Ensure Quay is running: make local-dev-up" >&2
  exit 1
fi

# Generate Dockerfile (same for all images in this run)
{
  echo "FROM ${BASE_IMAGE}"
  for i in $(seq 1 "$NUM_LAYERS"); do
    echo "RUN echo layer-$i > /layer_${i}"
  done
  echo "CMD [\"sh\"]"
} > "${BUILD_DIR}/Dockerfile"

echo "Config: ${NUM_LAYERS} layers, base ${BASE_IMAGE}, repo ${QUAY_HOST}/${REPO_PATH}, images ${START}..${END}"
echo "Engine: ${ENGINE}"
echo ""

for idx in $(seq "$START" "$END"); do
  if [[ "$MULTI_IMAGE" -eq 1 ]]; then
    TAG="${idx}"
  else
    TAG="${SINGLE_TAG}"
  fi
  FULL_IMAGE="${QUAY_HOST}/${REPO_PATH}:${TAG}"
  echo "--- Image ${idx}/${END} (tag ${TAG}): ${FULL_IMAGE} ---"
  echo "Building..."
  "$ENGINE" build -t "$FULL_IMAGE" -f "${BUILD_DIR}/Dockerfile" "${BUILD_DIR}" --quiet 2>/dev/null || \
  "$ENGINE" build -t "$FULL_IMAGE" -f "${BUILD_DIR}/Dockerfile" "${BUILD_DIR}"
  echo "Pushing..."
  "$ENGINE" push "$FULL_IMAGE"
  echo "Pushed: ${FULL_IMAGE}"
  if [[ "$idx" -lt "$END" && "$RATE" -gt 0 ]]; then
    echo "Waiting ${RATE}s (RATE)..."
    sleep "$RATE"
  fi
  echo ""
done

if [[ "$MULTI_IMAGE" -eq 1 ]]; then
  echo "Done. Pushed images ${START}..${END} to ${QUAY_HOST}/${REPO_PATH} (tags: ${START} to ${END})"
else
  echo "Done. Pushed ${QUAY_HOST}/${REPO_PATH}:${SINGLE_TAG}"
  echo "Verify: $ENGINE pull ${QUAY_HOST}/${REPO_PATH}:${SINGLE_TAG}"
fi
