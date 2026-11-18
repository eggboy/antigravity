#!/bin/bash
# shellcheck shell=bash

# Lint Enforcer Hook — Antigravity `Stop` lifecycle event
#
# Runs the canonical formatter + linter for each toolchain present in the
# workspace when the agent's execution loop terminates (end of turn).
# Pure bash + jq. The idle path (nothing relevant changed) costs two forks:
# one jq to read the payload and one `git status`. The only thing written is
# a small per-workspace state file under $TMPDIR (last verdict + status) that
# lets idle turns skip the linters; the host owns the audit trail
# (transcript), so the hook keeps no log of its own.
#
# Antigravity contract (jetski-customizations/docs/hooks.md):
#   * Event `Stop` (flat handler list). The host runs the command with the
#     working directory set to the directory containing hooks.json, so the
#     project roots come from the payload's `workspacePaths` — every entry is
#     linted (multi-root aware; a root may be a sub-directory of a git repo).
#   * stdin : JSON — workspacePaths, terminationReason, executionNum, ...
#   * stdout: exactly one JSON object, always (an invalid verdict is a host
#     error that is shown to the user):
#       {}                                     let the agent stop
#       {"decision":"continue","reason":...}   re-enter the loop; the reason
#         (machine tag, headline, failing tools, tail of their output) is
#         injected as a system message so the agent fixes the findings.
#   * stderr: diagnostics only — captured by the host, not shown on success.
#
# Posture: lint is a best-effort control, so the hook fails OPEN. Missing jq,
# an unparseable payload, an unreadable workspace, a missing linter or a
# crashing tool all end in {} — never in a non-zero exit, never in a hang
# (per-tool timeouts capped by a shared LINT_ENFORCER_BUDGET_SEC deadline,
# kept under the hooks.json 300s timeout so gathered findings still emit
# before the host fails open; raise both together). Verdict is deterministic
# given the working tree and state files, never wall-clock debounced.
#
# Fast path, per workspace (each step returns early):
#   L0  SKIP env, payload (one jq), terminationReason gate, SKIP_DIRS
#   L1  toolchain marker globs                              no fork
#   L2  `git status --porcelain -z -uall -- .` empty        one fork
#   L4  per-toolchain changed-file lists empty              no fork (1 find w/o git)
#   L3  same status, no dirty file newer, clean/deduped     one find
#   L5  linters, scoped to changed files
#
# Scope: formatters and checks receive only the files changed in the working
# tree (git: modified, staged, rename targets, untracked in new dirs; deletions
# and paths outside the workspace dropped) or modified since the last run (no
# git; all matching files on the first run, and only implicated failing files
# carried across runs). Exception: spring-javaformat has no file filter and
# runs project-wide; Spotless uses -DspotlessFiles.
#
# Modes:
#   block (default) enforcement: on findings answer decision:continue, but
#                   only for a normal completion (NO_TOOL_CALL) and while
#                   executionNum <= LINT_ENFORCER_MAX_CONTINUES, so a fix
#                   loop that never converges cannot trap the agent. Identical
#                   findings already sent in a previous continue are hashed in
#                   <key>.findings, downgraded to stderr ({}), and marked
#                   failed_sent so later unchanged Stops skip L5 at L3 until a
#                   file changes; a clean tree or clean pass resets the hash.
#                   Unsent findings (warn / non-normal stop) stay failed and
#                   enforce on the next normal Stop.
#   warn            evaluate-only: autofix runs, findings go to stderr, the
#                   answer is {} — not enforcement.
#
# Env vars (hooks.json has no env field — prefix the command string, e.g.
# `LINT_ENFORCER_SKIP_DIRS='~/repo-a:~/repo-b' bash ./lint-enforcer/lint-enforcer.sh`):
#   SKIP_LINT_ENFORCER           true to disable entirely
#   LINT_ENFORCER_SKIP_DIRS      colon list of dirs to skip (and subdirs; leading ~ = $HOME)
#   LINT_ENFORCER_MODE           block|warn                 (default: block)
#   LINT_ENFORCER_LANGS          comma list                 (default: spring_maven,python_uv,terraform,dockerfile,github_actions)
#   LINT_ENFORCER_SKIP_AUTOFIX   true to skip the formatter step (check only)
#   LINT_ENFORCER_TIMEOUT_SEC    per-tool override          (defaults: mvn 240, ruff 30, tf 60, hadolint 30, actionlint 30)
#   LINT_ENFORCER_BUDGET_SEC     shared deadline across all tool calls; keep < hooks.json timeout (default: 280)
#   LINT_ENFORCER_MAX_CONTINUES  block: forced continues per turn (default: 3, 0 = never force)
#   LINT_ENFORCER_EXCERPT_CHARS  block: tail of linter output quoted in the reason (default: 3000, 0 = none)
#   LINT_ENFORCER_STATE_DIR      state files                (default: $TMPDIR/antigravity-lint-enforcer)
#   LINT_ENFORCER_DEBUG          true to print the layer trace to stderr
#
# Manual run: `cd <project> && LINT_ENFORCER_DEBUG=true bash lint-enforcer.sh`
# from an interactive shell lints $PWD and prints the layer trace.

set -uo pipefail

