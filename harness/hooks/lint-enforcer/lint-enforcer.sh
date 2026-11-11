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
# (per-tool timeouts plus the hooks.json timeout). The verdict is
# deterministic: it depends only on the working tree and the state file,
# never on wall-clock time.
#
# Fast path, per workspace (each step returns early):
#   L0  SKIP env, payload (one jq), terminationReason gate
#   L1  toolchain marker globs                              no fork
#   L2  `git status --short -uall -- .` empty → clean tree  one fork
#   L4  no dirty path belongs to an enabled toolchain       no fork
#   L3  same status as the last run, no relevant dirty file one find
#       modified since, and the last verdict was clean (or
#       cannot be enforced now) → idle turn
#   L5  linters
#
# Modes:
#   block (default) enforcement: on findings answer decision:continue, but
#                   only for a normal completion (NO_TOOL_CALL) and while
#                   executionNum <= LINT_ENFORCER_MAX_CONTINUES, so a fix
#                   loop that never converges cannot trap the agent. A
#                   failing verdict is remembered and re-enforced on the next
#                   enforceable Stop even if nothing changed in between.
#   warn            evaluate-only: autofix runs, findings go to stderr, the
#                   answer is {} — not enforcement.
#
# Env vars (hooks.json has no env field — prefix the command string):
#   SKIP_LINT_ENFORCER           true to disable entirely
#   LINT_ENFORCER_MODE           block|warn                 (default: block)
#   LINT_ENFORCER_LANGS          comma list                 (default: spring_maven,python_uv,terraform,dockerfile,github_actions)
#   LINT_ENFORCER_SKIP_AUTOFIX   true to skip the formatter step (check only)
#   LINT_ENFORCER_TIMEOUT_SEC    per-tool override          (defaults: mvn 240, ruff 30, tf 60, hadolint 30, actionlint 30)
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

MODE="${LINT_ENFORCER_MODE:-block}"
LANGS_CSV="${LINT_ENFORCER_LANGS:-spring_maven,python_uv,terraform,dockerfile,github_actions}"
MAX_CONTINUES="${LINT_ENFORCER_MAX_CONTINUES:-3}"
EXCERPT_CHARS="${LINT_ENFORCER_EXCERPT_CHARS:-3000}"
STATE_DIR="${LINT_ENFORCER_STATE_DIR:-${TMPDIR:-/tmp}/antigravity-lint-enforcer}"
DEBUG="${LINT_ENFORCER_DEBUG:-}"
SKIP_AUTOFIX="${LINT_ENFORCER_SKIP_AUTOFIX:-}"
TIMEOUT_OVERRIDE="${LINT_ENFORCER_TIMEOUT_SEC:-}"

case "$MODE" in warn|block) ;; *) MODE="block" ;; esac
[[ "$MAX_CONTINUES" =~ ^[0-9]+$ ]] || MAX_CONTINUES=3
[[ "$EXCERPT_CHARS" =~ ^[0-9]+$ ]] || EXCERPT_CHARS=3000

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

# State file = "<clean|failed>\n<status text>". Last writer wins; a torn
# concurrent read can only differ from the live status, which means one
# extra lint pass — never a wrong skip.
save_state() { printf '%s\n%s' "$1" "$PORC" > "$STATE_FILE" 2>/dev/null || true; }

# May an unchanged workspace be skipped, given the previous verdict?
#   clean                                → yes
#   failed, but not enforcing right now  → yes (nothing new to say)
#   failed and enforcing                 → no: lint again to re-enforce
#   no / unknown state                   → no
idle_skip() {
  case "$PREV_VERDICT" in
    clean)  return 0 ;;
    failed) (( ENFORCING == 0 )) ;;
    *)      return 1 ;;
  esac
}

run_with_timeout() {
  local secs="$1"; shift
  if [[ -n "$TIMEOUT_BIN" ]]; then "$TIMEOUT_BIN" "$secs" "$@"; else "$@"; fi
}

# capture <timeout> <cmd...>: run a tool, keep its combined output in $OUT,
# return its exit status.
capture() { OUT=$(run_with_timeout "$@" 2>&1); }

