#!/usr/bin/env bash
#
# Configure Podman to use HTTP (insecure) for local Quay at 127.0.0.1:8080.
# Run once: ./scripts/setup-podman-insecure-registry.sh
#
# Then: podman login 127.0.0.1:8080
#       ./scripts/push_100_layer_image.sh perftest/myrepo latest
#

set -e

CONFIG_DIR="${HOME}/.config/containers"
CONFIG_FILE="${CONFIG_DIR}/registries.conf"
REGISTRY="127.0.0.1:8080"

mkdir -p "$CONFIG_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
  if grep -q "location.*${REGISTRY}" "$CONFIG_FILE" 2>/dev/null; then
    echo "Registry ${REGISTRY} already configured in ${CONFIG_FILE}"
    exit 0
  fi
  echo "Appending insecure registry to existing ${CONFIG_FILE}"
  {
    echo ""
    echo "# Local Quay (HTTP)"
    echo "[[registry]]"
    echo "location = \"${REGISTRY}\""
    echo "insecure = true"
  } >> "$CONFIG_FILE"
else
  echo "Creating ${CONFIG_FILE} with insecure registry for ${REGISTRY}"
  cat > "$CONFIG_FILE" << EOF
# Use HTTP for local Quay (make local-dev-up)
[[registry]]
location = "${REGISTRY}"
insecure = true
EOF
fi

echo "Done. Run: podman login ${REGISTRY}"
echo "Then: ./scripts/push_100_layer_image.sh perftest/myrepo latest"