# Output contract: exactly one JSON object on the host's stdout, on every
# exit path. fd 3 is the host; the script's own stdout is folded into stderr
# so a chatty tool can never corrupt the JSON.
exec 3>&1 1>&2
DECIDED=0
# shellcheck disable=SC2329  # invoked via the EXIT trap
emit_noop() { (( DECIDED )) || { printf '{}\n' >&3; DECIDED=1; }; }
trap emit_noop EXIT

# ---------------------------------------------------------------------------
# L0: instant bail-out + configuration
# ---------------------------------------------------------------------------
[[ "${SKIP_LINT_ENFORCER:-}" == "true" ]] && exit 0

SECONDS=0
SKIP_DIRS="${LINT_ENFORCER_SKIP_DIRS:-}"
MODE="${LINT_ENFORCER_MODE:-block}"
LANGS_CSV="${LINT_ENFORCER_LANGS:-spring_maven,python_uv,terraform,dockerfile,github_actions}"
MAX_CONTINUES="${LINT_ENFORCER_MAX_CONTINUES:-3}"
EXCERPT_CHARS="${LINT_ENFORCER_EXCERPT_CHARS:-3000}"
BUDGET_SEC="${LINT_ENFORCER_BUDGET_SEC:-280}"
STATE_DIR="${LINT_ENFORCER_STATE_DIR:-${TMPDIR:-/tmp}/antigravity-lint-enforcer}"
DEBUG="${LINT_ENFORCER_DEBUG:-}"
SKIP_AUTOFIX="${LINT_ENFORCER_SKIP_AUTOFIX:-}"
TIMEOUT_OVERRIDE="${LINT_ENFORCER_TIMEOUT_SEC:-}"

case "$MODE" in warn|block) ;; *) MODE="block" ;; esac
[[ "$MAX_CONTINUES" =~ ^[0-9]+$ ]] || MAX_CONTINUES=3
[[ "$EXCERPT_CHARS" =~ ^[0-9]+$ ]] || EXCERPT_CHARS=3000
[[ "$BUDGET_SEC" =~ ^[0-9]+$ ]] || BUDGET_SEC=280

trace() { [[ -n "$DEBUG" ]] && printf '[lint-enforcer] %s\n' "$*" >&2; }
note()  { printf '[lint-enforcer] %s\n' "$*" >&2; }

command -v jq &>/dev/null || { trace "L0: jq not on PATH; exit"; exit 0; }

TIMEOUT_BIN=""
if command -v timeout &>/dev/null; then TIMEOUT_BIN="timeout"
elif command -v gtimeout &>/dev/null; then TIMEOUT_BIN="gtimeout"
fi

# ---------------------------------------------------------------------------
# L0: payload — one jq call. An interactive shell (no payload) lints $PWD;
# a non-interactive caller that sends nothing gets {}.
# ---------------------------------------------------------------------------
TERM_REASON=""; EXEC_NUM=1; WORKSPACES=()
if [[ -t 0 ]]; then
  WORKSPACES=("$PWD")
else
  INPUT=""
  IFS= read -r -d '' INPUT || true
  [[ -z "$INPUT" ]] && { trace "L0: empty payload; exit"; exit 0; }
  _parsed=$(jq -r '
    (.terminationReason // ""),
    ((.executionNum // 1) | tostring),
    ((.workspacePaths // []) | .[] | strings)' <<< "$INPUT" 2>/dev/null) || _parsed=""
  [[ -z "$_parsed" ]] && { trace "L0: unparseable payload; exit"; exit 0; }
  _i=0
  while IFS= read -r _line; do
    case $_i in
      0) TERM_REASON="$_line" ;;
      1) EXEC_NUM="$_line" ;;
      *) [[ -n "$_line" ]] && WORKSPACES+=("$_line") ;;
    esac
    _i=$((_i + 1))
  done <<< "$_parsed"
fi
[[ "$EXEC_NUM" =~ ^[0-9]+$ ]] || EXEC_NUM=1
(( ${#WORKSPACES[@]} == 0 )) && { trace "L0: payload has no workspacePaths; exit"; exit 0; }

# ---------------------------------------------------------------------------
# L0: terminationReason gate
#   USER_CANCELED            the user wants out — don't even run the linters.
#   NO_TOOL_CALL (or empty)  normal turn completion — block mode may continue.
#   anything else            MAX_INVOCATIONS, ERROR, TERMINAL_STEP_TYPE (the
#                            agent is waiting on the user), budget limits...
#                            Still lint (autofix) but never force the loop to
#                            re-enter against the executor's decision; a
#                            failing verdict is remembered for the next
#                            enforceable Stop.
# Matched case-insensitively; MODEL_STOP is the name used by some public docs.
# ---------------------------------------------------------------------------
CAN_CONTINUE=0
shopt -s nocasematch
case "$TERM_REASON" in
  USER_CANCELED|USER_CANCELLED)
    shopt -u nocasematch
    trace "L0: terminationReason=$TERM_REASON; skip"; exit 0 ;;
  ""|NO_TOOL_CALL|MODEL_STOP) CAN_CONTINUE=1 ;;
  *) trace "L0: terminationReason=$TERM_REASON; will not force continue" ;;
esac
shopt -u nocasematch
if [[ "$MODE" == "block" ]] && (( EXEC_NUM > MAX_CONTINUES )); then
  trace "L0: executionNum=$EXEC_NUM > max continues $MAX_CONTINUES; will not force continue"
  CAN_CONTINUE=0
fi
# Enforcing now = block mode on an enforceable stop. Decides whether an
# unchanged-but-failing workspace is re-linted or left alone.
ENFORCING=0
[[ "$MODE" == "block" ]] && (( CAN_CONTINUE )) && ENFORCING=1

trace "mode=$MODE langs=$LANGS_CSV term=$TERM_REASON exec=$EXEC_NUM enforcing=$ENFORCING workspaces=${#WORKSPACES[@]}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# True when $1 (logical workspace path) or $2 (physical $PWD) is an entry of
# colon-separated $SKIP_DIRS or below one. Uses a string loop (no array) so
# empty/sparse lists stay safe on bash 3.2 under `set -u`.
in_skip_dirs() {
  [[ -z "$SKIP_DIRS" ]] && return 1
  local logical="$1" phys="$2" rest="${SKIP_DIRS}:" d dp
  while [[ "$logical" == */ && "$logical" != "/" ]]; do logical="${logical%/}"; done
  while [[ -n "$rest" ]]; do
    d="${rest%%:*}"
    rest="${rest#*:}"
    [[ -z "$d" ]] && continue
    case "$d" in
      \~)    [[ -n "${HOME:-}" ]] || continue; d="$HOME" ;;
      \~/*)  [[ -n "${HOME:-}" ]] || continue; d="${HOME%/}/${d:2}" ;;
    esac
    while [[ "$d" == */ && "$d" != "/" ]]; do d="${d%/}"; done
    [[ -z "$d" ]] && continue
    if [[ "$d" == "/" || "$phys" == "$d" || "$phys" == "$d/"* \
       || "$logical" == "$d" || "$logical" == "$d/"* ]]; then
      return 0
    fi
    if [[ -d "$d" ]]; then
      dp=$(cd -P "$d" 2>/dev/null && pwd) || dp=""
      if [[ -n "$dp" && ( "$dp" == "/" || "$phys" == "$dp" || "$phys" == "$dp/"* ) ]]; then
        return 0
      fi
    fi
  done
  return 1
}