# fail <category>: record a finding together with the tool output in $OUT.
fail() {
  FAILURES+=("$1")
  local hdr="--- $1"
  (( ${#WORKSPACES[@]} > 1 )) && hdr+=" @ ${HOOK_CWD##*/}"
  DETAILS+="${DETAILS:+$NL}$hdr ---$NL$OUT"
  note "$1"
}

# Directory walks (no-git gate, Dockerfile discovery) prune heavy dirs by
# name at any depth and are bounded to 10s so a misfire on a huge tree can't
# block Stop for minutes; on timeout they print nothing, the safe bias.
PRUNE=( \( -name .git -o -name node_modules -o -name vendor
           -o -name .venv -o -name venv -o -name .tox
           -o -name target -o -name build -o -name dist
           -o -name .gradle -o -name .mvn -o -name .terraform
           -o -name .next -o -name .cache
           -o -name Library -o -name .Trash -o -name .npm
           -o -name .nvm -o -name .rustup -o -name .cargo \) -prune -o )

# has_newer <name pattern>...: any file matching one of the patterns newer
# than the state file?
has_newer() {
  local expr=() p
  for p in "$@"; do expr+=( ${expr[@]+-o} -name "$p" ); done
  [[ -n "$(run_with_timeout 10 find . "${PRUNE[@]}" -type f \( "${expr[@]}" \) \
             -newer "$STATE_FILE" -print -quit 2>/dev/null)" ]]
}

# ---------------------------------------------------------------------------
# L5: linters (run from $HOOK_CWD). A missing tool is a skip, never a failure.
# ---------------------------------------------------------------------------
run_spring() {
  command -v mvn &>/dev/null || { note "[spring] mvn not on PATH; skip"; return 0; }
  local t="${TIMEOUT_OVERRIDE:-240}" apply check
  # $POM was read in L1. Spotless (google-java-format) or legacy spring-javaformat.
  if [[ $POM == *spotless-maven-plugin* ]]; then
    apply="spotless:apply"; check="spotless:check"
  else
    apply="spring-javaformat:apply"; check="spring-javaformat:validate"
  fi
  # apply formats everything check would flag, so a successful apply is the
  # verdict; the second JVM is only needed in check-only mode.
  if [[ -z "$SKIP_AUTOFIX" ]]; then
    capture "$t" mvn -q -B "$apply" || fail "mvn $apply failed"
  else
    capture "$t" mvn -q -B "$check" || fail "mvn $check reported violations (fix: mvn $apply)"
  fi
}

run_python() {
  local t="${TIMEOUT_OVERRIDE:-30}" ruff=()
  # ruff from the project environment, else a system ruff; neither → skip
  # (uv alone is not enough: `uv run ruff` fails closed when ruff is absent).
  if command -v uv &>/dev/null && capture 10 uv run --no-sync ruff --version; then
    ruff=(uv run --no-sync ruff)
  elif command -v ruff &>/dev/null; then
    ruff=(ruff)
  else
    note "[python] ruff not available (uv run ruff / ruff); skip"; return 0
  fi
  if [[ -z "$SKIP_AUTOFIX" ]]; then
    capture "$t" "${ruff[@]}" format . || fail "ruff format failed"
    # `check --fix` exits non-zero and prints what it could not fix.
    capture "$t" "${ruff[@]}" check --fix . || fail "ruff check reported issues"
  else
    capture "$t" "${ruff[@]}" check . || fail "ruff check reported issues"
  fi
}

run_terraform() {
  command -v terraform &>/dev/null || { note "[terraform] terraform not on PATH; skip"; return 0; }
  local t="${TIMEOUT_OVERRIDE:-60}"
  if [[ -z "$SKIP_AUTOFIX" ]]; then
    capture "$t" terraform fmt -recursive || true
  fi
  capture "$t" terraform fmt -recursive -check -diff || fail "terraform fmt reported drift"
  if command -v tflint &>/dev/null; then
    capture "$t" tflint --recursive || fail "tflint reported issues"
  fi
}

run_docker() {
  command -v hadolint &>/dev/null || { note "[docker] hadolint not on PATH; skip"; return 0; }
  local t="${TIMEOUT_OVERRIDE:-30}" f files=()
  # Dockerfile* + Containerfile* anywhere in the tree. No mapfile: bash 3.2.
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(run_with_timeout 10 find . "${PRUNE[@]}" -type f \
             \( -name Dockerfile -o -name 'Dockerfile.*' -o -name Containerfile -o -name 'Containerfile.*' \) \
             -print 2>/dev/null)
  (( ${#files[@]} == 0 )) && { note "[docker] no Dockerfile/Containerfile found; skip"; return 0; }
  capture "$t" hadolint "${files[@]}" || fail "hadolint reported issues"
}

run_actions() {
  command -v actionlint &>/dev/null || { note "[github_actions] actionlint not on PATH; skip"; return 0; }
  # actionlint auto-discovers .github/workflows/*.{yml,yaml} from the repo root.
  capture "${TIMEOUT_OVERRIDE:-30}" actionlint || fail "actionlint reported issues"
}

# ---------------------------------------------------------------------------
# One workspace: L1 → L5. Always returns 0; appends to FAILURES/DETAILS/REASON.
# ---------------------------------------------------------------------------
lint_workspace() {
  HOOK_CWD="$1"
  cd -P "$HOOK_CWD" 2>/dev/null || { trace "cd $HOOK_CWD failed; skip"; return 0; }
  # Refuse non-project roots: firing on $HOME or / would glob-trip L1 on
  # unrelated subtrees or walk the whole home tree in the no-git gate.
  if [[ "$PWD" == "/" || "$PWD" -ef "${HOME:-/nonexistent}" ]]; then
    trace "L0: refusing to lint non-project dir $HOOK_CWD"; return 0
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

  [[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR" 2>/dev/null || true
  state_key "$HOOK_CWD"
  STATE_FILE="$STATE_DIR/$KEY.state"
  PREV_VERDICT=""; PREV_PORC=""
  if [[ -f "$STATE_FILE" ]]; then
    local state=""
    IFS= read -r -d '' state < "$STATE_FILE" || true
    PREV_VERDICT="${state%%$'\n'*}"
    [[ "$state" == *$'\n'* ]] && PREV_PORC="${state#*$'\n'}"
  fi

  # -------------------------------------------------------------------------
  # L2: one git status — clean tree? (also tells us whether this is a repo).
  # `--short` with relativePaths forced on and colour forced off is the
  # porcelain format with paths relative to the workspace, so a workspace
  # that is a sub-directory of a repo sees only its own changes; `-- .`
  # scopes the walk; -uall lists files inside new untracked directories.
  # -------------------------------------------------------------------------
  HAS_GIT=0; PORC=""
  if command -v git &>/dev/null \
     && PORC=$(git -c status.relativePaths=true -c color.status=false \
                   status --short -uall -- . 2>/dev/null); then
    HAS_GIT=1
    [[ -z "$PORC" ]] && { trace "L2: working tree clean"; return 0; }
  fi

  RUN_SPRING=0; RUN_PY=0; RUN_TF=0; RUN_DOCKER=0; RUN_GHA=0
  RELEVANT=()
  if (( HAS_GIT )); then
    # -----------------------------------------------------------------------
    # L4: which enabled toolchains have dirty files? New side of renames;
    # surrounding quotes stripped from C-quoted (non-ASCII) paths.
    # -----------------------------------------------------------------------
    local line path hit
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      path="${line:3}"
      [[ "$path" == *' -> '* ]] && path="${path##* -> }"
      [[ "$path" == \"*\" ]] && path="${path:1:${#path}-2}"
      hit=0
      case "$path" in
        *.java)        (( WANT_SPRING )) && { RUN_SPRING=1; hit=1; } ;;
        *.py)          (( WANT_PY ))     && { RUN_PY=1;     hit=1; } ;;
        *.tf|*.tfvars) (( WANT_TF ))     && { RUN_TF=1;     hit=1; } ;;
        .github/workflows/*.yml|.github/workflows/*.yaml)
                       (( WANT_GHA ))    && { RUN_GHA=1;    hit=1; } ;;
      esac
      case "${path##*/}" in
        Dockerfile|Dockerfile.*|Containerfile|Containerfile.*)
                       (( WANT_DOCKER )) && { RUN_DOCKER=1; hit=1; } ;;
      esac
      (( hit )) && RELEVANT+=("$path")
    done <<< "$PORC"
    (( ${#RELEVANT[@]} == 0 )) && { trace "L4: no relevant files changed"; return 0; }
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
    # No git, but a previous run to compare against: per-toolchain mtime gate.
    (( WANT_SPRING )) && has_newer '*.java'           && RUN_SPRING=1
    (( WANT_PY ))     && has_newer '*.py'             && RUN_PY=1
    (( WANT_TF ))     && has_newer '*.tf' '*.tfvars'  && RUN_TF=1
    (( WANT_DOCKER )) && has_newer Dockerfile 'Dockerfile.*' Containerfile 'Containerfile.*' && RUN_DOCKER=1
    if (( WANT_GHA )) && [[ -n "$(find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) \
                                   -newer "$STATE_FILE" -print -quit 2>/dev/null)" ]]; then
      RUN_GHA=1
    fi
    if (( !(RUN_SPRING || RUN_PY || RUN_TF || RUN_DOCKER || RUN_GHA) )); then
      idle_skip && { trace "L4: nothing newer than last run (verdict: $PREV_VERDICT)"; return 0; }
      trace "L4: nothing newer but last verdict failed; re-enforcing"
      RUN_SPRING=$WANT_SPRING; RUN_PY=$WANT_PY; RUN_TF=$WANT_TF
      RUN_DOCKER=$WANT_DOCKER; RUN_GHA=$WANT_GHA
    fi
  else
    # No git and no prior state — first run on a fresh project: run everything.
    RUN_SPRING=$WANT_SPRING; RUN_PY=$WANT_PY; RUN_TF=$WANT_TF
    RUN_DOCKER=$WANT_DOCKER; RUN_GHA=$WANT_GHA
  fi

  # -------------------------------------------------------------------------
  # L5
  # -------------------------------------------------------------------------
  WS_FAIL_START=${#FAILURES[@]}
  (( RUN_SPRING )) && run_spring
  (( RUN_PY ))     && run_python
  (( RUN_TF ))     && run_terraform
  (( RUN_DOCKER )) && run_docker
  (( RUN_GHA ))    && run_actions
  local n=$(( ${#FAILURES[@]} - WS_FAIL_START )) i section verdict=clean
  (( n > 0 )) && verdict=failed
  # Remember the verdict with the status as it is now (formatter rewrites
  # included). The state file is created first so that, should STATE_DIR live
  # inside the repo, it is an untracked entry in this snapshot and every later
  # one.
  : > "$STATE_FILE" 2>/dev/null || true
  if (( HAS_GIT )); then
    PORC=$(git -c status.relativePaths=true -c color.status=false \
               status --short -uall -- . 2>/dev/null) || true
  fi
  save_state "$verdict"
  trace "L5: $verdict ($n failure category/ies)"

  (( n == 0 )) && return 0
  section="Workspace $HOOK_CWD — $n failure category/ies:"
  for (( i = WS_FAIL_START; i < ${#FAILURES[@]}; i++ )); do
    section+="$NL • ${FAILURES[$i]}"
  done
  REASON+="${REASON:+$NL$NL}$section"
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch over every workspace, then answer the host
# ---------------------------------------------------------------------------
NL=$'\n'
FAILURES=(); REASON=""; DETAILS=""; OUT=""; KEY=""; WS_FAIL_START=0
PREV_VERDICT=""; PREV_PORC=""; PORC=""; STATE_FILE=""

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
BODY="lint-enforcer:lint_failed — ${#FAILURES[@]} lint failure category/ies remain;"
BODY+=" fix them, re-run the listed tools to verify, then finish your turn."
BODY+=" (forced continue $EXEC_NUM of $MAX_CONTINUES)$NL$NL$REASON"
if (( EXCERPT_CHARS > 0 )) && [[ -n "$DETAILS" ]]; then
  if (( ${#DETAILS} > EXCERPT_CHARS )); then
    DETAILS="… (${#DETAILS} chars; showing the last $EXCERPT_CHARS)$NL${DETAILS:${#DETAILS}-EXCERPT_CHARS}"
  fi
  BODY+="$NL${NL}Linter output:$NL$DETAILS"
fi
jq -cn --arg r "$BODY" '{decision:"continue",reason:$r}' >&3 && DECIDED=1
exit 0
