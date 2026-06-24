#!/usr/bin/env bash
# openusage harness benchmark
# Measures token cost across 5 scenarios: CLAUDE.md / subagents / skills
#
# Usage: ./run_benchmark.sh [--skip-init]
#   --skip-init  Skip the /init step and reuse existing CLAUDE.md (for re-runs)

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
MODEL="claude-sonnet-4-6"
REPO_URL="https://github.com/robinebers/openusage"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEMP_BASE="/tmp/openusage-bm-$TIMESTAMP"
RESULTS_DIR="$SCRIPT_DIR/results"
RESULTS_FILE="$RESULTS_DIR/run_$TIMESTAMP.json"
SKIP_INIT=false
E2E=false        # --e2e: run S1 only with haiku to validate pipeline

for arg in "$@"; do
  [[ "$arg" == "--skip-init" ]] && SKIP_INIT=true
  [[ "$arg" == "--e2e"       ]] && E2E=true
done

if [[ "$E2E" == "true" ]]; then
  MODEL="claude-haiku-4-5-20251001"
  log() { echo "[e2e][$(date +%H:%M:%S)] $*" >&2; }
fi

# Tools allowed per scenario type (no Task in non-subagent scenarios to prevent spontaneous agent spawning)
TOOLS_BASE="Read,Write,Edit,MultiEdit,Bash,LS,Glob,Grep"
TOOLS_WITH_SUBAGENTS="$TOOLS_BASE,Task"

# Neutral feature prompt — describes WHAT, not HOW
FEATURE_PROMPT='Add a Codex rate limit reset status feature to this openusage repository.

The Codex plugin should display whether the API rate limit has been reset today
using https://hascodexratelimitreset.today/api/status. Include caching to avoid
excessive API calls, graceful error handling for network failures, and a community
link for the service in plugin.json. Write comprehensive tests.'

# ── Scenario definitions ─────────────────────────────────────────────────────
# Arrays indexed 1-5 (index 0 unused)
SCENARIO_LABELS=( ""  "S1_baseline"  "S2_claude_md"  "S3_subagents"  "S4_skills"  "S5_full" )
SCENARIO_CLAUDE=( ""  "false"        "true"           "true"           "true"        "true"   )
SCENARIO_SUBAG=( ""   "false"        "false"          "true"           "false"       "true"   )
SCENARIO_SKILLS=( ""  "false"        "false"          "false"          "true"        "true"   )

# ── Helpers ──────────────────────────────────────────────────────────────────
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Returns the max weighted token total for a session UUID from tokens.jsonl.
# Parent session entries in tokens.jsonl include all subagent token costs merged in.
get_session_weighted_tokens() {
  local session_id="$1"
  # Grep by UUID only (avoids field-name spacing variations)
  grep "$session_id" ~/.claude/usage-tracker/tokens.jsonl 2>/dev/null \
    | jq -s 'if length > 0 then map(.tokens) | max else 0 end' \
    || echo 0
}

