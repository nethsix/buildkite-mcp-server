#!/bin/bash
set -euo pipefail

# Resolve the harness directory so sibling scripts (and the harness copies of
# evals.yaml / prompts) keep resolving after we cd into a separate git checkout
# (the subject under test) below.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The eval matrix. Each entry is one run: agent + model + prompt + scenario +
# mcp_version (+ optional compare base/target). Override with EVALS_CONFIG.
EVALS_CONFIG="${EVALS_CONFIG:-$ROOT_DIR/evals.yaml}"

command -v jq >/dev/null || { echo "babystand: jq is required" >&2; exit 1; }
command -v yq >/dev/null || { echo "babystand: yq is required to parse $EVALS_CONFIG" >&2; exit 1; }
[[ -f "$EVALS_CONFIG" ]] || { echo "babystand: config not found: $EVALS_CONFIG" >&2; exit 1; }

if [[ "${LOCAL_CI}" == "true" ]]; then
  WAIT_STATUS_STRING="(perform local CI)"
else
  WAIT_STATUS_STRING="(patiently check for cloud CI failure status before proceeding with anything. DO NOT VIOLATE THIS)"
fi

if [[ "${DEBUG_PERMISSIONS}" == "true" ]]; then
  DEBUG_STRING=" If you do NOT have permissions to perform something, flag it loudly and BAIL!"
else
  DEBUG_STRING=""
fi

# One timestamp for the whole build; entries are disambiguated by ENTRY_ID.
DATETIME=$(date +%Y-%m-%d-%H%M%S)

if [[ "${RUN_IN_CI:-false}" == "true" ]]; then
  # The CI agent runs in a container built via COPY (mount-checkout=false), so the
  # working directory is not a git checkout. Clone a fresh working copy for the
  # eval (and the agent) to operate on. gh already authenticates from GITHUB_TOKEN
  # in the env; `gh auth setup-git` wires that into git so clone/push work too.
  # (Do NOT `gh auth login --with-token` here: it errors when GITHUB_TOKEN is set.)
  gh auth setup-git

  REPO_SLUG="${EVAL_REPO_SLUG:-nethsix/buildkite-mcp-server}"
  WORKDIR="$HOME/eval-repo-$DATETIME"
  git clone "https://github.com/${REPO_SLUG}.git" "$WORKDIR"
  cd "$WORKDIR"
fi

ORG_SLUG="${BUILDKITE_ORGANIZATION_SLUG:-anothertest}"
PIPELINE_SLUG="${BUILDKITE_PIPELINE_SLUG:-buildkite-mcp-server}"

# Local run bundles live under ./runs/<id>/ (relative to the working dir, i.e. the
# clone in CI). Gitignored. This is the canonical comparison store; in CI we ALSO
# upload the same files as build artifacts (see below).
RUNS_ROOT="$PWD/runs"

echo "*** Initial Env Vars"
echo "***"
echo "*** LOCAL_CI: $LOCAL_CI"
echo "*** DEBUG_PERMISSIONS: $DEBUG_PERMISSIONS"
echo "*** RUN_IN_CI: ${RUN_IN_CI:-false}"
echo "*** EVALS_CONFIG: $EVALS_CONFIG"
echo "*** DATETIME: $DATETIME"
echo "*** ORG_SLUG: $ORG_SLUG"
echo "*** PIPELINE_SLUG: $PIPELINE_SLUG"
echo "***"

# Format a duration in whole seconds as "Nm Ns".
fmt_elapsed() { printf '%dm %ds' $(($1 / 60)) $(($1 % 60)); }

# Render a prompt template: replace {{.KEY}} with VALUE for every KEY=VALUE line
# in the vars file. Line-oriented (values are single-line: urls, branch names).
#   render_prompt <template_file> <vars_file>   -> rendered prompt on stdout
render_prompt() {
    local template="$1" vars="$2" content key val
    content="$(cat "$template")"
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        content="${content//\{\{.$key\}\}/$val}"
    done < "$vars"
    printf '%s' "$content"
}

# annotate_markdown <context> <title> <file> <meta> [style] -- collapsible markdown
annotate_markdown() {
    local context="$1" title="$2" file="$3" meta="$4" style="${5:-info}"
    {
        printf '<details><summary>%s' "$title"
        [[ -n "$meta" ]] && printf ' — %s' "$meta"
        printf '</summary>\n\n'
        if [[ -s "$file" ]]; then cat "$file"; else printf '_(no final output captured)_\n'; fi
        printf '\n\n</details>\n'
    } | buildkite-agent annotate --context "$context" --style "$style" --priority 10 \
        || echo "WARNING: failed to annotate '$context'" >&2
}

