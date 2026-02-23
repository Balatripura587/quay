#!/usr/bin/env bash
#
# Generate pull load against a Quay/registry v2 API without writing to disk.
# Uses curl to GET manifests and blobs, streaming to /dev/null (no disk I/O).
# Compatible with quay-performance-scripts style env vars (LOAD_REPO, START, END).
#
# Prerequisites:
#   1. Quay running (e.g. make local-dev-up)
#   2. Images already pushed to LOAD_REPO (e.g. via push_100_layer_image.sh)
#   3. QUAY_USER / QUAY_PASS for auth (for local dev: admin / password, or use token)
#
# Usage (env vars, like performance-scripts):
#   LOAD_REPO="localhost:8080/admin/my-repo" START=1 END=20 ./scripts/pull_load.sh
#
# Usage (positional, single tag):
#   ./scripts/pull_load.sh [ORG/REPO] [TAG]
#
# Env vars:
#   LOAD_REPO   - Full repo (host/org/repo), e.g. localhost:8080/admin/my-repo
#   START       - First tag index (default: 1)
#   END         - Last tag index inclusive (default: 1). Tags :1 .. :N
#   QUAY_USER   - Registry user (default: admin for local)
#   QUAY_PASS   - Registry password or token
#   CONCURRENCY - Parallel workers (default: 1). Each worker loops over tags.
#   ITERATIONS  - How many full cycles over START..END per worker (default: 1)
#   RATE        - Delay in seconds between pulls within a worker (default: 0)
#   MANIFEST_ONLY - If set (e.g. 1), only fetch manifests (no blobs); lighter load
#   VERBOSE     - 1 (default): print per-tag progress; 0: quiet
#   QUAY_HOST   - Override registry host when using LOAD_REPO
#

set -e

# --- Resolve LOAD_REPO vs positional args ---
if [[ -n "${LOAD_REPO}" ]]; then
  QUAY_HOST="${QUAY_HOST:-${LOAD_REPO%%/*}}"
  REPO_PATH="${LOAD_REPO#*/}"
  START="${START:-1}"
  END="${END:-1}"
  MULTI_TAG=1
else
  QUAY_HOST="${QUAY_HOST:-localhost:8080}"
  REPO_PATH="${1:-admin/my-repo}"
  SINGLE_TAG="${2:-latest}"
  START=1
  END=1
  MULTI_TAG=0
fi

QUAY_USER="${QUAY_USER:-admin}"
QUAY_PASS="${QUAY_PASS:-}"
CONCURRENCY="${CONCURRENCY:-1}"
ITERATIONS="${ITERATIONS:-1}"
RATE="${RATE:-0}"
MANIFEST_ONLY="${MANIFEST_ONLY:-0}"
VERBOSE="${VERBOSE:-1}"

BASE_URL="http://${QUAY_HOST}/v2/${REPO_PATH}"
AUTH_HEADER=""

# Check registry reachable
HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://${QUAY_HOST}/v2/" 2>/dev/null)" || true
if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "401" ]]; then
  echo "Error: Cannot reach registry at http://${QUAY_HOST}/v2/ (got: ${HTTP_CODE:-connection failed})" >&2
  exit 1
fi

# Obtain Bearer token if we have credentials (handles 401 + Www-Authenticate)
_get_token() {
  local scope="repository:${REPO_PATH}:pull"
  local token
  if [[ -n "$QUAY_PASS" ]]; then
    # Use -G and --data-urlencode; keep body and http_code separate for reliable parsing
    local auth_body auth_code
    auth_body=$(mktemp)
    auth_code=$(curl -s -o "$auth_body" -w "%{http_code}" -u "${QUAY_USER}:${QUAY_PASS}" \
      -G "http://${QUAY_HOST}/v2/auth" \
      --data-urlencode "service=${QUAY_HOST}" \
      --data-urlencode "scope=${scope}" 2>/dev/null) || true
    if [[ "$auth_code" == "200" ]]; then
      if command -v jq &>/dev/null; then
        token=$(jq -r '.token // empty' "$auth_body" 2>/dev/null)
      else
        token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$auth_body")
      fi
    fi
    rm -f "$auth_body"
  fi
  if [[ -n "$token" ]]; then
    echo "Bearer $token"
  else
    echo ""
  fi
}

