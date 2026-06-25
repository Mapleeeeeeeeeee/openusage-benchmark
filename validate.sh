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

count_task_calls() {
  local log="$1/tool-calls.jsonl"
  [[ -f "$log" ]] || { echo 0; return; }
  jq -s '[.[] | select(.event == "subagent_start" and .agent_type != "Explore")] | length' "$log"
}

count_skill_reads() {
  local log="$1/tool-calls.jsonl"
  [[ -f "$log" ]] || { echo 0; return; }
  jq -s '[.[] | select(.event == "skill_used")] | length' "$log"
}

plugin_modified() {
  local plugin="$1/plugins/codex/plugin.js"
  [[ -f "$plugin" ]] || { echo "false"; return; }
  grep -qE "fetchRateLimitReset|RateLimitReset|rateLimit.*reset|resetStatus|hascodexratelimitreset" \
    "$plugin" 2>/dev/null && echo "true" || echo "false"
}

run_tests() {
  local scenario_dir="$1"
  local tmpout
  tmpout=$(mktemp)
  # Only run plugin tests — App/component tests may fail due to missing DOM environment
  (cd "$scenario_dir" && bun run test -- --run plugins/ > "$tmpout" 2>&1) || true

  if grep -qE "[0-9]+ failed" "$tmpout"; then
    echo "fail"
    grep -E "failed|FAIL|×" "$tmpout" | head -6 | sed 's/^/      /' >&2
  elif grep -qE "[0-9]+ passed" "$tmpout"; then
    echo "pass"
  else
    echo "fail"
    tail -8 "$tmpout" | sed 's/^/      /' >&2
  fi
  rm -f "$tmpout"
}

# ── Behavioral validation (reference: PR #287) ──────────────────────────────
# Checks that the implementation matches the behavioral contract from the
# reference PR, regardless of UI differences (label text, colors, line type).
validate_behavior() {
  local scenario_dir="$1"
  local plugin_js="$scenario_dir/plugins/codex/plugin.js"
  local plugin_json="$scenario_dir/plugins/codex/plugin.json"

  # API URL — must use the correct endpoint
  grep -qF "hascodexratelimitreset.today/api/status" "$plugin_js" 2>/dev/null \
    && pass "Correct API endpoint" \
    || fail "Wrong or missing API URL (expected hascodexratelimitreset.today/api/status)"

  # Community link in plugin.json
  grep -qF "hascodexratelimitreset.today" "$plugin_json" 2>/dev/null \
    && pass "Community link in plugin.json" \
    || fail "Missing community link to hascodexratelimitreset.today"

  # Line declaration in plugin.json
  jq -e '.lines[] | select(.scope == "detail")' "$plugin_json" >/dev/null 2>&1 \
    && pass "Line declaration in plugin.json" \
    || fail "Missing line declaration in plugin.json"

  # Caching — any form of cache (file-based or in-memory)
  grep -qEi "cache|Cache|CACHE" "$plugin_js" 2>/dev/null \
    && pass "Caching implemented" \
    || fail "No caching found — API will be called on every probe"

  # Graceful degradation — error handling that returns null/skips the line
  grep -qE "catch|\.status\s*!==?\s*200|non.?2" "$plugin_js" 2>/dev/null \
    && pass "Graceful error handling" \
    || fail "No error handling — network failures may crash probe"

  # Both states handled — positive and negative display
  grep -qEi 'yes|reset.*true|hasReset' "$plugin_js" 2>/dev/null \
    && grep -qEi 'no|nope|reset.*false|!.*hasReset|!.*reset' "$plugin_js" 2>/dev/null \
    && pass "Both reset/not-reset states handled" \
    || fail "Missing handling for one or both reset states"
}

