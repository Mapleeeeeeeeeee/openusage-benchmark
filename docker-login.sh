#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="openusage-benchmark"
VOLUME="claude-benchmark-auth"

echo "=== Claude Code Docker Login ==="
echo ""
echo "This sets up authentication in a persistent Docker volume."
echo "Claude Code will display a URL — open it in your Mac browser to authenticate."
echo ""
echo "Inside the container, run:  claude"
echo "Then copy the URL shown and open it in your Mac browser to complete OAuth."
echo "Once authenticated, type 'exit' to leave the container."
echo ""

# Build image if needed (or pass --build to force rebuild)
if [[ "${1:-}" == "--build" ]] || ! docker image inspect "$IMAGE" &>/dev/null; then
  echo "Building image..."
  docker build -t "$IMAGE" "$SCRIPT_DIR" --quiet
fi

# Drop into an interactive bash shell so the user can run `claude` themselves.
# --entrypoint bash overrides the benchmark ENTRYPOINT to skip the auth check.
docker run -it --rm \
  -v "$VOLUME:/root/.claude" \
  --entrypoint bash \
  "$IMAGE"

echo ""
echo "Login complete. Credentials saved to volume '$VOLUME'."
echo "You can now run: ./run_in_docker.sh"