# Fetch manifest for tag, output to file. Returns 0 on success. On failure prints HTTP code to stderr.
_fetch_manifest() {
  local tag="$1"
  local out="${2:-/dev/null}"
  local url="${BASE_URL}/manifests/${tag}"
  local code
  local curl_opts=(-s -o "$out" -w "%{http_code}" -L
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json"
    -H "Accept: application/vnd.oci.image.manifest.v1+json"
    -H "Accept: application/vnd.oci.image.index.v1+json"
    "$url")
  if [[ -n "$AUTH_HEADER" ]]; then
    code=$(curl "${curl_opts[@]}" -H "Authorization: $AUTH_HEADER")
  else
    code=$(curl "${curl_opts[@]}")
  fi
  # curl -w prints code after body; we need code only (body went to $out)
  if [[ "$out" != "/dev/null" ]]; then
    : # body already in file
  fi
  if [[ "$code" != "200" ]]; then
    echo "  HTTP $code" >&2
    return 1
  fi
  return 0
}

# Fetch blob by digest to /dev/null (no disk write).
# Uses curl -f so 4xx/5xx (e.g. 401, 404) cause non-zero exit; we do not ignore failures
# (aligned with quay-performance-scripts main.py raise_for_status() on blob GET).
_fetch_blob() {
  local digest="$1"
  local url="${BASE_URL}/blobs/${digest}"
  if [[ -n "$AUTH_HEADER" ]]; then
    curl -s -f -o /dev/null -H "Authorization: $AUTH_HEADER" "$url"
  else
    curl -s -f -o /dev/null "$url"
  fi
}