# ── Per-scenario validator ───────────────────────────────────────────────────
validate_scenario() {
  local i="$1"
  local label="$2"
  local expect_subagents="$3"
  local expect_skills="$4"
  local scenario_dir="$TEMP_BASE/s$i"

  {
    echo ""
    echo "── $label ──────────────────────────────────────"

    # ── 1. Setup checks ─────────────────────────────────
    if [[ "$i" -ge 2 ]]; then
      [[ -f "$scenario_dir/CLAUDE.md" ]] \
        && pass "CLAUDE.md present" \
        || fail "CLAUDE.md missing"
      [[ -f "$scenario_dir/AGENTS.md" ]] \
        && pass "AGENTS.md present (referenced by CLAUDE.md)" \
        || fail "AGENTS.md missing"
    else
      [[ ! -f "$scenario_dir/CLAUDE.md" ]] \
        && pass "CLAUDE.md absent (baseline)" \
        || warn "CLAUDE.md unexpectedly present"
      [[ ! -f "$scenario_dir/AGENTS.md" ]] \
        && pass "AGENTS.md absent (baseline)" \
        || warn "AGENTS.md unexpectedly present — may leak context into baseline"
      [[ ! -d "$scenario_dir/.claude/skills" ]] \
        && pass ".claude/skills absent (baseline)" \
        || warn ".claude/skills unexpectedly present — may auto-trigger in baseline"
    fi

    if [[ "$expect_skills" == "true" ]]; then
      [[ -d "$scenario_dir/.claude/skills" ]] \
        && pass ".claude/skills/ present" \
        || fail ".claude/skills/ missing (project skills not found in clone)"
    else
      if [[ "$i" -ge 2 ]]; then
        [[ ! -d "$scenario_dir/.claude/skills" ]] \
          && pass ".claude/skills absent (not testing skills)" \
          || warn ".claude/skills present — may contaminate non-skills scenario"
      fi
    fi

    # ── 2. Token data sanity ─────────────────────────────
    local tokens
    tokens=$(jq -r --arg s "$label" '.[] | select(.scenario == $s) | .total_weighted' "$RESULTS_JSON" 2>/dev/null || echo 0)
    if [[ "$tokens" -gt 0 ]]; then
      pass "total_weighted = $tokens (scenario ran)"
    else
      fail "total_weighted = 0 — scenario may not have run at all"
      return
    fi

    # ── 3. Subagent behavior ─────────────────────────────
    local task_calls
    task_calls=$(count_task_calls "$scenario_dir")
    if [[ "$expect_subagents" == "true" ]]; then
      [[ "$task_calls" -gt 0 ]] \
        && pass "Subagents dispatched — $task_calls user subagent(s)" \
        || warn "Task tool available but Claude chose not to delegate (valid behavior)"
    else
      [[ "$task_calls" -eq 0 ]] \
        && pass "No user subagents (as expected)" \
        || fail "Unexpected user subagents: $task_calls — scenario contaminated"
    fi

    # ── 4. Skill invocation behavior ─────────────────────
    local skill_reads
    skill_reads=$(count_skill_reads "$scenario_dir")
    if [[ "$expect_skills" == "true" ]]; then
      [[ "$skill_reads" -gt 0 ]] \
        && pass "Skills invoked — $skill_reads skill read(s)" \
        || warn "Skills available but Claude chose not to invoke (valid if skills are off-topic)"
    else
      [[ "$skill_reads" -eq 0 ]] \
        && pass "No skill reads (as expected)" \
        || fail "Unexpected skill reads: $skill_reads — scenario contaminated"
    fi

    # ── 5. Feature implementation ────────────────────────
    local implemented
    implemented=$(plugin_modified "$scenario_dir")
    [[ "$implemented" == "true" ]] \
      && pass "Feature implemented (rate limit reset code found in plugin.js)" \
      || fail "Feature NOT implemented — plugin.js shows no rate-limit reset code"

    # ── 6. Behavioral contract (ref: PR #287) ────────────
    if [[ "$implemented" == "true" ]]; then
      validate_behavior "$scenario_dir"
    fi

    # ── 7. Claude's own tests pass ───────────────────────
    echo "  Running Claude's tests..."
    local test_result
    test_result=$(run_tests "$scenario_dir")
    if [[ "$test_result" == "pass" ]]; then
      pass "Claude's tests pass"
    else
      fail "Claude's tests fail"
    fi

    # ── 8. Behavioral contract test (ref: PR #287) ─────
    local behavioral_src
    behavioral_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/behavioral.test.js"
    if [[ -f "$behavioral_src" ]]; then
      cp "$behavioral_src" "$scenario_dir/plugins/codex/behavioral.test.js"
      echo "  Running behavioral test..."
      local beh_output
      beh_output=$(cd "$scenario_dir" && bun run test -- --run plugins/codex/behavioral.test.js 2>&1) || true
      local beh_passed beh_failed
      beh_passed=$(echo "$beh_output" | grep -oE '[0-9]+ passed' | head -1 | grep -oE '[0-9]+' || echo 0)
      beh_failed=$(echo "$beh_output" | grep -oE '[0-9]+ failed' | head -1 | grep -oE '[0-9]+' || echo 0)
      if [[ "$beh_failed" -eq 0 && "$beh_passed" -gt 0 ]]; then
        pass "Behavioral test pass ($beh_passed assertions)"
      else
        fail "Behavioral test: $beh_failed of $((beh_passed + beh_failed)) assertions failed"
      fi
    fi
  } > "$TEMP_BASE/.validate_s${i}.out" 2>&1

  cat "$TEMP_BASE/.validate_s${i}.out"
}

