#!/usr/bin/env bash
# validate.sh — Evaluates whether each benchmark scenario ran correctly.
#
# Usage: ./validate.sh <temp_base_dir> <results_json>
# Example: ./validate.sh /tmp/openusage-bm-20260623_120000 results/run_20260623_120000.json

set -euo pipefail

TEMP_BASE="${1:-}"
RESULTS_JSON="${2:-}"

[[ -z "$TEMP_BASE"    ]] && { echo "Usage: $0 <temp_base_dir> <results_json>"; exit 1; }
[[ -z "$RESULTS_JSON" ]] && { echo "Usage: $0 <temp_base_dir> <results_json>"; exit 1; }
[[ -d "$TEMP_BASE"    ]] || { echo "ERROR: temp dir not found: $TEMP_BASE"; exit 1; }
[[ -f "$RESULTS_JSON" ]] || { echo "ERROR: results file not found: $RESULTS_JSON"; exit 1; }

# ── Helpers ──────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0

pass() { echo "  ✓ $*"; (( PASS++ )) || true; }
fail() { echo "  ✗ $*"; (( FAIL++ )) || true; }
warn() { echo "  ~ $*"; (( WARN++ )) || true; }

# Read tool-calls.jsonl written by SubagentStart and PostToolUse(Skill) hooks.
# Entry exists = tool executed successfully. No JSONL parsing gymnastics needed.

count_task_calls() {
  local log="$1/tool-calls.jsonl"
  [[ -f "$log" ]] || { echo 0; return; }
  jq -s '[.[] | select(.event == "subagent_start")] | length' "$log"
}

count_skill_reads() {
  local log="$1/tool-calls.jsonl"
  [[ -f "$log" ]] || { echo 0; return; }
  jq -s '[.[] | select(.event == "skill_used")] | length' "$log"
}

# Check if plugin.js was actually modified (has additions vs base)
plugin_modified() {
  local scenario_dir="$1"
  local plugin="$scenario_dir/plugins/codex/plugin.js"
  [[ -f "$plugin" ]] || { echo "false"; return; }
  # Any of these function signatures indicate the feature was implemented
  grep -qE "fetchRateLimitReset|RateLimitReset|rateLimit.*reset|resetStatus|hascodexratelimitreset" \
    "$plugin" 2>/dev/null && echo "true" || echo "false"
}

# Run vitest and return pass/fail
run_tests() {
  local scenario_dir="$1"

  local output
  output=$(cd "$scenario_dir" && npx vitest run plugins/codex/plugin.test.js 2>&1) || true

  if echo "$output" | grep -qE "passed|Tests:.*[1-9][0-9]* passed"; then
    echo "pass"
  else
    echo "fail"
    # Print last few lines for debugging
    echo "$output" | tail -8 | sed 's/^/      /' >&2
  fi
}

