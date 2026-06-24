#!/usr/bin/env bash
set -euo pipefail

CLAUDE_DIR="/root/.claude"

# ── Auth check ─────────────────────────────────────────────────────────────
if [[ ! -d "$CLAUDE_DIR" ]] || [[ -z "$(ls -A "$CLAUDE_DIR" 2>/dev/null)" ]]; then
  echo "ERROR: No Claude credentials found in container."
  echo "Run './docker-login.sh' first to authenticate."
  exit 1
fi

# ── Sanitize global Claude environment ─────────────────────────────────────
# Remove any contaminating global files that could affect benchmark results.
# These may be left over from interactive login sessions.
rm -f "$CLAUDE_DIR/CLAUDE.md"
rm -rf "$CLAUDE_DIR/hooks"

# Write minimal settings — no hooks, no alwaysThinkingEnabled, no global instructions
cat > "$CLAUDE_DIR/settings.json" << 'EOF'
{
  "alwaysThinkingEnabled": false
}
EOF

echo "[benchmark] Clean environment ready (no global CLAUDE.md, no hooks, alwaysThinkingEnabled=false)"

exec /benchmark/run_benchmark.sh "$@"
