#!/usr/bin/env bash
# test_benchmark.sh — Unit tests for benchmark infrastructure.
# Run this BEFORE the real benchmark to confirm hooks, token extraction,
# and scenario setup are all wired correctly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared functions from run_benchmark.sh (main guard ensures no execution).
# `|| true` guards against set -e treating the main guard's false branch as failure:
#   [[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
# evaluates to exit 1 when sourced (left side is false), which set -e would abort on.
# Syntax errors in run_benchmark.sh still propagate — bash exits before || true is reached.
# shellcheck source=run_benchmark.sh
source "$SCRIPT_DIR/run_benchmark.sh" || true

PASS=0; FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────
pass() { echo "  ✓ $*"; (( PASS++ )) || true; }
fail() { echo "  ✗ $*"; (( FAIL++ )) || true; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc — expected: $expected  got: $actual"
  fi
}

assert_file_exists()    { [[ -f "$2" ]] && pass "$1" || fail "$1 — file missing: $2"; }
assert_file_not_exists(){ [[ ! -f "$2" ]] && pass "$1" || fail "$1 — file should not exist: $2"; }
assert_dir_exists()     { [[ -d "$2" ]] && pass "$1" || fail "$1 — dir missing: $2"; }
assert_contains()       { grep -q "$3" "$2" && pass "$1" || fail "$1 — '$3' not found in $2"; }
assert_not_contains()   { ! grep -q "$3" "$2" && pass "$1" || fail "$1 — '$3' unexpectedly found in $2"; }

# ── Suite 1: Hook jq expressions ─────────────────────────────────────────────
# Simulate exactly what Claude Code sends to the hook command via stdin.
echo ""
echo "=== Suite 1: Hook jq expressions ==="

# 1a. SubagentStart — should log subagent_start with agent_type and agent_id
SUBAGENT_INPUT='{"agent_type":"claude","agent_id":"agent-abc123","session_id":"sess-x","cwd":"/tmp/s3","hook_event_name":"SubagentStart"}'
SUBAGENT_CMD=$(jq -r '.hooks.SubagentStart[0].hooks[0].command' "$SCRIPT_DIR/hook_settings.json")
# Note: async:true in hook_settings.json governs Claude Code's dispatch mechanism.
# When invoked via eval in bash (as here), the command runs synchronously — no sleep needed.
# If hook_settings.json renames $CLAUDE_PROJECT_DIR, this substitution silently fails.
SUBAGENT_CMD="${SUBAGENT_CMD//\$CLAUDE_PROJECT_DIR/$TMP}"
SUBAGENT_LOG="$TMP/tool-calls.jsonl"

echo "$SUBAGENT_INPUT" | eval "$SUBAGENT_CMD" 2>/dev/null
RESULT=$(jq -r '.event' "$SUBAGENT_LOG" 2>/dev/null || echo "")
assert_eq "SubagentStart hook writes event=subagent_start" "subagent_start" "$RESULT"
RESULT=$(jq -r '.agent_type' "$SUBAGENT_LOG" 2>/dev/null || echo "")
assert_eq "SubagentStart hook captures agent_type" "claude" "$RESULT"
RESULT=$(jq -r '.agent_id' "$SUBAGENT_LOG" 2>/dev/null || echo "")
assert_eq "SubagentStart hook captures agent_id" "agent-abc123" "$RESULT"

# 1b. PostToolUse(Skill) — should log skill_used with skill name
rm -f "$SUBAGENT_LOG"
SKILL_INPUT='{"tool_name":"Skill","tool_input":{"skill":"explore-codex"},"tool_response":"...content...","session_id":"sess-x","cwd":"/tmp/s4","hook_event_name":"PostToolUse"}'
SKILL_CMD=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$SCRIPT_DIR/hook_settings.json")
# If hook_settings.json renames $CLAUDE_PROJECT_DIR, this substitution silently fails.
SKILL_CMD="${SKILL_CMD//\$CLAUDE_PROJECT_DIR/$TMP}"

echo "$SKILL_INPUT" | eval "$SKILL_CMD" 2>/dev/null
RESULT=$(jq -r '.event' "$SUBAGENT_LOG" 2>/dev/null || echo "")
assert_eq "PostToolUse(Skill) hook writes event=skill_used" "skill_used" "$RESULT"
RESULT=$(jq -r '.skill' "$SUBAGENT_LOG" 2>/dev/null || echo "")
assert_eq "PostToolUse(Skill) hook captures skill name" "explore-codex" "$RESULT"

# 1c. Both events can coexist in the same log file
rm -f "$SUBAGENT_LOG"
echo "$SUBAGENT_INPUT" | eval "$SUBAGENT_CMD" 2>/dev/null
echo "$SKILL_INPUT"    | eval "$SKILL_CMD"    2>/dev/null
COUNT=$(jq -s 'length' "$SUBAGENT_LOG" 2>/dev/null || echo 0)
assert_eq "Both event types written to same log file" "2" "$COUNT"