# annotate_codeblock <context> <title> <file>  -- plain text, collapsed
annotate_codeblock() {
    local context="$1" title="$2" file="$3"
    if [[ ! -s "$file" ]]; then echo "WARNING: nothing to annotate for '$context'" >&2; return 0; fi
    { printf '<details><summary>%s</summary>\n\n```\n' "$title"; cat "$file"; printf '\n```\n\n</details>\n'; } \
        | buildkite-agent annotate --context "$context" --style info --priority 10 \
        || echo "WARNING: failed to annotate '$context'" >&2
}

# run_claude <rendered_prompt_file> <model> <log_file>  -- runs the agent,
# streaming its output to the build log (via tee), and sets the caller's
# SESSION_ID / TRANSCRIPT / EVAL_RESULT_FILE variables (bash dynamic scoping: the
# caller declares them `local` before calling).
run_claude() {
    local prompt_file="$1" model="$2" log="$3"
    local args=(
        --output-format stream-json --verbose --model "$model"
        --allowedTools "Edit" "Bash(go:*)" "Bash(make:*)" "Bash(git:*)" "mcp__bk_bkbk_ro"
    )
    if [[ "${RUN_IN_CI:-false}" == "true" ]]; then
        # Sandboxed CI execution via claude.sh (owns mcp_in_ci.json, the system
        # prompt, and the parser). The prompt is already rendered, so pass it as a
        # plain prompt file with no KEY=VALUE substitution args. Output streams to
        # the build log; the CLAUDE_* pointers land in $log for recovery below.
        "$SCRIPT_DIR/claude.sh" "$prompt_file" "${args[@]}" | tee "$log"
        SESSION_ID=$(sed -n 's/^CLAUDE_SESSION_ID=//p' "$log" | tail -n1)
        TRANSCRIPT=$(sed -n 's/^CLAUDE_TRANSCRIPT=//p' "$log" | tail -n1)
        EVAL_RESULT_FILE=$(sed -n 's/^CLAUDE_RESULT_FILE=//p' "$log" | tail -n1)
    else
        claude -p "$(cat "$prompt_file")" --mcp-config mcp.json "${args[@]}" | tee "$log"
        SESSION_ID=$(jq -r 'select(.type == "system" and .subtype == "init") | .session_id' "$log" | head -n1)
        TRANSCRIPT="$HOME/.claude/projects/$(pwd | sed -e 's/[\/.]/-/g')/$SESSION_ID.jsonl"
        EVAL_RESULT_FILE="$(mktemp)"
        jq -r 'select(.type == "result") | .result // empty' "$log" > "$EVAL_RESULT_FILE" 2>/dev/null || true
    fi
}