# Parses main session JSONL for per-type token breakdown (excludes subagent sessions).
extract_session_breakdown() {
  local session_file="$1"
  [[ -f "$session_file" ]] || { echo '{"input":0,"output":0,"cache_write":0,"cache_read":0}'; return; }

  jq -rs '
    [.[] | select(.type == "assistant"
               and .message != null
               and .message.usage != null)] |
    {
      input:       (map(.message.usage.input_tokens                // 0) | add // 0),
      output:      (map(.message.usage.output_tokens               // 0) | add // 0),
      cache_write: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
      cache_read:  (map(.message.usage.cache_read_input_tokens     // 0) | add // 0)
    }
  ' "$session_file"
}

# Finds the PARENT session JSONL created after a marker file.
# For subagent scenarios, multiple sessions exist; the parent contains the original prompt.
find_parent_session() {
  local marker="$1"
  local prompt_fingerprint="hascodexratelimitreset.today"  # Distinctive phrase from FEATURE_PROMPT

  local new_sessions
  new_sessions=$(find ~/.claude/projects/ -name "*.jsonl" -newer "$marker" 2>/dev/null \
    | grep -v 'tokens\|ratelimit\|api-cache') || true

  [[ -z "$new_sessions" ]] && { echo ""; return; }

  # Parent session contains the original user prompt; subagent sessions don't
  local parent
  parent=$(echo "$new_sessions" | while read -r f; do
    grep -qlF "$prompt_fingerprint" "$f" 2>/dev/null && echo "$f"
  done | head -1)

  # Fallback: oldest new session if grep finds nothing
  if [[ -z "$parent" ]]; then
    parent=$(echo "$new_sessions" | head -1)
  fi

  echo "$parent"
}

append_result() {
  local result="$1"
  local tmp
  tmp=$(jq --argjson r "$result" '. += [$r]' "$RESULTS_FILE")
  echo "$tmp" > "$RESULTS_FILE"
}

# ── Setup ────────────────────────────────────────────────────────────────────
log "Benchmark starting — model: $MODEL"
log "Temp dir: $TEMP_BASE"
log "Results : $RESULTS_FILE"
mkdir -p "$TEMP_BASE" "$RESULTS_DIR"
echo "[]" > "$RESULTS_FILE"

# ── Phase 0: Clone base repo + generate CLAUDE.md via /init ─────────────────
log ""
log "=== Phase 0: Clone + generate CLAUDE.md ==="

git clone "$REPO_URL" "$TEMP_BASE/base" --quiet
log "Cloned openusage"

BASE_CLAUDE_MD="$TEMP_BASE/base/CLAUDE.md"

if [[ "$SKIP_INIT" == "true" && -f "$SCRIPT_DIR/cached_claude_md.md" ]]; then
  log "Using cached CLAUDE.md (--skip-init)"
  cp "$SCRIPT_DIR/cached_claude_md.md" "$BASE_CLAUDE_MD"
else
  log "Running /init to generate CLAUDE.md..."
  (cd "$TEMP_BASE/base" && \
    claude -p "/init" \
      --model "$MODEL" \
      --allowedTools "Write,Read,Bash,LS,Glob,Grep" \
      --output-format text \
    2>/dev/null) || true

  if [[ ! -f "$BASE_CLAUDE_MD" ]]; then
    log "WARNING: /init did not create CLAUDE.md — trying direct prompt fallback"
    (cd "$TEMP_BASE/base" && \
      claude -p 'Analyze this repository and create a CLAUDE.md file covering:
project purpose, directory structure, key files, build and test commands,
and coding conventions observed in the source. Write it to CLAUDE.md.' \
        --model "$MODEL" \
        --allowedTools "Write,Read,Bash,LS,Glob,Grep" \
        --output-format text \
      2>/dev/null) || true
  fi

  [[ -f "$BASE_CLAUDE_MD" ]] || die "Could not generate CLAUDE.md"

  # Cache for --skip-init re-runs
  cp "$BASE_CLAUDE_MD" "$SCRIPT_DIR/cached_claude_md.md"
fi

log "CLAUDE.md ready ($(wc -l < "$BASE_CLAUDE_MD") lines)"

# ── Phase 1: Clone 5 scenario repos ──────────────────────────────────────────
log ""
log "=== Phase 1: Cloning 5 scenario repos ==="
for i in 1 2 3 4 5; do
  git clone "$TEMP_BASE/base" "$TEMP_BASE/s$i" --quiet
  log "Cloned s$i"
done

# ── Phase 2: Configure each scenario ─────────────────────────────────────────
log ""
log "=== Phase 2: Configuring scenarios ==="

# S1 — No CLAUDE.md
rm -f "$TEMP_BASE/s1/CLAUDE.md"
log "S1: no CLAUDE.md"

# S2 — CLAUDE.md only (no workflow additions)
cp "$BASE_CLAUDE_MD" "$TEMP_BASE/s2/CLAUDE.md"
log "S2: CLAUDE.md only"

# S3 — CLAUDE.md + subagents workflow section
cp "$BASE_CLAUDE_MD" "$TEMP_BASE/s3/CLAUDE.md"
cat >> "$TEMP_BASE/s3/CLAUDE.md" << 'SECTION'

## Development Workflow

Spawn an Agent subagent to explore `plugins/codex/` and map existing patterns
before writing code. Use the Agent tool to parallelize independent tasks where
appropriate.
SECTION
log "S3: CLAUDE.md + subagents"

# S4 — CLAUDE.md + skills (no subagents)
cp "$BASE_CLAUDE_MD" "$TEMP_BASE/s4/CLAUDE.md"
cat >> "$TEMP_BASE/s4/CLAUDE.md" << 'SECTION'

## Available Skills

When implementing features in the Codex plugin, use these project skills:
- `/explore-codex` — maps the codex plugin architecture and conventions
- `/test-codex`    — runs the codex plugin test suite and reports results
SECTION
mkdir -p "$TEMP_BASE/s4/.claude/commands"
cp "$SCRIPT_DIR/commands/explore-codex.md" "$TEMP_BASE/s4/.claude/commands/"
cp "$SCRIPT_DIR/commands/test-codex.md"    "$TEMP_BASE/s4/.claude/commands/"
log "S4: CLAUDE.md + skills"

# S5 — CLAUDE.md + subagents + skills
cp "$BASE_CLAUDE_MD" "$TEMP_BASE/s5/CLAUDE.md"
cat >> "$TEMP_BASE/s5/CLAUDE.md" << 'SECTION'

## Development Workflow

Spawn an Agent subagent to explore `plugins/codex/` and map existing patterns
before writing code. Use the Agent tool to parallelize independent tasks where
appropriate.

## Available Skills

When implementing features in the Codex plugin, use these project skills:
- `/explore-codex` — maps the codex plugin architecture and conventions
- `/test-codex`    — runs the codex plugin test suite and reports results
SECTION
mkdir -p "$TEMP_BASE/s5/.claude/commands"
cp "$SCRIPT_DIR/commands/explore-codex.md" "$TEMP_BASE/s5/.claude/commands/"
cp "$SCRIPT_DIR/commands/test-codex.md"    "$TEMP_BASE/s5/.claude/commands/"
log "S5: CLAUDE.md + subagents + skills"

# Install monitoring hook in all 5 scenarios.
# PostToolUse(Task) → logs task_call; PostToolUse(Read on .claude/commands/) → logs skill_read.
# Hook fires only on successful execution, so any entry = confirmed success.
for i in 1 2 3 4 5; do
  mkdir -p "$TEMP_BASE/s$i/.claude"
  cp "$SCRIPT_DIR/hook_settings.json" "$TEMP_BASE/s$i/.claude/settings.json"
done
log "Monitoring hook installed in all scenarios"

# ── Phase 3: Run each scenario ────────────────────────────────────────────────
log ""
log "=== Phase 3: Running scenarios ==="

run_scenario() {
  local i="$1"
  local label="${SCENARIO_LABELS[$i]}"
  local dir="$TEMP_BASE/s$i"
  local use_subagents="${SCENARIO_SUBAG[$i]}"
  local allowed_tools="$TOOLS_BASE"
  [[ "$use_subagents" == "true" ]] && allowed_tools="$TOOLS_WITH_SUBAGENTS"

  log ""
  log "--- $label (tools: $allowed_tools) ---"

  # Marker for finding new session file afterwards
  touch "$TEMP_BASE/marker_s$i"

  local start_sec
  start_sec=$(date +%s)

  (cd "$dir" && \
    claude -p "$FEATURE_PROMPT" \
      --model "$MODEL" \
      --effort low \
      --allowedTools "$allowed_tools" \
      --output-format text \
    2>/dev/null) || log "WARNING: claude exited non-zero for $label"

  local end_sec
  end_sec=$(date +%s)
  local duration=$(( end_sec - start_sec ))

  sleep 3  # Allow JSONL flush to disk

  # Find the new session file
  local session_file
  session_file=$(find_parent_session "$TEMP_BASE/marker_s$i") || true

  local breakdown
  local session_id=""
  local total_weighted=0

  if [[ -n "$session_file" ]]; then
    session_id=$(basename "$session_file" .jsonl)
    log "Session: $session_id"
    breakdown=$(extract_session_breakdown "$session_file")
    total_weighted=$(get_session_weighted_tokens "$session_id")
  else
    log "WARNING: No session file found for $label"
    breakdown='{"input":0,"output":0,"cache_write":0,"cache_read":0}'
  fi

  # Compute sum of main-session tokens for subagent delta
  local main_total
  main_total=$(echo "$breakdown" | jq '.input + .output + .cache_write + .cache_read')
  local subagent_tokens=$(( total_weighted - main_total ))
  [[ $subagent_tokens -lt 0 ]] && subagent_tokens=0

  local result
  result=$(echo "$breakdown" | jq \
    --arg label       "$label" \
    --argjson claude  "$([ "${SCENARIO_CLAUDE[$i]}" = true ] && echo true || echo false)" \
    --argjson subag   "$([ "${SCENARIO_SUBAG[$i]}"  = true ] && echo true || echo false)" \
    --argjson skills  "$([ "${SCENARIO_SKILLS[$i]}" = true ] && echo true || echo false)" \
    --argjson dur     "$duration" \
    --argjson tw      "$total_weighted" \
    --argjson sub_tok "$subagent_tokens" \
    '{
      scenario:            $label,
      has_claude_md:       $claude,
      has_subagents:       $subag,
      has_skills:          $skills,
      input_tokens:        .input,
      output_tokens:       .output,
      cache_write_tokens:  .cache_write,
      cache_read_tokens:   .cache_read,
      subagent_tokens:     $sub_tok,
      total_weighted:      $tw,
      duration_sec:        $dur
    }')

  append_result "$result"
  log "$label done — weighted: $total_weighted, subagent overhead: $subagent_tokens, time: ${duration}s"
}

SCENARIOS_TO_RUN=(1 2 3 4 5)
[[ "$E2E" == "true" ]] && SCENARIOS_TO_RUN=(1)

for i in "${SCENARIOS_TO_RUN[@]}"; do
  run_scenario "$i"
done

# ── Phase 4: Print results table ─────────────────────────────────────────────
log ""
log "=== Results ==="
echo ""
echo "Results saved to: $RESULTS_FILE"
echo ""

# Print table via jq + column
printf "%-20s %-9s %-9s %-7s %-10s %-10s %-10s %-10s %-10s %-10s %-8s\n" \
  "Scenario" "CLAUDE.md" "Subagents" "Skills" \
  "Input" "Output" "CacheWrite" "CacheRead" "Subagent" "Weighted" "Time"
printf '%0.s─' {1..120}; echo

jq -r '.[] | [
  .scenario,
  (if .has_claude_md  then "✓" else "✗" end),
  (if .has_subagents  then "✓" else "✗" end),
  (if .has_skills     then "✓" else "✗" end),
  (.input_tokens       | tostring),
  (.output_tokens      | tostring),
  (.cache_write_tokens | tostring),
  (.cache_read_tokens  | tostring),
  (.subagent_tokens    | tostring),
  (.total_weighted     | tostring),
  ((.duration_sec | tostring) + "s")
] | @tsv' "$RESULTS_FILE" \
  | awk -F'\t' '{printf "%-20s %-9s %-9s %-7s %-10s %-10s %-10s %-10s %-10s %-10s %-8s\n",
      $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11}'

echo ""

# ── Delta analysis ────────────────────────────────────────────────────────────
echo "=== Delta Analysis (weighted tokens) ==="
echo ""

jq -r '
  def get(s): map(select(.scenario == s)) | first | .total_weighted // 0;
  {
    "S2-S1  CLAUDE.md effect":         (get("S2_claude_md")  - get("S1_baseline")),
    "S3-S2  subagents added":           (get("S3_subagents")  - get("S2_claude_md")),
    "S4-S2  skills added":              (get("S4_skills")     - get("S2_claude_md")),
    "S5-S3  skills on top of subag":    (get("S5_full")       - get("S3_subagents")),
    "S5-S4  subagents on top of skills":(get("S5_full")       - get("S4_skills"))
  } | to_entries[] | "\(.key):  \(.value)"
' "$RESULTS_FILE"

echo ""
echo "Temp repos: $TEMP_BASE"
echo "Done."
