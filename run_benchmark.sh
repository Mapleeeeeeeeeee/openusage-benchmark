#!/usr/bin/env bash
# openusage harness benchmark
# Measures token cost across 5 scenarios: CLAUDE.md / subagents / skills
#
# Usage: ./run_benchmark.sh [--skip-init] [--e2e] [--dry-run]
#   --skip-init  Skip the /init step and reuse existing CLAUDE.md (for re-runs)
#   --e2e        Run S1 only with Haiku to validate pipeline end-to-end
#   --dry-run    Mock claude -p with fake output to test pipeline without AI cost

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
MODEL="claude-sonnet-4-6"
REPO_URL="https://github.com/robinebers/openusage"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tools allowed per scenario type (no Task in non-subagent scenarios to prevent spontaneous agent spawning)
TOOLS_BASE="Read,Write,Edit,MultiEdit,Bash,LS,Glob,Grep"
TOOLS_WITH_SUBAGENTS="$TOOLS_BASE,Task"

# Neutral feature prompt — describes WHAT, not HOW
FEATURE_PROMPT='Add a Codex rate limit reset status feature to this openusage repository.

The Codex plugin should display whether the API rate limit has been reset today
using https://hascodexratelimitreset.today/api/status.

Requirements:
- Show a green (#22c55e) positive indicator when rate limit has reset today
- Show a red (#ef4444) negative indicator when it has not
- Omit the line entirely on API errors or network failures (do not crash probe)
- Include caching to avoid excessive API calls
- Add a community link for the service in plugin.json
- Write comprehensive tests

A behavioral test file already exists at plugins/codex/behavioral.test.js.
After implementing, run: bun run test -- --run plugins/codex/
All plugin tests AND behavioral tests must pass. Fix until zero failures.'

# ── Scenario definitions ─────────────────────────────────────────────────────
# Arrays indexed 1-5 (index 0 unused)
SCENARIO_LABELS=( ""  "S1_baseline"  "S2_claude_md"  "S3_subagents"  "S4_skills"  "S5_full" )
SCENARIO_CLAUDE=( ""  "false"        "true"           "true"           "true"        "true"   )
SCENARIO_SUBAG=( ""   "false"        "false"          "true"           "false"       "true"   )
SCENARIO_SKILLS=( ""  "false"        "false"          "false"          "true"        "true"   )

# ── Shared content blocks (DRY: used by configure_scenario_dirs) ─────────────
SUBAGENT_SECTION='
## Development Workflow

Spawn an Agent subagent to explore `plugins/codex/` and map existing patterns
before writing code. Use the Agent tool to parallelize independent tasks where
appropriate.'

SKILLS_SECTION='
## Available Skills

This project includes skills for Tauri development. Use them when working on
Tauri configuration, Rust commands, IPC patterns, or cross-platform builds:
- `/tauri-development` — TypeScript/Rust patterns, project structure, state management
- `/tauri-v2`          — Tauri v2 IPC, capabilities, common errors and prevention'

# ── Helpers ──────────────────────────────────────────────────────────────────

# Resolves the Claude Code project dir for a given scenario working directory.
# Claude Code slugifies the real path: replace / and _ with -.
get_project_dir() {
  local dir="$1"
  local real_dir
  real_dir=$(cd "$dir" 2>/dev/null && pwd -P) || real_dir="$dir"
  local slug="${real_dir//\//-}"
  slug="${slug//_/-}"
  echo "$HOME/.claude/projects/$slug"
}

# Parse args before defining log() so $E2E is available
SKIP_INIT=false
E2E=false        # --e2e: run S1 only with haiku to validate pipeline
DRY_RUN=false    # --dry-run: mock claude -p, test everything else

for arg in "$@"; do
  case "$arg" in
    --skip-init) SKIP_INIT=true ;;
    --e2e)       E2E=true ;;
    --dry-run)   DRY_RUN=true ;;
    *) echo "ERROR: Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

log() {
  local prefix="[$(date +%H:%M:%S)]"
  [[ "$E2E" == "true" ]] && prefix="[e2e]$prefix"
  echo "$prefix $*" >&2
}

die() { log "ERROR: $*"; exit 1; }