# run_entry <entry_json> -- execute one matrix entry end to end. Best-effort: a
# failure in one entry logs and returns without aborting the rest of the matrix.
run_entry() {
    local entry="$1"
    local ENTRY_ID AGENT MODEL PROMPT_NAME MCP_VERSION SETUP COMPARE_BASE COMPARE_TARGET
    ENTRY_ID=$(jq -r '.id'                    <<<"$entry")
    AGENT=$(jq -r '.agent // "claude"'        <<<"$entry")
    MODEL=$(jq -r '.model // "claude-opus-4-8"' <<<"$entry")
    PROMPT_NAME=$(jq -r '.prompt'             <<<"$entry")
    MCP_VERSION=$(jq -r '.mcp_version // "source"' <<<"$entry")
    SETUP=$(jq -r '.scenario.setup // ""'     <<<"$entry")
    COMPARE_BASE=$(jq -r '.compare_base // ""'   <<<"$entry")
    COMPARE_TARGET=$(jq -r '.compare_target // ""' <<<"$entry")

    echo "+++ :robot_face: Eval entry: $ENTRY_ID"

    if [[ "$AGENT" != "claude" ]]; then
        echo "WARNING: entry '$ENTRY_ID' uses agent '$AGENT' which is not implemented yet; skipping." >&2
        return 0
    fi
    if [[ -n "$MCP_VERSION" && "$MCP_VERSION" != "source" ]]; then
        echo "NOTICE: entry '$ENTRY_ID' requests mcp_version '$MCP_VERSION', which is not yet wired into the image build (follow-up); running the in-image 'source' binary." >&2
    fi

    local RUN_KEY="${ENTRY_ID}-${DATETIME}"
    local RUN_DIR="$RUNS_ROOT/$ENTRY_ID"
    mkdir -p "$RUN_DIR"
    local PREFIX="$RUN_DIR/$RUN_KEY"

    # --- Scenario setup -----------------------------------------------------
    # setup bash may push branches, etc. It exposes values to the prompt by
    # appending KEY=VALUE lines to $SCENARIO_VARS_FILE.
    local SCENARIO_VARS_FILE; SCENARIO_VARS_FILE="$(mktemp)"
    if [[ -n "$SETUP" ]]; then
        echo "--- :gear: [$ENTRY_ID] scenario setup"
        if ! env ENTRY_ID="$ENTRY_ID" DATETIME="$DATETIME" ORG_SLUG="$ORG_SLUG" \
                 PIPELINE_SLUG="$PIPELINE_SLUG" SCENARIO_VARS_FILE="$SCENARIO_VARS_FILE" \
                 bash -c "$SETUP"; then
            echo "WARNING: scenario setup failed for '$ENTRY_ID'; skipping entry." >&2
            return 0
        fi
    fi

    # --- Assemble substitution vars: globals + scenario.vars + setup vars ---
    local VARS_FILE; VARS_FILE="$(mktemp)"
    {
        printf 'ENTRY_ID=%s\n' "$ENTRY_ID"
        printf 'DATETIME=%s\n' "$DATETIME"
        printf 'ORG_SLUG=%s\n' "$ORG_SLUG"
        printf 'PIPELINE_SLUG=%s\n' "$PIPELINE_SLUG"
        printf 'WAIT_STATUS=%s\n' "$WAIT_STATUS_STRING"
        printf 'DEBUG_STRING=%s\n' "$DEBUG_STRING"
        jq -r '.scenario.vars // {} | to_entries[] | "\(.key)=\(.value)"' <<<"$entry"
        cat "$SCENARIO_VARS_FILE"
    } > "$VARS_FILE"

    # --- Render the prompt --------------------------------------------------
    local TEMPLATE="$ROOT_DIR/prompts/$PROMPT_NAME.md"
    if [[ ! -f "$TEMPLATE" ]]; then
        echo "WARNING: prompt template not found for '$ENTRY_ID': $TEMPLATE; skipping." >&2
        return 0
    fi
    local RENDERED; RENDERED="$(mktemp)"
    render_prompt "$TEMPLATE" "$VARS_FILE" > "$RENDERED"
    echo "--- :scroll: [$ENTRY_ID] rendered prompt"
    cat "$RENDERED"; echo

    # --- Run the agent ------------------------------------------------------
    local LOG="/tmp/babystand-$RUN_KEY.log"
    local SESSION_ID="" TRANSCRIPT="" EVAL_RESULT_FILE=""   # set by run_claude (dynamic scope)
    local EVAL_START; EVAL_START=$(date +%s)
    run_claude "$RENDERED" "$MODEL" "$LOG"
    local EVAL_ELAPSED; EVAL_ELAPSED=$(fmt_elapsed $(( $(date +%s) - EVAL_START )))
    echo "*** [$ENTRY_ID] EVAL ELAPSED: $EVAL_ELAPSED  SESSION_ID: $SESSION_ID"
    echo "*** [$ENTRY_ID] TRANSCRIPT: $TRANSCRIPT"

    # --- Audit: tools + metrics --------------------------------------------
    local AUDIT_TOOLS_FILE AUDIT_METRICS_FILE
    AUDIT_TOOLS_FILE="$(mktemp)"; AUDIT_METRICS_FILE="$(mktemp)"
    echo "--- :hammer_and_wrench: [$ENTRY_ID] tool calls"
    "$SCRIPT_DIR/bk-tool-audit-v2.sh" --all "$TRANSCRIPT" | tee "$AUDIT_TOOLS_FILE" || true
    echo "--- :bar_chart: [$ENTRY_ID] session metrics"
    "$SCRIPT_DIR/bk-tool-audit-v2.sh" metrics "$TRANSCRIPT" | tee "$AUDIT_METRICS_FILE" || true

    # --- Klaren review (best-effort) ---------------------------------------
    echo "--- :female-detective: [$ENTRY_ID] klaren review"
    local KLAREN_LOG="/tmp/klaren-$RUN_KEY.log"
    local KLAREN_PROMPT_FILE KLAREN_RESULT_FILE=""
    KLAREN_PROMPT_FILE="$(mktemp)"
    {
        cat "$ROOT_DIR/prompts/klaren.md"
        echo
        echo "The LLM session log file to analyze is: $TRANSCRIPT"
    } > "$KLAREN_PROMPT_FILE"
    local KLAREN_ARGS=( --output-format stream-json --verbose --allowedTools "Read" "Grep" "Glob" "Bash" )
    local KLAREN_START; KLAREN_START=$(date +%s)
    if [[ "${RUN_IN_CI:-false}" == "true" ]]; then
        if ! "$SCRIPT_DIR/claude.sh" "$KLAREN_PROMPT_FILE" "${KLAREN_ARGS[@]}" | tee "$KLAREN_LOG"; then
            echo "WARNING: klaren review failed for '$ENTRY_ID'" >&2
        fi
        KLAREN_RESULT_FILE=$(sed -n 's/^CLAUDE_RESULT_FILE=//p' "$KLAREN_LOG" | tail -n1)
    else
        if ! claude -p "$(cat "$KLAREN_PROMPT_FILE")" --mcp-config mcp.json "${KLAREN_ARGS[@]}" | tee "$KLAREN_LOG"; then
            echo "WARNING: klaren review failed for '$ENTRY_ID'" >&2
        fi
        KLAREN_RESULT_FILE="$(mktemp)"
        jq -r 'select(.type == "result") | .result // empty' "$KLAREN_LOG" > "$KLAREN_RESULT_FILE" 2>/dev/null || true
    fi
    local KLAREN_ELAPSED; KLAREN_ELAPSED=$(fmt_elapsed $(( $(date +%s) - KLAREN_START )))
    echo "*** [$ENTRY_ID] KLAREN ELAPSED: $KLAREN_ELAPSED"

    # --- Write the run bundle to ./runs/<id>/<id>-<datetime>.<ext> ----------
    [[ -s "$EVAL_RESULT_FILE"   ]] && cp "$EVAL_RESULT_FILE"   "$PREFIX.eval-final.md"     || : > "$PREFIX.eval-final.md"
    [[ -s "$AUDIT_METRICS_FILE" ]] && cp "$AUDIT_METRICS_FILE" "$PREFIX.metrics.json"      || : > "$PREFIX.metrics.json"
    [[ -s "$AUDIT_TOOLS_FILE"   ]] && cp "$AUDIT_TOOLS_FILE"   "$PREFIX.tools.txt"         || : > "$PREFIX.tools.txt"
    [[ -s "$KLAREN_RESULT_FILE" ]] && cp "$KLAREN_RESULT_FILE" "$PREFIX.klaren.md"         || : > "$PREFIX.klaren.md"
    [[ -s "$TRANSCRIPT"         ]] && cp "$TRANSCRIPT"         "$PREFIX.transcript.jsonl"  || true
    echo "*** [$ENTRY_ID] run bundle: $PREFIX.*"

    # --- CI: upload the bundle as build artifacts (dual store) + annotate ---
    if [[ "${RUN_IN_CI:-false}" == "true" ]]; then
        # runs/ is relative to the working dir (the clone), which is cwd.
        buildkite-agent artifact upload "runs/$ENTRY_ID/$RUN_KEY.*" \
            || echo "WARNING: failed to upload run bundle for '$ENTRY_ID'" >&2

        annotate_markdown "eval-final-$ENTRY_ID"  ":robot_face: [$ENTRY_ID] Eval — final output" \
            "$PREFIX.eval-final.md" "⏱️ Elapsed: ${EVAL_ELAPSED}" "success"
        annotate_codeblock "eval-metrics-$ENTRY_ID" ":bar_chart: [$ENTRY_ID] Eval — session metrics" "$PREFIX.metrics.json"
        annotate_codeblock "eval-tools-$ENTRY_ID"   ":hammer_and_wrench: [$ENTRY_ID] Eval — tool calls" "$PREFIX.tools.txt"
        annotate_markdown "klaren-final-$ENTRY_ID"   ":female-detective: [$ENTRY_ID] Klaren — session review" \
            "$PREFIX.klaren.md" "⏱️ Elapsed: ${KLAREN_ELAPSED}"
    fi

    # --- Compare against the baseline (best-effort) -------------------------
    echo "--- :scales: [$ENTRY_ID] comparison"
    ENTRY_ID="$ENTRY_ID" \
    RUN_KEY="$RUN_KEY" \
    RUN_DIR="$RUN_DIR" \
    CUR_EVAL="$PREFIX.eval-final.md" \
    CUR_METRICS="$PREFIX.metrics.json" \
    CUR_TOOLS="$PREFIX.tools.txt" \
    CUR_KLAREN="$PREFIX.klaren.md" \
    COMPARE_BASE="$COMPARE_BASE" \
    COMPARE_TARGET="$COMPARE_TARGET" \
        "$SCRIPT_DIR/bk-eval-compare.sh" \
        || echo "WARNING: comparison failed for '$ENTRY_ID'" >&2
}

# --- Drive the matrix -------------------------------------------------------
MATRIX_JSON="$(yq -o=json '.matrix' "$EVALS_CONFIG")"
ENTRY_COUNT="$(jq 'length' <<<"$MATRIX_JSON")"
echo "*** Matrix entries: $ENTRY_COUNT"
[[ "$ENTRY_COUNT" -gt 0 ]] || { echo "babystand: matrix is empty; nothing to run." >&2; exit 0; }

for i in $(seq 0 $((ENTRY_COUNT - 1))); do
    entry="$(jq -c ".[$i]" <<<"$MATRIX_JSON")"
    # Never let one entry abort the rest of the matrix.
    run_entry "$entry" || echo "WARNING: entry index $i failed" >&2
done