# ── Per-scenario validators ───────────────────────────────────────────────────
# $1 = scenario number (1-5)
# $2 = label
# $3 = expect_subagents (true/false)
# $4 = expect_skills (true/false)
validate_scenario() {
  local i="$1"
  local label="$2"
  local expect_subagents="$3"
  local expect_skills="$4"
  local scenario_dir="$TEMP_BASE/s$i"

  echo ""
  echo "── $label ──────────────────────────────────────"

  # ── 1. Setup checks ─────────────────────────────────
  if [[ "$i" -ge 2 ]]; then
    [[ -f "$scenario_dir/CLAUDE.md" ]] \
      && pass "CLAUDE.md present" \
      || fail "CLAUDE.md missing"
  else
    [[ ! -f "$scenario_dir/CLAUDE.md" ]] \
      && pass "CLAUDE.md absent (baseline)" \
      || warn "CLAUDE.md unexpectedly present"
  fi

  if [[ "$expect_skills" == "true" ]]; then
    [[ -d "$scenario_dir/.claude/commands" ]] \
      && pass ".claude/commands/ present" \
      || fail ".claude/commands/ missing"
  fi

  # ── 2. Hook log exists ───────────────────────────────
  # tool-calls.jsonl is written by the SubagentStart / PostToolUse(Skill) hook (async).
  # If it doesn't exist, it means either the hook didn't fire (no matching tool calls)
  # OR the scenario didn't run. We check token data to distinguish.

  # ── 3. Token data sanity ─────────────────────────────
  local tokens
  tokens=$(jq -r --arg s "$label" '.[] | select(.scenario == $s) | .total_weighted' "$RESULTS_JSON" 2>/dev/null || echo 0)
  if [[ "$tokens" -gt 0 ]]; then
    pass "total_weighted = $tokens (scenario ran)"
  else
    fail "total_weighted = 0 — scenario may not have run at all"
    return
  fi

  # ── 4. Subagent behavior ─────────────────────────────
  # SubagentStart hook writes to tool-calls.jsonl when an agent starts.
  # Entry exists = agent was spawned.
  local task_calls
  task_calls=$(count_task_calls "$scenario_dir")
  if [[ "$expect_subagents" == "true" ]]; then
    [[ "$task_calls" -gt 0 ]] \
      && pass "Subagents confirmed — $task_calls subagent(s) logged by hook" \
      || fail "Expected subagents but hook logged 0 subagents — CLAUDE.md workflow section may not have worked"
  else
    [[ "$task_calls" -eq 0 ]] \
      && pass "No subagents (as expected)" \
      || fail "Hook logged unexpected subagents: $task_calls — scenario contaminated"
  fi

  # ── 5. Skill invocation behavior ─────────────────────
  # PostToolUse(Skill) hook writes to tool-calls.jsonl when a skill is invoked.
  # Entry exists = skill file was successfully read.
  local skill_reads
  skill_reads=$(count_skill_reads "$scenario_dir")
  if [[ "$expect_skills" == "true" ]]; then
    [[ "$skill_reads" -gt 0 ]] \
      && pass "Skills confirmed — $skill_reads .claude/commands read(s) logged by hook" \
      || fail "Expected skill reads but hook logged 0 — Claude may have ignored the skills section"
  else
    [[ "$skill_reads" -eq 0 ]] \
      && pass "No skill reads (as expected)" \
      || fail "Hook logged unexpected skill reads: $skill_reads — scenario contaminated"
  fi

  # ── 6. Feature implementation ────────────────────────
  local implemented
  implemented=$(plugin_modified "$scenario_dir")
  [[ "$implemented" == "true" ]] \
    && pass "Feature implemented (rate limit reset code found in plugin.js)" \
    || fail "Feature NOT implemented — plugin.js shows no rate-limit reset code"

  # ── 7. Tests pass ────────────────────────────────────
  echo "  Running tests..."
  local test_result
  test_result=$(run_tests "$scenario_dir")
  if [[ "$test_result" == "pass" ]]; then
    pass "Tests pass"
  else
    fail "Tests fail"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
echo "=== Benchmark Validation ==="
echo "Temp dir : $TEMP_BASE"
echo "Results  : $RESULTS_JSON"

# Install npm deps once in s1, copy node_modules to s2-s5 to avoid 5x install
if [[ ! -d "$TEMP_BASE/s1/node_modules" ]]; then
  echo "Installing npm deps..."
  (cd "$TEMP_BASE/s1" && npm install --silent 2>/dev/null) || true
fi
for i in 2 3 4 5; do
  if [[ ! -d "$TEMP_BASE/s$i/node_modules" ]]; then
    cp -r "$TEMP_BASE/s1/node_modules" "$TEMP_BASE/s$i/"
  fi
done

#              i  label              subagents  skills
validate_scenario 1 "S1_baseline"    false      false
validate_scenario 2 "S2_claude_md"   false      false
validate_scenario 3 "S3_subagents"   true       false
validate_scenario 4 "S4_skills"      false      true
validate_scenario 5 "S5_full"        true       true

echo ""
echo "────────────────────────────────────────────────"
echo "Summary: ${PASS} passed  ${FAIL} failed  ${WARN} warnings"
[[ "$FAIL" -eq 0 ]] && echo "Status: VALID — token numbers are trustworthy" \
                     || echo "Status: INVALID — re-run affected scenarios before drawing conclusions"
[[ "$FAIL" -eq 0 ]]
