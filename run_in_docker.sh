#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="openusage-benchmark"
VOLUME="claude-benchmark-auth"

# Build image (uses cache, fast if no changes)
echo "Building image..."
docker build -t "$IMAGE" "$SCRIPT_DIR" --quiet

# Check volume exists (user must have run docker-login.sh first)
if ! docker volume inspect "$VOLUME" &>/dev/null; then
  echo "ERROR: Auth volume '$VOLUME' not found."
  echo "Run './docker-login.sh' first to authenticate."
  exit 1
fi

# Ensure results dir exists on the host before mounting
mkdir -p "$SCRIPT_DIR/results"

echo "Starting benchmark in isolated container..."
echo "(No global CLAUDE.md, no hooks, alwaysThinkingEnabled=false)"
echo ""

docker run --rm \
  -v "$VOLUME:/root/.claude" \
  -v "$SCRIPT_DIR/results:/benchmark/results" \
  -v "$SCRIPT_DIR/cached_claude_md.md:/benchmark/cached_claude_md.md" \
  "$IMAGE" \
  "$@"