# ── Main ─────────────────────────────────────────────────────────────────────
echo "=== Benchmark Validation ==="
echo "Temp dir : $TEMP_BASE"
echo "Results  : $RESULTS_JSON"

# Ensure deps are up to date (idempotent, picks up any new deps Claude added)
echo "Checking deps..."
for i in 1 2 3 4 5; do
  (cd "$TEMP_BASE/s$i" && bun install --silent 2>/dev/null) &
done
wait

# Run all 5 scenario validations concurrently, print results in order
for i in 1 2 3 4 5; do
  case "$i" in
    1) validate_scenario 1 "S1_baseline"  false false & ;;
    2) validate_scenario 2 "S2_claude_md" false false & ;;
    3) validate_scenario 3 "S3_subagents" true  false & ;;
    4) validate_scenario 4 "S4_skills"    false true  & ;;
    5) validate_scenario 5 "S5_full"      true  true  & ;;
  esac
done
wait

# Aggregate counters from subshell output files
for i in 1 2 3 4 5; do
  f="$TEMP_BASE/.validate_s${i}.out"
  [[ -f "$f" ]] || continue
  (( PASS += $(grep -c '  ✓ ' "$f" || true) )) || true
  (( FAIL += $(grep -c '  ✗ ' "$f" || true) )) || true
  (( WARN += $(grep -c '  ~ ' "$f" || true) )) || true
done

# ── Cross-scenario consistency ───────────────────────────────────────────────
echo ""
echo "── Cross-scenario consistency ──────────────────────"

# Collect the line type each scenario registered in plugin.json for the reset feature
declare -a line_types=()
for i in 1 2 3 4 5; do
  local_plugin="$TEMP_BASE/s$i/plugins/codex/plugin.json"
  if [[ -f "$local_plugin" ]]; then
    lt=$(jq -r '[.lines[] | select(.label | test("reset|Reset"; "i"))] | first | .type // "none"' "$local_plugin" 2>/dev/null || echo "none")
  else
    lt="missing"
  fi
  line_types+=("$lt")
done

# Check all scenarios agree on line type (text vs badge vs progress)
unique_types=$(printf '%s\n' "${line_types[@]}" | sort -u | grep -v "none" | grep -v "missing")
type_count=$(echo "$unique_types" | wc -l | tr -d ' ')

if [[ "$type_count" -eq 1 ]]; then
  pass "All scenarios use same line type: $(echo "$unique_types" | head -1)"
elif [[ "$type_count" -eq 0 ]]; then
  fail "No scenario registered a reset line in plugin.json"
else
  warn "Mixed line types across scenarios: $(printf '%s\n' "${line_types[@]}" | paste -sd, -) — UI differs but may still function"
fi

# Check all scenarios use the same API endpoint
api_consistent=true
for i in 1 2 3 4 5; do
  plugin_js="$TEMP_BASE/s$i/plugins/codex/plugin.js"
  if [[ -f "$plugin_js" ]] && ! grep -qF "hascodexratelimitreset.today/api/status" "$plugin_js" 2>/dev/null; then
    api_consistent=false
  fi
done
if [[ "$api_consistent" == "true" ]]; then
  pass "All scenarios use consistent API endpoint"
else
  fail "API endpoint inconsistency — some scenarios may call wrong URL"
fi

echo ""
echo "────────────────────────────────────────────────"
echo "Summary: ${PASS} passed  ${FAIL} failed  ${WARN} warnings"
[[ "$FAIL" -eq 0 ]] && echo "Status: VALID — token numbers are trustworthy" \
                     || echo "Status: INVALID — re-run affected scenarios before drawing conclusions"
[[ "$FAIL" -eq 0 ]]