# ── Suite 2: Token extraction ─────────────────────────────────────────────────
echo ""
echo "=== Suite 2: Token extraction from session JSONL ==="

MOCK_SESSION="$TMP/mock_session.jsonl"
# Two assistant turns with known token values
cat > "$MOCK_SESSION" << 'EOF'
{"type":"user","message":{"role":"user","content":"implement the feature"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1000,"output_tokens":200,"cache_creation_input_tokens":500,"cache_read_input_tokens":300}}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":800,"output_tokens":150,"cache_creation_input_tokens":0,"cache_read_input_tokens":400}}}
EOF

BREAKDOWN=$(extract_session_breakdown "$MOCK_SESSION")

assert_eq "input_tokens summed correctly"  "1800" "$(echo "$BREAKDOWN" | jq '.input')"
assert_eq "output_tokens summed correctly"  "350" "$(echo "$BREAKDOWN" | jq '.output')"
assert_eq "cache_write summed correctly"    "500" "$(echo "$BREAKDOWN" | jq '.cache_write')"
assert_eq "cache_read summed correctly"     "700" "$(echo "$BREAKDOWN" | jq '.cache_read')"

# Edge case: no assistant messages → all zeros
EMPTY_SESSION="$TMP/empty_session.jsonl"
echo '{"type":"user","message":{"content":"hi"}}' > "$EMPTY_SESSION"
BREAKDOWN=$(extract_session_breakdown "$EMPTY_SESSION")
assert_eq "Empty session → all zeros" '{"input":0,"output":0,"cache_write":0,"cache_read":0}' \
  "$(echo "$BREAKDOWN" | jq -c .)"

# ── Suite 3: Scenario setup (runs Phases 0-2 on a local dummy repo) ──────────
echo ""
echo "=== Suite 3: Scenario setup structure ==="

DUMMY_REPO="$TMP/dummy_repo"
mkdir -p "$DUMMY_REPO"
git -C "$DUMMY_REPO" init -q
git -C "$DUMMY_REPO" commit --allow-empty -q -m "init"

# Create a fake base CLAUDE.md (simulate /init output)
cat > "$DUMMY_REPO/CLAUDE.md" << 'EOF'
# dummy project
## Build
npm test
EOF

BASE_CLAUDE_MD="$DUMMY_REPO/CLAUDE.md"

# Simulate Phase 1: clone 5 times
for i in 1 2 3 4 5; do
  git clone "$DUMMY_REPO" "$TMP/s$i" -q 2>/dev/null
done

# Phase 2: use production configure_scenario_dirs (from sourced run_benchmark.sh)
configure_scenario_dirs "$BASE_CLAUDE_MD" "$TMP" 2>/dev/null

# Assertions
assert_file_not_exists "S1 has no CLAUDE.md"         "$TMP/s1/CLAUDE.md"
assert_file_exists     "S2 has CLAUDE.md"             "$TMP/s2/CLAUDE.md"
assert_file_exists     "S3 has CLAUDE.md"             "$TMP/s3/CLAUDE.md"
assert_file_exists     "S4 has CLAUDE.md"             "$TMP/s4/CLAUDE.md"
assert_file_exists     "S5 has CLAUDE.md"             "$TMP/s5/CLAUDE.md"

assert_not_contains "S2 CLAUDE.md has no subagent section" "$TMP/s2/CLAUDE.md" "subagent\|Agent"
assert_contains     "S3 CLAUDE.md has subagent section"    "$TMP/s3/CLAUDE.md" "Agent"
assert_not_contains "S3 CLAUDE.md has no skills section"   "$TMP/s3/CLAUDE.md" "Available Skills"
assert_contains     "S4 CLAUDE.md has skills section"      "$TMP/s4/CLAUDE.md" "Available Skills"
assert_not_contains "S4 CLAUDE.md has no subagent section" "$TMP/s4/CLAUDE.md" "subagent\|Agent"
assert_contains     "S5 CLAUDE.md has subagent section"    "$TMP/s5/CLAUDE.md" "Agent"
assert_contains     "S5 CLAUDE.md has skills section"      "$TMP/s5/CLAUDE.md" "Available Skills"

assert_dir_exists  "S4 has .claude/commands/"        "$TMP/s4/.claude/commands"
assert_file_exists "S4 has explore-codex skill"      "$TMP/s4/.claude/commands/explore-codex.md"
assert_file_exists "S4 has test-codex skill"         "$TMP/s4/.claude/commands/test-codex.md"
assert_dir_exists  "S5 has .claude/commands/"        "$TMP/s5/.claude/commands"

for i in 1 2 3 4 5; do
  assert_file_exists "S$i has monitoring hook settings.json" "$TMP/s$i/.claude/settings.json"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────"
echo "Results: ${PASS} passed  ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] && echo "Status: ALL PASS — safe to run benchmark" \
                     || echo "Status: FAIL — fix before running benchmark"
[[ "$FAIL" -eq 0 ]]