# Fork-free key for the per-workspace state file: a sanitized tail of the
# path plus a 32-bit checksum of the whole path, so distinct workspaces that
# sanitize alike (or exceed NAME_MAX) still get distinct files. Sets $KEY.
state_key() {
  local p="$1" h=0 i c tail
  for (( i = 0; i < ${#p}; i++ )); do
    printf -v c '%d' "'${p:i:1}"
    h=$(( (h * 31 + c) & 0xFFFFFFFF ))
  done
  tail="${p//[^A-Za-z0-9._-]/_}"
  (( ${#tail} > 100 )) && tail="${tail:${#tail}-100}"
  printf -v KEY '%s.%08x' "$tail" "$h"
}

hash_str() {
  local out
  if command -v shasum &>/dev/null; then out=$(shasum)
  elif command -v sha1sum &>/dev/null; then out=$(sha1sum)
  else out=$(cksum)
  fi
  printf '%s' "${out%% *}"
}

# State file = "<clean|failed|failed_sent>\n<status text>". Last writer wins;
# a torn concurrent read can only differ from the live status, which means
# one extra lint pass — never a wrong skip.
save_state() { printf '%s\n%s' "$1" "$PORC" > "$STATE_FILE" 2>/dev/null || true; }

# May an unchanged workspace be skipped, given the previous verdict?
#   clean | failed_sent                  → yes (clean, or already deduped)
#   failed, but not enforcing right now  → yes (nothing new to say)
#   failed and enforcing                 → no: lint once more to re-enforce / dedupe
#   no / unknown state                   → no
idle_skip() {
  case "$PREV_VERDICT" in
    clean|failed_sent) return 0 ;;
    failed)            (( ENFORCING == 0 )) ;;
    *)                 return 1 ;;
  esac
}

# All tool calls share one deadline (BUDGET_SEC from script start), kept under
# the hooks.json timeout: a host timeout fails open and drops every finding
# gathered so far. Once spent, remaining calls are skipped and report 124.
run_with_timeout() {
  local secs="$1" left=$(( BUDGET_SEC - SECONDS )); shift
  if (( left < 1 )); then
    printf '[lint-enforcer] skipped %s; the %ss time budget is used up\n' "$1" "$BUDGET_SEC" >&2
    return 124
  fi
  (( secs > left )) && secs=$left
  if [[ -n "$TIMEOUT_BIN" ]]; then "$TIMEOUT_BIN" "$secs" "$@"; else "$@"; fi
}

# capture <timeout> <cmd...>: run a tool, keep its combined output in $OUT
# and exit code in $LAST_RC, return its exit status.
capture() {
  OUT=$(run_with_timeout "$@" 2>&1)
  LAST_RC=$?
  return $LAST_RC
}

# sanitize_out <text>: strip ANSI escapes, invalid UTF-8 bytes, and non-space
# ASCII control chars so JSON and terminal diagnostics stay clean on macOS/Linux.
sanitize_out() {
  local s
  s=$(printf '%s' "$1" \
    | LC_ALL=C sed $'s/\033\\[[0-9;]*[A-Za-z]//g' \
    | { if command -v iconv &>/dev/null; then iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true; else cat; fi; } \
    | LC_ALL=C tr -d '\001-\010\013\014\016-\037')
  printf '%s' "$s"
}

# fail <category> [rc]: record a finding for the current workspace with $OUT.
fail() {
  local label="$1" rc="${2:-$LAST_RC}" clean_out body=""
  clean_out=$(sanitize_out "$OUT")
  WS_FAILURES+=("$label")
  WS_SIG+="## $label $rc$NL$clean_out$NL"
  case "$CUR_TC" in
    spring) FAIL_SPRING=1; (( rc == 124 )) && TO_SPRING=1; OUT_SPRING+="${OUT_SPRING:+$NL}$clean_out" ;;
    py)     FAIL_PY=1;     (( rc == 124 )) && TO_PY=1;     OUT_PY+="${OUT_PY:+$NL}$clean_out" ;;
    tf)     FAIL_TF=1;     (( rc == 124 )) && TO_TF=1;     OUT_TF+="${OUT_TF:+$NL}$clean_out" ;;
    docker) FAIL_DOCKER=1; (( rc == 124 )) && TO_DOCKER=1; OUT_DOCKER+="${OUT_DOCKER:+$NL}$clean_out" ;;
    gha)    FAIL_GHA=1;    (( rc == 124 )) && TO_GHA=1;    OUT_GHA+="${OUT_GHA:+$NL}$clean_out" ;;
  esac
  local hdr="--- $label"
  (( ${#WORKSPACES[@]} > 1 )) && hdr+=" @ ${HOOK_CWD##*/}"
  (( rc == 124 )) && body="(timed out; output may be partial)"
  if [[ -n "$clean_out" ]]; then
    body+="${body:+$NL}$clean_out"
  elif (( rc != 124 )); then
    body="(no output; exit $rc)"
  fi
  WS_DETAILS+="${WS_DETAILS:+$NL}$hdr ---$NL$body"
  note "$label"
}

# True when $2 (relative path or basename) appears in $1 bounded by characters
# outside [A-Za-z0-9._-], avoiding substring false positives (a.tf in data.tf).
mentions_name() {
  local s="$1" needle="$2" pre post
  [[ -n "$s" && -n "$needle" ]] || return 1
  while [[ "$s" == *"$needle"* ]]; do
    pre="${s%%"$needle"*}"
    post="${s:${#pre}+${#needle}:1}"
    if [[ ( -z "$pre" || ! "${pre:${#pre}-1:1}" =~ [A-Za-z0-9._-] ) \
       && ( -z "$post" || ! "$post" =~ [A-Za-z0-9._-] ) ]]; then
      return 0
    fi
    s="${s:${#pre}+1}"
  done
  return 1
}

# For a failing no-git toolchain, append implicated files (without "./") from
# $@ to $IMPLICATED; fall back to all $@ on timeout (124) or unattributed output.
collect_implicated() {
  local timed_out="$1" tc_out="$2" f rel base matched=()
  shift 2
  if (( !timed_out )) && [[ -n "$tc_out" ]]; then
    for f in "$@"; do
      rel="${f#./}"
      base="${rel##*/}"
      if mentions_name "$tc_out" "$rel" || mentions_name "$tc_out" "$base"; then
        matched+=("$rel")
      fi
    done
  fi
  if (( ${#matched[@]} > 0 )); then
    for rel in "${matched[@]}"; do IMPLICATED+=("$rel"); done
  else
    for f in "$@"; do IMPLICATED+=("${f#./}"); done
  fi
}

# Directory walks (no-git mtime gate) prune heavy dirs by name at any depth
# and are bounded to 10s so a misfire on a huge tree can't block Stop for
# minutes; on timeout they print nothing, the safe bias.
PRUNE=( \( -name .git -o -name node_modules -o -name vendor
           -o -name .venv -o -name venv -o -name .tox
           -o -name target -o -name build -o -name dist
           -o -name .gradle -o -name .mvn -o -name .terraform
           -o -name .next -o -name .cache
           -o -name Library -o -name .Trash -o -name .npm
           -o -name .nvm -o -name .rustup -o -name .cargo \) -prune -o )

# Add a workspace-relative path to per-toolchain changed-file lists. Leading
# "./" prevents filenames starting with "-" from being read as CLI flags.
add_path() {
  local p="$1" rel="./$1" hit=0 x
  [[ -f "$rel" ]] || return 0   # drop deletions, directories, submodules
  for x in ${RELEVANT[@]+"${RELEVANT[@]}"}; do [[ "$x" == "$rel" ]] && return 0; done
  case "$p" in
    *.java)        (( WANT_SPRING )) && { JAVA_FILES+=("$rel"); hit=1; } ;;
    *.py)          (( WANT_PY ))     && { PY_FILES+=("$rel");   hit=1; } ;;
    *.tf|*.tfvars) (( WANT_TF ))     && { TF_FILES+=("$rel");   hit=1; } ;;
    .github/workflows/*.yml|.github/workflows/*.yaml)
      # actionlint reads only top-level workflow files.
      [[ "${p#.github/workflows/}" != */* ]] && (( WANT_GHA )) && { GHA_FILES+=("$rel"); hit=1; } ;;
  esac
  if (( WANT_DOCKER )); then
    case "${p##*/}" in
      Dockerfile|Dockerfile.*|Containerfile|Containerfile.*) DOCKER_FILES+=("$rel"); hit=1 ;;
    esac
  fi
  (( hit )) && RELEVANT+=("$rel")
  return 0
}

