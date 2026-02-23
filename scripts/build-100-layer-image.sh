#!/usr/bin/env bash
# Build a Docker image with 100 layers for testing blob download profiling.
# Usage: ./scripts/build-100-layer-image.sh [repo:tag]
# Default: localhost:8080/admin/repo100:100layers

set -e
REPO_TAG="${1:-localhost:8080/admin/repo100:100layers}"
DIR=$(mktemp -d)
trap "rm -rf $DIR" EXIT

echo "FROM alpine:3.18" > "$DIR/Dockerfile"
for i in $(seq 1 100); do
  echo "RUN echo $i > /layer$i" >> "$DIR/Dockerfile"
done

echo "Building 100-layer image: $REPO_TAG"
docker build -t "$REPO_TAG" "$DIR"
echo "Built. Push with: docker push $REPO_TAG"