# Sums weighted tokens (input+output+cache_write+cache_read) across all new session JSONLs
# created after $marker within the scenario's own project dir (parent + subagent children).
# Scoped to prevent contamination from other Claude Code sessions running concurrently.
compute_total_weighted() {
  local scenario_dir="$1"
  local marker="$2"

  local project_dir
  project_dir=$(get_project_dir "$scenario_dir")

  [[ -d "$project_dir" ]] || { echo 0; return; }

  local total=0 f t
  while IFS= read -r f; do
    t=$(jq -rs '
      [.[] | select(.type == "assistant"
                 and .message != null
                 and .message.usage != null)] |
      map(.message.usage |
        (.input_tokens                // 0) +
        (.output_tokens               // 0) +
        (.cache_creation_input_tokens // 0) +
        (.cache_read_input_tokens     // 0)) |
      add // 0
    ' "$f" 2>/dev/null) || t=0
    total=$(( total + t ))
  done < <(find "$project_dir" -name "*.jsonl" -newer "$marker" 2>/dev/null)
  echo "$total"
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

# Finds the PARENT session JSONL created after a marker file within the scenario's project dir.
# For subagent scenarios, multiple sessions exist; the parent contains the original prompt.
# Scoped to the scenario's own project dir to prevent contamination from other sessions.
find_parent_session() {
  local marker="$1"
  local scenario_dir="$2"
  local prompt_fingerprint="hascodexratelimitreset.today"  # Distinctive phrase from FEATURE_PROMPT

  local project_dir
  project_dir=$(get_project_dir "$scenario_dir")

  [[ -d "$project_dir" ]] || { echo ""; return; }

  local new_sessions
  new_sessions=$(find "$project_dir" -name "*.jsonl" -newer "$marker" 2>/dev/null) || true

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

# Configures all 5 scenario directories from a base CLAUDE.md.
# Uses $SCRIPT_DIR (global) to locate hook_settings.json.
#
# Isolation rules:
#   AGENTS.md  — kept only in S2-S5 (CLAUDE.md says "Read AGENTS.md first")
#   .claude/skills/ — kept only in S4-S5 (skills test scenarios)
configure_scenario_dirs() {
  local base_claude_md="$1"
  local temp_base="$2"

  # S1 — true baseline: no CLAUDE.md, no AGENTS.md, no skills
  rm -f  "$temp_base/s1/CLAUDE.md"
  rm -f  "$temp_base/s1/AGENTS.md"
  rm -rf "$temp_base/s1/.claude/skills"
  log "S1: no CLAUDE.md"

  # S2 — CLAUDE.md + AGENTS.md only (CLAUDE.md references AGENTS.md)
  cp "$base_claude_md" "$temp_base/s2/CLAUDE.md"
  rm -rf "$temp_base/s2/.claude/skills"
  log "S2: CLAUDE.md only"

  # S3 — CLAUDE.md + AGENTS.md + subagents workflow section
  cp "$base_claude_md" "$temp_base/s3/CLAUDE.md"
  printf '%s\n' "$SUBAGENT_SECTION" >> "$temp_base/s3/CLAUDE.md"
  rm -rf "$temp_base/s3/.claude/skills"
  log "S3: CLAUDE.md + subagents"

  # S4 — CLAUDE.md + AGENTS.md + project skills (no subagents)
  # .claude/skills/ already present from repo clone; SKILLS_SECTION tells Claude about them.
  cp "$base_claude_md" "$temp_base/s4/CLAUDE.md"
  printf '%s\n' "$SKILLS_SECTION" >> "$temp_base/s4/CLAUDE.md"
  log "S4: CLAUDE.md + skills"

  # S5 — CLAUDE.md + AGENTS.md + subagents + project skills
  cp "$base_claude_md" "$temp_base/s5/CLAUDE.md"
  printf '%s\n' "$SUBAGENT_SECTION" >> "$temp_base/s5/CLAUDE.md"
  printf '%s\n' "$SKILLS_SECTION"   >> "$temp_base/s5/CLAUDE.md"
  log "S5: CLAUDE.md + subagents + skills"

  for i in 1 2 3 4 5; do
    # Monitoring hook
    mkdir -p "$temp_base/s$i/.claude"
    cp "$SCRIPT_DIR/hook_settings.json" "$temp_base/s$i/.claude/settings.json"
    # Behavioral test (acceptance criteria Claude must pass)
    if [[ -d "$temp_base/s$i/plugins/codex" ]]; then
      cp "$SCRIPT_DIR/behavioral.test.js" "$temp_base/s$i/plugins/codex/behavioral.test.js"
    fi
  done
  log "Monitoring hook + behavioral test installed in all scenarios"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  local TIMESTAMP
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  local TEMP_BASE="${BENCHMARK_TEMP_BASE:-/tmp}/openusage-bm-$TIMESTAMP"
  local RESULTS_DIR="$SCRIPT_DIR/results"
  local RESULTS_FILE="$RESULTS_DIR/run_$TIMESTAMP.json"

  [[ "$E2E" == "true" ]] && MODEL="claude-haiku-4-5-20251001"

  # Accumulate results in-memory; write once at the end
  local RESULTS=()

  # ── Setup ──────────────────────────────────────────────────────────────────
  log "Benchmark starting — model: $MODEL"
  log "Temp dir: $TEMP_BASE"
  log "Results : $RESULTS_FILE"
  mkdir -p "$TEMP_BASE" "$RESULTS_DIR"

  # ── Phase 0: Clone base repo + generate CLAUDE.md via /init ────────────────
  log ""
  log "=== Phase 0: Clone + generate CLAUDE.md ==="

  git clone "$REPO_URL" "$TEMP_BASE/base" --quiet
  log "Cloned openusage"

  local BASE_CLAUDE_MD="$TEMP_BASE/base/CLAUDE.md"

  if { [[ "$SKIP_INIT" == "true" ]] || [[ "$DRY_RUN" == "true" ]]; } && [[ -f "$SCRIPT_DIR/cached_claude_md.md" ]]; then
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

  # ── Phase 1: Clone 5 scenario repos (parallel) ─────────────────────────────
  log ""
  log "=== Phase 1: Cloning 5 scenario repos ==="
  for i in 1 2 3 4 5; do
    git clone "$TEMP_BASE/base" "$TEMP_BASE/s$i" --quiet &
  done
  wait
  log "All 5 scenario repos cloned"

  # ── Phase 2: Configure each scenario + install deps ─────────────────────────
  log ""
  log "=== Phase 2: Configuring scenarios ==="
  configure_scenario_dirs "$BASE_CLAUDE_MD" "$TEMP_BASE"

  # Install deps once per scenario so Claude doesn't waste tokens on bun install
  log "Installing deps in all scenarios..."
  for i in 1 2 3 4 5; do
    (cd "$TEMP_BASE/s$i" && bun install --silent 2>/dev/null) &
  done
  wait
  log "Deps installed"

  # ── Phase 3: Run each scenario ─────────────────────────────────────────────
  log ""
  if [[ "$DRY_RUN" == "true" ]]; then
    log "=== Phase 3: Running scenarios (DRY RUN — mock output) ==="
  else
    log "=== Phase 3: Running scenarios ==="
  fi

  # Writes fake session JSONL + plugin changes so Phase 4 validate can run.
  mock_claude_session() {
    local dir="$1"
    local scenario_dir="$2"
    local use_subagents="$3"

    # Simulate feature implementation in plugin.js
    local plugin_js="$dir/plugins/codex/plugin.js"
    if [[ -f "$plugin_js" ]]; then
      cat >> "$plugin_js" << 'MOCK_EOF'

// --- mock: rate limit reset status ---
const RATE_LIMIT_RESET_STATUS_URL = "https://hascodexratelimitreset.today/api/status";
function fetchRateLimitResetStatus(ctx) {
  try {
    const resp = ctx.util.request({ method: "GET", url: RATE_LIMIT_RESET_STATUS_URL, headers: { Accept: "application/json" }, timeoutMs: 3000 });
    if (resp.status !== 200) return null;
    const data = ctx.util.tryParseJson(resp.bodyText);
    if (!data) return null;
    return typeof data.reset === "boolean" ? data.reset : null;
  } catch { return null; }
}
MOCK_EOF
    fi

    # Add community link + line declaration to plugin.json
    local plugin_json="$dir/plugins/codex/plugin.json"
    if [[ -f "$plugin_json" ]]; then
      local tmp_json="${plugin_json}.tmp"
      jq '.links += [{"label":"Rate limit reset?","url":"https://hascodexratelimitreset.today"}]
        | .lines += [{"type":"text","label":"Reset today?","scope":"detail"}]' \
        "$plugin_json" > "$tmp_json" && mv "$tmp_json" "$plugin_json"
    fi

    # Simulate test file
    cat > "$dir/plugins/codex/plugin.ratelimitreset.test.js" << 'MOCK_EOF'
import { describe, it, expect } from "vitest";
describe("rate limit reset status (mock)", () => {
  it("placeholder", () => { expect(true).toBe(true); });
});
MOCK_EOF

    # Create fake session JSONL in the project dir
    local project_dir
    project_dir=$(get_project_dir "$dir")
    mkdir -p "$project_dir"

    local session_id
    session_id="mock-$(date +%s)-$$"
    local session_file="$project_dir/${session_id}.jsonl"

    # Write plausible token usage entries
    local base_input=12000 base_output=8000 base_cw=60000 base_cr=1500000
    cat > "$session_file" << MOCK_JSONL
{"type":"assistant","message":{"usage":{"input_tokens":${base_input},"output_tokens":${base_output},"cache_creation_input_tokens":${base_cw},"cache_read_input_tokens":${base_cr}}}}
MOCK_JSONL

    # For subagent scenarios, add a child session
    if [[ "$use_subagents" == "true" ]]; then
      local child_file="$project_dir/mock-child-${session_id}.jsonl"
      cat > "$child_file" << MOCK_JSONL
{"type":"assistant","message":{"usage":{"input_tokens":3000,"output_tokens":2000,"cache_creation_input_tokens":10000,"cache_read_input_tokens":200000}}}
MOCK_JSONL
    fi

    echo "$session_file"
  }

  run_scenario() {
    local i="$1"
    local label="${SCENARIO_LABELS[$i]}"
    local dir="$TEMP_BASE/s$i"
    local use_subagents="${SCENARIO_SUBAG[$i]}"
    local allowed_tools="$TOOLS_BASE"
    [[ "$use_subagents" == "true" ]] && allowed_tools="$TOOLS_WITH_SUBAGENTS"

    local log_file="$TEMP_BASE/.log_s${i}.txt"
    local result_file="$TEMP_BASE/.result_s${i}.json"

    {
      log "--- $label (tools: $allowed_tools) ---"

      # Marker for finding new session file afterwards
      touch "$TEMP_BASE/marker_s$i"

      local start_sec
      start_sec=$(date +%s)

      local session_file
      if [[ "$DRY_RUN" == "true" ]]; then
        session_file=$(mock_claude_session "$dir" "$TEMP_BASE/s$i" "$use_subagents")
        sleep 1
      else
        (cd "$dir" && \
          claude -p "$FEATURE_PROMPT" \
            --model "$MODEL" \
            --effort low \
            --allowedTools "$allowed_tools" \
            --output-format text \
          2>/dev/null) || log "WARNING: claude exited non-zero for $label"

        sleep 3  # Allow JSONL flush to disk

        session_file=$(find_parent_session "$TEMP_BASE/marker_s$i" "$dir") || true
      fi

      local end_sec
      end_sec=$(date +%s)
      local duration=$(( end_sec - start_sec ))

      local breakdown
      local total_weighted=0

      if [[ -n "$session_file" ]]; then
        log "Session: $(basename "$session_file" .jsonl)"
        breakdown=$(extract_session_breakdown "$session_file")
        total_weighted=$(compute_total_weighted "$dir" "$TEMP_BASE/marker_s$i")
      else
        log "WARNING: No session file found for $label"
        breakdown='{"input":0,"output":0,"cache_write":0,"cache_read":0}'
      fi

      local main_total
      main_total=$(echo "$breakdown" | jq '.input + .output + .cache_write + .cache_read')
      local subagent_tokens=$(( total_weighted - main_total ))
      [[ $subagent_tokens -lt 0 ]] && subagent_tokens=0

      echo "$breakdown" | jq \
        --arg lbl      "$label" \
        --arg claude   "${SCENARIO_CLAUDE[$i]}" \
        --arg subag    "${SCENARIO_SUBAG[$i]}" \
        --arg skills   "${SCENARIO_SKILLS[$i]}" \
        --argjson dur  "$duration" \
        --argjson tw   "$total_weighted" \
        --argjson sub_tok "$subagent_tokens" \
        '{
          scenario:            $lbl,
          has_claude_md:       ($claude == "true"),
          has_subagents:       ($subag  == "true"),
          has_skills:          ($skills == "true"),
          input_tokens:        .input,
          output_tokens:       .output,
          cache_write_tokens:  .cache_write,
          cache_read_tokens:   .cache_read,
          subagent_tokens:     $sub_tok,
          total_weighted:      $tw,
          duration_sec:        $dur
        }' > "$result_file"

      log "$label done — weighted: $total_weighted, subagent overhead: $subagent_tokens, time: ${duration}s"
    } > "$log_file" 2>&1
  }

  local SCENARIOS_TO_RUN=(1 2 3 4 5)

  # Run all scenarios concurrently
  for i in "${SCENARIOS_TO_RUN[@]}"; do
    run_scenario "$i" &
  done
  wait

  # Print logs and collect results in order
  for i in "${SCENARIOS_TO_RUN[@]}"; do
    [[ -f "$TEMP_BASE/.log_s${i}.txt" ]] && cat "$TEMP_BASE/.log_s${i}.txt" >&2
    [[ -f "$TEMP_BASE/.result_s${i}.json" ]] && RESULTS+=("$(cat "$TEMP_BASE/.result_s${i}.json")")
  done

  # Write all results at once
  printf '%s\n' "${RESULTS[@]}" | jq -s '.' > "$RESULTS_FILE"

  # ── Phase 4: Print results table ───────────────────────────────────────────
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

  # ── Delta analysis ──────────────────────────────────────────────────────────
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

  # ── Phase 4: Validate ────────────────────────────────────────────────────────
  log ""
  log "=== Phase 4: Validation ==="
  local validate_out="$RESULTS_DIR/validate_${TIMESTAMP}.txt"
  "$SCRIPT_DIR/validate.sh" "$TEMP_BASE" "$RESULTS_FILE" 2>&1 | tee "$validate_out"
  log "Validation report saved: $validate_out"

  echo "Done."
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