# Read NUL-delimited `git status --porcelain -z -uall -- .` into $PORC; when
# $1 == 1, also rebase repo-root paths onto $PWD and populate changed-file lists.
collect_git_status() {
  local collect="${1:-0}" entry src p
  PORC=""
  while IFS= read -r -d '' entry; do
    PORC+="$entry$NL"
    # A rename or copy entry is followed by a second NUL field: the old path.
    if [[ "${entry:0:2}" == *[RC]* ]]; then
      IFS= read -r -d '' src && PORC+="$src$NL"
    fi
    (( collect )) || continue
    p="${entry:3}"
    if [[ -n "$GIT_PREFIX" ]]; then
      [[ "$p" == "$GIT_PREFIX"* ]] || continue
      p="${p#"$GIT_PREFIX"}"
    fi
    add_path "$p"
  done < <(git -c color.status=false status --porcelain -z -uall -- . 2>/dev/null)
}

# Collect files matching enabled toolchains via pruned `find`; pass `-newer
# "$STATE_FILE"` args when incremental.
collect_nogit_files() {
  local expr=() p
  (( WANT_SPRING )) && expr+=( ${expr[@]+-o} -name '*.java' )
  (( WANT_PY ))     && expr+=( ${expr[@]+-o} -name '*.py' )
  (( WANT_TF ))     && expr+=( ${expr[@]+-o} -name '*.tf' -o -name '*.tfvars' )
  (( WANT_DOCKER )) && expr+=( ${expr[@]+-o} -name Dockerfile -o -name 'Dockerfile.*' -o -name Containerfile -o -name 'Containerfile.*' )
  (( WANT_GHA ))    && expr+=( ${expr[@]+-o} -path './.github/workflows/*.yml' -o -path './.github/workflows/*.yaml' )
  (( ${#expr[@]} )) || return 0
  while IFS= read -r -d '' p; do
    add_path "${p#./}"
  done < <(run_with_timeout 10 find . "${PRUNE[@]}" -type f \( "${expr[@]}" \) "$@" -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# L5: linters (run from $HOOK_CWD, scoped to changed files). Missing tool → skip.
# ---------------------------------------------------------------------------
run_spring() {
  command -v mvn &>/dev/null || { note "[spring] mvn not on PATH; skip"; return 0; }
  local t="${TIMEOUT_OVERRIDE:-240}" apply check scope=()
  # $POM was read in L1. Spotless scopes via -DspotlessFiles; spring-javaformat
  # has no file filter and stays project-wide.
  if [[ $POM == *spotless-maven-plugin* ]]; then
    apply="spotless:apply"; check="spotless:check"
    # Spotless matches comma-separated regexes against full paths. $PWD is
    # physical (cd -P); add logical $HOOK_CWD too if symlinked.
    local roots=("$PWD") logical="$HOOK_CWD" f r pats=""
    while [[ "$logical" == */ && "$logical" != "/" ]]; do logical="${logical%/}"; done
    [[ "$logical" == /* && "$logical" != "$PWD" ]] && roots+=("$logical")
    for f in "${JAVA_FILES[@]}"; do
      for r in "${roots[@]}"; do pats+="${pats:+,}\\Q$r/${f#./}\\E"; done
    done
    scope=("-DspotlessFiles=$pats")
  else
    apply="spring-javaformat:apply"; check="spring-javaformat:validate"
  fi
  # apply formats everything check would flag, so a successful apply is the
  # verdict; the second JVM is only needed in check-only mode.
  if [[ -z "$SKIP_AUTOFIX" ]]; then
    capture "$t" mvn -q -B "$apply" ${scope[@]+"${scope[@]}"} || fail "mvn $apply failed"
  else
    capture "$t" mvn -q -B "$check" ${scope[@]+"${scope[@]}"} \
      || fail "mvn $check reported violations (fix: mvn $apply)"
  fi
}

run_python() {
  local t="${TIMEOUT_OVERRIDE:-30}" ruff=()
  # ruff from the project environment, else a system ruff; neither → skip
  # (uv alone is not enough: `uv run ruff` fails closed when ruff is absent).
  if command -v uv &>/dev/null; then
    if capture 10 uv run --no-sync ruff --version; then
      ruff=(uv run --no-sync ruff)
    elif (( LAST_RC == 124 )); then
      fail "ruff check reported issues" 124; return 0
    fi
  fi
  if (( ${#ruff[@]} == 0 )); then
    if command -v ruff &>/dev/null; then
      ruff=(ruff)
    else
      note "[python] ruff not available (uv run ruff / ruff); skip"; return 0
    fi
  fi
  # --force-exclude keeps ruff's exclude settings active on explicit file args.
  # Fix before format, as ruff recommends, so the formatter tidies the fixes.
  if [[ -z "$SKIP_AUTOFIX" ]]; then
    run_with_timeout "$t" "${ruff[@]}" check --fix --force-exclude "${PY_FILES[@]}" >/dev/null 2>&1 || true
    capture "$t" "${ruff[@]}" format --force-exclude "${PY_FILES[@]}" || fail "ruff format failed"
  fi
  capture "$t" "${ruff[@]}" check --force-exclude "${PY_FILES[@]}" || fail "ruff check reported issues"
}

run_terraform() {
  command -v terraform &>/dev/null || { note "[terraform] terraform not on PATH; skip"; return 0; }
  local t="${TIMEOUT_OVERRIDE:-60}" f d x fmt_rc=0 out="" dirs=()
  # One file per call: older terraform releases accept a single target.
  if [[ -z "$SKIP_AUTOFIX" ]]; then
    for f in "${TF_FILES[@]}"; do
      run_with_timeout "$t" terraform fmt "$f" >/dev/null 2>&1 || true
    done
  fi
  for f in "${TF_FILES[@]}"; do
    capture "$t" terraform fmt -check -diff "$f"
    if (( LAST_RC != 0 )); then fmt_rc=$LAST_RC; out+="${out:+$NL}$OUT"; fi
  done
  if (( fmt_rc != 0 )); then
    OUT="$out"
    fail "terraform fmt reported drift" "$fmt_rc"
  fi
  if command -v tflint &>/dev/null; then
    # tflint lints a module (directory), so run it once per changed dir.
    for f in "${TF_FILES[@]}"; do
      d="${f%/*}"
      for x in ${dirs[@]+"${dirs[@]}"}; do [[ "$x" == "$d" ]] && continue 2; done
      dirs+=("$d")
      capture "$t" tflint --chdir="$d" || fail "tflint reported issues ($d)"
    done
  fi
}

run_docker() {
  command -v hadolint &>/dev/null || { note "[docker] hadolint not on PATH; skip"; return 0; }
  capture "${TIMEOUT_OVERRIDE:-30}" hadolint "${DOCKER_FILES[@]}" || fail "hadolint reported issues"
}

run_actions() {
  command -v actionlint &>/dev/null || { note "[github_actions] actionlint not on PATH; skip"; return 0; }
  capture "${TIMEOUT_OVERRIDE:-30}" actionlint "${GHA_FILES[@]}" || fail "actionlint reported issues"
}

# ---------------------------------------------------------------------------
# One workspace: L0 (SKIP_DIRS) → L5. Always returns 0; appends enforceable
# findings to FAILURES/DETAILS/REASON.
# ---------------------------------------------------------------------------
lint_workspace() {
  HOOK_CWD="$1"
  cd -P "$HOOK_CWD" 2>/dev/null || { trace "cd $HOOK_CWD failed; skip"; return 0; }
  # Refuse non-project roots: firing on $HOME or / would glob-trip L1 on
  # unrelated subtrees or walk the whole home tree in the no-git gate.
  if [[ "$PWD" == "/" || "$PWD" -ef "${HOME:-/nonexistent}" ]]; then
    trace "L0: refusing to lint non-project dir $HOOK_CWD"; return 0
  fi
  if in_skip_dirs "$HOOK_CWD" "$PWD"; then
    trace "L0: $HOOK_CWD matched LINT_ENFORCER_SKIP_DIRS; skip"; return 0
  fi
  trace "cwd=$HOOK_CWD"

  # -------------------------------------------------------------------------
  # L1: marker checks — pure bash, no fork. Globs reach two levels deep
  # (./infra/*.tf, ./services/api/Dockerfile); literal words keep the arrays
  # non-empty under set -u on bash 3.2.
  # -------------------------------------------------------------------------
  HAS_POM=0; [[ -f pom.xml ]] && HAS_POM=1
  HAS_PY=0;  [[ -f pyproject.toml ]] && HAS_PY=1
  shopt -s nullglob
  _tf=( *.tf */*.tf */*/*.tf ); HAS_TF=$(( ${#_tf[@]} > 0 ))
  _docker=( Dockerfile Dockerfile.* Containerfile Containerfile.* \
            */Dockerfile */Dockerfile.* */Containerfile */Containerfile.* \
            */*/Dockerfile */*/Dockerfile.* )
  HAS_DOCKER=0
  for _f in "${_docker[@]}"; do [[ -f "$_f" ]] && { HAS_DOCKER=1; break; }; done
  # `${arr[@]+"${arr[@]}"}` keeps an empty glob result legal under set -u on
  # bash 3.2, e.g. a workflows dir holding only a README.
  HAS_GHA=0
  if [[ -d .github/workflows ]]; then
    _gha=( .github/workflows/*.yml .github/workflows/*.yaml )
    for _f in ${_gha[@]+"${_gha[@]}"}; do [[ -f "$_f" ]] && { HAS_GHA=1; break; }; done
  fi
  shopt -u nullglob
  (( HAS_POM || HAS_PY || HAS_TF || HAS_DOCKER || HAS_GHA )) || { trace "L1: no markers"; return 0; }

  WANT_SPRING=0; WANT_PY=0; WANT_TF=0; WANT_DOCKER=0; WANT_GHA=0
  IFS=',' read -ra _LANGS <<< "$LANGS_CSV"
  for _l in ${_LANGS[@]+"${_LANGS[@]}"}; do
    case "${_l// /}" in
      spring_maven)   WANT_SPRING=$HAS_POM ;;
      python_uv)      WANT_PY=$HAS_PY ;;
      terraform)      WANT_TF=$HAS_TF ;;
      dockerfile)     WANT_DOCKER=$HAS_DOCKER ;;
      github_actions) WANT_GHA=$HAS_GHA ;;
    esac
  done
  POM=""
  if (( WANT_SPRING )); then
    IFS= read -r -d '' POM < pom.xml || true
    [[ $POM == *spring-javaformat* || $POM == *spotless-maven-plugin* ]] \
      || { trace "L1: pom.xml has no supported formatter plugin; skip Spring"; WANT_SPRING=0; }
  fi
  (( WANT_SPRING || WANT_PY || WANT_TF || WANT_DOCKER || WANT_GHA )) \
    || { trace "L1: nothing enabled matches present markers"; return 0; }

  state_key "$HOOK_CWD"
  STATE_FILE="$STATE_DIR/$KEY.state"
  FINDINGS_FILE="$STATE_DIR/$KEY.findings"
  PREV_VERDICT=""; PREV_PORC=""
  if [[ -f "$STATE_FILE" ]]; then
    local state=""
    IFS= read -r -d '' state < "$STATE_FILE" || true
    PREV_VERDICT="${state%%$'\n'*}"
    [[ "$state" == *$'\n'* ]] && PREV_PORC="${state#*$'\n'}"
  fi

  # -------------------------------------------------------------------------
  # L2 + L4: one NUL-delimited `git status --porcelain -z -uall -- .` feeds
  # both the clean-tree check and per-toolchain changed-file lists. When $PWD
  # is a repo root (.git/HEAD present) no extra git fork is needed; for a
  # monorepo sub-directory `git rev-parse` gives the prefix to strip.
  # -------------------------------------------------------------------------
  JAVA_FILES=(); PY_FILES=(); TF_FILES=(); DOCKER_FILES=(); GHA_FILES=()
  RELEVANT=()
  HAS_GIT=0; GIT_PREFIX=""; PORC=""
  if command -v git &>/dev/null; then
    if [[ -z "${GIT_DIR:-}" && -d .git && -e .git/HEAD ]]; then
      HAS_GIT=1
    else
      local _git_info
      if _git_info=$(git rev-parse --is-inside-work-tree --show-prefix 2>/dev/null) \
         && [[ "${_git_info%%$'\n'*}" == "true" ]]; then
        HAS_GIT=1
        [[ "$_git_info" == *$'\n'* ]] && GIT_PREFIX="${_git_info#*$'\n'}"
      fi
    fi
  fi

  if (( HAS_GIT )); then
    collect_git_status 1
    if [[ -z "$PORC" ]]; then
      [[ -f "$FINDINGS_FILE" ]] && rm -f "$FINDINGS_FILE"
      trace "L2: working tree clean"
      return 0
    fi
    if (( ${#RELEVANT[@]} == 0 )); then
      [[ -f "$FINDINGS_FILE" ]] && rm -f "$FINDINGS_FILE"
      trace "L4: no relevant files changed"
      return 0
    fi
    # -----------------------------------------------------------------------
    # L3: same status as the last run and none of the relevant files modified
    # since. Skip only if the last verdict allows it (see idle_skip). The
    # state file is written AFTER the linters ran, so formatter rewrites never
    # trigger a redundant pass.
    # -----------------------------------------------------------------------
    if [[ -n "$PREV_VERDICT" && "$PREV_PORC" == "$PORC" ]] \
       && [[ -z "$(find "${RELEVANT[@]}" -newer "$STATE_FILE" -print -quit 2>/dev/null)" ]]; then
      idle_skip && { trace "L3: unchanged since last run (verdict: $PREV_VERDICT)"; return 0; }
      trace "L3: unchanged but last verdict failed; re-enforcing"
    fi
  elif [[ -n "$PREV_VERDICT" ]]; then
    # No git, with prior state: collect files newer than the state file.
    collect_nogit_files -newer "$STATE_FILE"
    if (( ${#RELEVANT[@]} == 0 )); then
      idle_skip && { trace "L4: nothing newer than last run (verdict: $PREV_VERDICT)"; return 0; }
      trace "L4: nothing newer but last verdict failed; re-enforcing"
      if [[ -n "$PREV_PORC" ]]; then
        local _prev_p
        while IFS= read -r _prev_p; do
          [[ -n "$_prev_p" ]] && add_path "$_prev_p"
        done <<< "$PREV_PORC"
      fi
      (( ${#RELEVANT[@]} == 0 )) && collect_nogit_files
    elif [[ "$PREV_VERDICT" == failed* && -n "$PREV_PORC" ]]; then
      local _prev_p
      while IFS= read -r _prev_p; do
        [[ -n "$_prev_p" ]] && add_path "$_prev_p"
      done <<< "$PREV_PORC"
    fi
    (( ${#RELEVANT[@]} == 0 )) && { trace "L4: no relevant files changed"; return 0; }
  else
    # No git and no prior state — first run on a fresh project: every matching file.
    collect_nogit_files
    (( ${#RELEVANT[@]} == 0 )) && { trace "L4: no relevant files changed"; return 0; }
  fi

  RUN_SPRING=$(( ${#JAVA_FILES[@]} > 0 ))
  RUN_PY=$(( ${#PY_FILES[@]} > 0 ))
  RUN_TF=$(( ${#TF_FILES[@]} > 0 ))
  RUN_DOCKER=$(( ${#DOCKER_FILES[@]} > 0 ))
  RUN_GHA=$(( ${#GHA_FILES[@]} > 0 ))

  # -------------------------------------------------------------------------
  # L5
  # -------------------------------------------------------------------------
  WS_FAILURES=(); WS_DETAILS=""; WS_SIG=""; CUR_TC=""
  FAIL_SPRING=0; TO_SPRING=0; OUT_SPRING=""
  FAIL_PY=0;     TO_PY=0;     OUT_PY=""
  FAIL_TF=0;     TO_TF=0;     OUT_TF=""
  FAIL_DOCKER=0; TO_DOCKER=0; OUT_DOCKER=""
  FAIL_GHA=0;    TO_GHA=0;    OUT_GHA=""
  (( RUN_SPRING )) && { CUR_TC=spring; run_spring; }
  (( RUN_PY ))     && { CUR_TC=py;     run_python; }
  (( RUN_TF ))     && { CUR_TC=tf;     run_terraform; }
  (( RUN_DOCKER )) && { CUR_TC=docker; run_docker; }
  (( RUN_GHA ))    && { CUR_TC=gha;    run_actions; }
  CUR_TC=""

  [[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR" 2>/dev/null || true
  local n=${#WS_FAILURES[@]} i section verdict=clean deduped=0 sig_hash=""
  (( n > 0 )) && verdict=failed
  if (( n == 0 )); then
    [[ -f "$FINDINGS_FILE" ]] && rm -f "$FINDINGS_FILE"
  elif (( ENFORCING )); then
    sig_hash=$(printf '%s' "$WS_SIG" | hash_str)
    if [[ -f "$FINDINGS_FILE" && "$sig_hash" == "$(cat "$FINDINGS_FILE" 2>/dev/null)" ]]; then
      deduped=1
      verdict=failed_sent
      trace "L5: findings unchanged since last continue; reporting to stderr only"
    else
      printf '%s' "$sig_hash" > "$FINDINGS_FILE" 2>/dev/null || true
    fi
  fi

  # Remember the verdict with the status as it is now (formatter rewrites and
  # any state/findings files inside a repo-local STATE_DIR included). Without
  # git, keep only files implicated by failing toolchains so one bad file never
  # forces later incremental runs to re-lint clean files.
  : > "$STATE_FILE" 2>/dev/null || true
  if (( HAS_GIT )); then
    collect_git_status 0
  elif (( n > 0 )); then
    IMPLICATED=()
    (( FAIL_SPRING )) && collect_implicated "$TO_SPRING" "$OUT_SPRING" "${JAVA_FILES[@]}"
    (( FAIL_PY ))     && collect_implicated "$TO_PY"     "$OUT_PY"     "${PY_FILES[@]}"
    (( FAIL_TF ))     && collect_implicated "$TO_TF"     "$OUT_TF"     "${TF_FILES[@]}"
    (( FAIL_DOCKER )) && collect_implicated "$TO_DOCKER" "$OUT_DOCKER" "${DOCKER_FILES[@]}"
    (( FAIL_GHA ))    && collect_implicated "$TO_GHA"    "$OUT_GHA"    "${GHA_FILES[@]}"
    PORC=""
    for i in ${IMPLICATED[@]+"${IMPLICATED[@]}"}; do PORC+="${PORC:+$NL}$i"; done
  else
    PORC=""
  fi
  save_state "$verdict"
  trace "L5: $verdict ($n failure category/ies)"

  (( n == 0 )) && return 0
  if (( !ENFORCING || deduped )); then
    [[ -n "$WS_DETAILS" ]] && printf '%s\n' "$WS_DETAILS" >&2
    return 0
  fi
  for (( i = 0; i < n; i++ )); do
    FAILURES+=("${WS_FAILURES[$i]}")
  done
  DETAILS+="${DETAILS:+$NL}$WS_DETAILS"
  section="Workspace $HOOK_CWD — $n failure category/ies:"
  for (( i = 0; i < n; i++ )); do
    section+="$NL • ${WS_FAILURES[$i]}"
  done
  REASON+="${REASON:+$NL$NL}$section"
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch over every workspace, then answer the host
# ---------------------------------------------------------------------------
NL=$'\n'
FAILURES=(); REASON=""; DETAILS=""; OUT=""; LAST_RC=0; KEY=""
WS_FAILURES=(); WS_DETAILS=""; WS_SIG=""
PREV_VERDICT=""; PREV_PORC=""; PORC=""; STATE_FILE=""; FINDINGS_FILE=""

for _ws in "${WORKSPACES[@]}"; do
  lint_workspace "$_ws"
done

(( ${#FAILURES[@]} )) || exit 0
if (( ENFORCING == 0 )); then
  trace "${#FAILURES[@]} failure(s) but not enforcing (mode=$MODE termination=$TERM_REASON execution=$EXEC_NUM)"
  exit 0
fi

# Reason = machine tag + one-line headline, then the details. Kept bounded:
# the headline is short and the quoted tool output is a tail of at most
# LINT_ENFORCER_EXCERPT_CHARS characters.
BODY="lint-enforcer:lint_failed — ${#FAILURES[@]} lint failure category/ies remain on changed files."
BODY+=" Formatters already ran, so re-read a file before editing it."
BODY+=" Fix them and re-run the listed tools to verify, or if one should not be fixed, say why in your reply."
BODY+=" (forced continue $EXEC_NUM of $MAX_CONTINUES)$NL$NL$REASON"
if (( EXCERPT_CHARS > 0 )) && [[ -n "$DETAILS" ]]; then
  if (( ${#DETAILS} > EXCERPT_CHARS )); then
    DETAILS="… (${#DETAILS} chars; showing the last $EXCERPT_CHARS)$NL${DETAILS:${#DETAILS}-EXCERPT_CHARS}"
  fi
  BODY+="$NL${NL}Linter output:$NL$DETAILS"
fi
jq -cn --arg r "$BODY" '{decision:"continue",reason:$r}' >&3 && DECIDED=1
exit 0