# Extract blob digests from manifest JSON (config + layers only). Requires manifest on stdin or in file.
# Handles both single-line and pretty-printed JSON. Use only on an image manifest, not on a manifest list (index).
_extract_digests() {
  local file="${1:--}"
  # Match "digest": "sha256:..." (same line)
  local out
  out=$(grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[a-f0-9]+"' "$file" 2>/dev/null | sed 's/.*"sha256:/sha256:/;s/".*//' || true)
  if [[ -z "$out" ]]; then
    # Pretty-printed: collapse newlines and try again
    out=$(tr '\n' ' ' < "$file" 2>/dev/null | grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[a-f0-9]+"' | sed 's/.*"sha256:/sha256:/;s/".*//' || true)
  fi
  echo "$out"
}

# Detect if manifest file is an OCI/Docker manifest list (index). Index lists child *manifest* digests;
# GET /blobs/<manifest-digest> returns 404 (BlobUnknown) because manifest bytes are not repo blobs.
# Returns 0 if index, 1 if single image manifest.
_is_manifest_index() {
  local file="$1"
  grep -q '"manifests"' "$file" 2>/dev/null && ! grep -q '"config"' "$file" 2>/dev/null
}

# Get first child manifest digest from an index (for resolving to image manifest).
_get_first_manifest_digest_from_index() {
  local file="$1"
  grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[a-f0-9]+"' "$file" 2>/dev/null | head -1 | sed 's/.*"sha256:/sha256:/;s/".*//'
}

# Fetch manifest by digest (for resolving index -> image manifest). Writes to file. Returns 0 on success.
_fetch_manifest_by_digest() {
  local digest="$1"
  local out="${2:-/dev/null}"
  local url="${BASE_URL}/manifests/${digest}"
  local code
  # Prefer image manifest types so we get config + layers, not another index
  local curl_opts=(-s -o "$out" -w "%{http_code}" -L
    -H "Accept: application/vnd.oci.image.manifest.v1+json"
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json"
    -H "Accept: application/vnd.oci.image.index.v1+json"
    "$url")
  if [[ -n "$AUTH_HEADER" ]]; then
    code=$(curl "${curl_opts[@]}" -H "Authorization: $AUTH_HEADER")
  else
    code=$(curl "${curl_opts[@]}")
  fi
  if [[ "$code" != "200" ]]; then
    return 1
  fi
  return 0
}

# One full "pull" (manifest + all blobs to /dev/null) for one tag
_pull_one_tag() {
  local tag="$1"
  local manifest_file
  manifest_file=$(mktemp)
  if ! _fetch_manifest "$tag" "$manifest_file"; then
    rm -f "$manifest_file"
    return 1
  fi

  if [[ "$MANIFEST_ONLY" == "1" ]]; then
    rm -f "$manifest_file"
    return 0
  fi

  local digests
  # If the server returned a manifest list (index), digests in it are child *manifest* digests, not
  # blob digests; GET /blobs/<those> returns 404. Resolve to the image manifest and use its config + layers.
  if _is_manifest_index "$manifest_file"; then
    local first_digest
    first_digest=$(_get_first_manifest_digest_from_index "$manifest_file")
    if [[ -n "$first_digest" ]]; then
      local image_manifest_file
      image_manifest_file=$(mktemp)
      if _fetch_manifest_by_digest "$first_digest" "$image_manifest_file"; then
        digests=($(_extract_digests "$image_manifest_file"))
        rm -f "$image_manifest_file"
      else
        [[ "$VERBOSE" == "1" ]] && echo "  [warning] tag $tag: could not fetch image manifest $first_digest" >&2
        rm -f "$image_manifest_file"
      fi
    fi
  else
    digests=($(_extract_digests "$manifest_file"))
  fi

  [[ "$VERBOSE" == "1" && "${#digests[@]}" -eq 0 ]] && echo "  [warning] tag $tag: no blob digests in manifest" >&2
  [[ "$VERBOSE" == "1" && "${#digests[@]}" -gt 0 ]] && echo "  [tag $tag] fetching ${#digests[@]} blobs" >&2

  for digest in "${digests[@]}"; do
    [[ -z "$digest" ]] && continue
    _fetch_blob "$digest"
  done
  rm -f "$manifest_file"
}

# Worker: run ITERATIONS cycles over tags START..END
_worker() {
  local worker_id="$1"
  local iter t tag ok
  for (( iter=1; iter<=ITERATIONS; iter++ )); do
    for (( t=START; t<=END; t++ )); do
      if [[ "$MULTI_TAG" -eq 1 ]]; then
        tag="$t"
      else
        tag="$SINGLE_TAG"
      fi
      if [[ "$VERBOSE" == "1" ]]; then
        echo "  [worker $worker_id] tag $tag ..." >&2
      fi
      if _pull_one_tag "$tag"; then
        [[ "$VERBOSE" == "1" ]] && echo "  [worker $worker_id] tag $tag OK" >&2
      else
        echo "  [worker $worker_id] tag $tag FAILED" >&2
      fi
      [[ "$RATE" != "0" && "$RATE" != "0.0" ]] && sleep "$RATE"
    done
  done
}

# --- Main ---
# Get token once (reused by all workers)
AUTH_HEADER=$(_get_token)
if [[ -n "$QUAY_PASS" && -z "$AUTH_HEADER" ]]; then
  echo "Warning: Could not get registry token (check QUAY_USER/QUAY_PASS). Trying without auth." >&2
fi

export BASE_URL AUTH_HEADER REPO_PATH QUAY_HOST QUAY_USER QUAY_PASS
export MANIFEST_ONLY VERBOSE
export -f _fetch_manifest _fetch_blob _extract_digests _pull_one_tag _worker \
  _is_manifest_index _get_first_manifest_digest_from_index _fetch_manifest_by_digest

if [[ "$MULTI_TAG" -eq 1 ]]; then
  echo "Pull load: repo ${QUAY_HOST}/${REPO_PATH}, tags ${START}..${END}, concurrency ${CONCURRENCY}, iterations ${ITERATIONS}"
else
  echo "Pull load: repo ${QUAY_HOST}/${REPO_PATH}, tag ${SINGLE_TAG}, concurrency ${CONCURRENCY}, iterations ${ITERATIONS}"
fi
[[ "$MANIFEST_ONLY" == "1" ]] && echo "Manifest-only mode (no blobs)."
echo ""

# Run workers: foreground when CONCURRENCY=1 (no subshell/export issues), else background
if [[ "$CONCURRENCY" -eq 1 ]]; then
  _worker 1
else
  for (( w=1; w<=CONCURRENCY; w++ )); do
    _worker "$w" &
  done
  wait
fi
echo "Done."