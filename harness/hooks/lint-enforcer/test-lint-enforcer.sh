#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2015  # `cond && ok || bad` is the assertion idiom here; ok() never fails
# shellcheck disable=SC2016  # stub bodies are deliberately single-quoted: they expand at stub run time

# Tests for lint-enforcer.sh (Antigravity `Stop` hook).
# Verifies the Antigravity I/O contract (strict JSON on stdout, workspacePaths,
# terminationReason / executionNum gating), the fast-path layers and their
# timing budgets, the no-timer idle detection, mode dispatch, and graceful
# degradation when toolchain binaries are missing.
#
# Needs bash >= 5 for EPOCHREALTIME (sub-ms timing without forking). macOS
# ships 3.2 at /bin/bash, so re-exec under a newer bash when available.

if (( BASH_VERSINFO[0] < 5 )); then
  for _b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$_b" ]] && exec "$_b" "$0" "$@"
  done
  echo "FAIL: this test runner needs bash >= 5 (brew install bash); the hook itself runs on 3.2" >&2
  exit 1
fi

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/lint-enforcer.sh"

[[ -x "$HOOK" ]] || { echo "FAIL: $HOOK not executable"; exit 1; }
command -v jq &>/dev/null || { echo "FAIL: tests need jq"; exit 1; }

# Per-test sandbox: isolated state dir, stub-call dir and a temp cwd. Physical
# path (macOS /var → /private/var) because the hook `cd -P`s into workspaces.
SANDBOX_ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

# Restricted PATH for stub tests: stubs first, then a shim dir holding ONLY jq
# (not its whole bin dir, which on Homebrew would also expose the real
# terraform/tflint/hadolint/uv), then the base system (git, find, mkdir).
# Never contains timeout/gtimeout or real toolchains.
mkdir -p "$SANDBOX_ROOT/jq-shim" && ln -s "$(command -v jq)" "$SANDBOX_ROOT/jq-shim/jq"
BASE_PATH="$SANDBOX_ROOT/jq-shim:/usr/bin:/bin"

PASS=0
FAIL=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n  %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

mk_sandbox() {
  local name="$1"
  local dir="$SANDBOX_ROOT/$name"
  # State/calls live OUTSIDE the cwd so git status of the sandbox stays stable.
  mkdir -p "$dir" "$SANDBOX_ROOT/$name.state" "$SANDBOX_ROOT/$name.calls"
  printf '%s' "$dir"
}

state_dir_of() { printf '%s' "$SANDBOX_ROOT/$(basename "$1").state"; }
calls_of()     { printf '%s' "$SANDBOX_ROOT/$(basename "$1").calls/calls"; }

# Antigravity `Stop` payload. $1 = workspace path(s) separated by ':',
# $2 = terminationReason, $3 = executionNum.
payload() {
  local paths="$1" term="${2:-NO_TOOL_CALL}" execnum="${3:-1}"
  local json_paths="" p
  IFS=':' read -ra _ps <<< "$paths"
  for p in "${_ps[@]}"; do
    [[ -z "$p" ]] && continue
    json_paths+="${json_paths:+,}\"$p\""
  done
  printf '{"conversationId":"test-conv","workspacePaths":[%s],"transcriptPath":"/dev/null","artifactDirectoryPath":"/dev/null","modelName":"test","lastUserInput":"x","isBattleMode":false,"executionNum":%s,"terminationReason":"%s","error":"","fullyIdle":true}' \
    "$json_paths" "$execnum" "$term"
}

# Run the hook with an isolated state dir. Captures stdout+stderr+ms.
# Uses bash 5 EPOCHREALTIME for zero-subprocess timing (~µs precision).
# The hook is launched from an unrelated directory (the sandbox root) — just
# like Antigravity, whose hook cwd is the hooks.json directory, not the
# project — so any accidental reliance on $PWD shows up as a failure.
#   run_hook <workspace[:workspace2]> [env VAR=... ...]
# Optional: RUN_TERM / RUN_EXEC override terminationReason / executionNum.
RUN_TERM=""; RUN_EXEC=""
run_hook() {
  local ws="$1"; shift
  local out_file err_file t0 t1 dt_ms rc first="${ws%%:*}"
  out_file=$(mktemp); err_file=$(mktemp)
  t0="${EPOCHREALTIME/./}"
  ( cd "$SANDBOX_ROOT" && \
    LINT_ENFORCER_STATE_DIR="$(state_dir_of "$first")" \
    LE_TEST_CALLS="$(calls_of "$first")" \
    "$@" \
      "$HOOK" >"$out_file" 2>"$err_file" < <(payload "$ws" "${RUN_TERM:-NO_TOOL_CALL}" "${RUN_EXEC:-1}") )
  rc=$?
  t1="${EPOCHREALTIME/./}"
  dt_ms=$(( (t1 - t0) / 1000 ))
  HOOK_STDOUT=$(cat "$out_file"); rm -f "$out_file"
  HOOK_STDERR=$(cat "$err_file"); rm -f "$err_file"
  HOOK_RC=$rc
  HOOK_MS=$dt_ms
  RUN_TERM=""; RUN_EXEC=""
}

# Antigravity parses stdout as JSON: a no-op answer must be exactly `{}`.
assert_noop() {
  if [[ "$HOOK_STDOUT" == "{}" ]]; then ok "stdout is the {} no-op"
  else bad "stdout must be exactly {}" "stdout='$HOOK_STDOUT'"; fi
}
assert_continue() {
  if printf '%s' "$HOOK_STDOUT" | jq -e '.decision == "continue" and (.reason | length) > 0' >/dev/null 2>&1; then
    ok "stdout is valid decision:continue JSON with a reason"
  else
    bad "decision:continue JSON" "stdout='$HOOK_STDOUT'"
  fi
}

# Stub binary helper: $1 = stub dir, $2 = name, $3.. = script body lines.
# Stubs record their invocations in $LE_TEST_CALLS when asked to.
mk_stub() {
  local dir="$1" name="$2"; shift 2
  { echo '#!/bin/bash'; printf '%s\n' "$@"; } > "$dir/$name"
  chmod +x "$dir/$name"
}
RECORD='echo "ran $(basename "$0") $* in $PWD" >> "$LE_TEST_CALLS"'

# Git sandbox helper: init repo, commit everything, then apply the dirty edit
# given as a shell snippet in $2.
git_sandbox() {
  local cwd="$1" dirty="$2"
  ( cd "$cwd" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -q -m init && eval "$dirty" )
}

# A dirty terraform repo whose stub terraform fails the check pass.
tf_failing_sandbox() {
  local name="$1" cwd
  cwd=$(mk_sandbox "$name")
  echo 'resource "x" "y" {}' > "$cwd/main.tf"
  git_sandbox "$cwd" "echo 'resource \"x\" \"z\" {}' >> main.tf"
  printf '%s' "$cwd"
}

# ---------------------------------------------------------------------------
hdr "Contract: refuses to lint \$HOME as a workspace (non-project parent)"
# ---------------------------------------------------------------------------
# Regression: firing on $HOME (or /) would let the L1 depth-2/3 globs match
# unrelated Dockerfiles in subprojects, then in the no-git L4 branch walk the
# entire home tree. Stop stalled for minutes.
run_hook "$HOME" env LINT_ENFORCER_DEBUG=true
[[ $HOOK_RC -eq 0 ]] && ok "exit 0 from \$HOME" || bad "exit code from \$HOME" "got $HOOK_RC"
assert_noop
printf '%s' "$HOOK_STDERR" | grep -q 'refusing to lint non-project' \
  && ok "logged refusal" || bad "no refusal trace" "stderr='$HOOK_STDERR'"
[[ $HOOK_MS -lt 500 ]] && ok "<500ms (got ${HOOK_MS}ms)" || bad "<500ms" "got ${HOOK_MS}ms"

# ---------------------------------------------------------------------------
hdr "L0: SKIP env short-circuits (<150ms) and still answers {}"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox skip)
touch "$cwd/pom.xml"
run_hook "$cwd" env SKIP_LINT_ENFORCER=true
[[ $HOOK_RC -eq 0 ]] && ok "exit 0" || bad "exit code" "got $HOOK_RC"
assert_noop
[[ -z "$HOOK_STDERR" ]] && ok "stderr silent" || bad "stderr silent" "stderr='$HOOK_STDERR'"
[[ $HOOK_MS -lt 150 ]] && ok "<150ms (got ${HOOK_MS}ms)" || bad "<150ms" "got ${HOOK_MS}ms"

# ---------------------------------------------------------------------------
hdr "L0: without jq the hook is a silent, fail-open no-op"
# ---------------------------------------------------------------------------
if [[ -x /usr/bin/jq || -x /bin/jq ]]; then
  ok "skipped: jq lives in the base PATH on this system"
else
  cwd=$(mk_sandbox no-jq)
  echo 'resource "x" "y" {}' > "$cwd/main.tf"
  run_hook "$cwd" env PATH="/usr/bin:/bin" LINT_ENFORCER_DEBUG=true LINT_ENFORCER_MODE=block
  [[ $HOOK_RC -eq 0 ]] && ok "exit 0" || bad "exit code" "got $HOOK_RC"
  assert_noop
  printf '%s' "$HOOK_STDERR" | grep -q 'jq not on PATH' && ok "trace names the missing dependency" \
    || bad "jq trace" "stderr='$HOOK_STDERR'"
fi

# ---------------------------------------------------------------------------
hdr "L0: USER_CANCELED stops never run the linters"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox canceled)
echo 'resource "x" "y" {}' > "$cwd/main.tf"
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'exit 0'
RUN_TERM=USER_CANCELED run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_DEBUG=true
assert_noop
[[ ! -f "$(calls_of "$cwd")" ]] && ok "linter not invoked on USER_CANCELED" \
  || bad "USER_CANCELED gate" "stub ran: $(cat "$(calls_of "$cwd")")"
printf '%s' "$HOOK_STDERR" | grep -q 'terminationReason=USER_CANCELED; skip' \
  && ok "trace names the gate" || bad "trace" "stderr='$HOOK_STDERR'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "L0: payload without workspacePaths is a fast no-op (never lints \$PWD)"
# ---------------------------------------------------------------------------
# Stage a marker in the directory the hook is launched from; it must be ignored.
touch "$SANDBOX_ROOT/pom.xml"
run_hook "" env LINT_ENFORCER_DEBUG=true
rm -f "$SANDBOX_ROOT/pom.xml"
assert_noop
printf '%s' "$HOOK_STDERR" | grep -q 'no workspacePaths' && ok "trace: no workspacePaths" \
  || bad "no-workspace trace" "stderr='$HOOK_STDERR'"
[[ $HOOK_MS -lt 200 ]] && ok "<200ms (got ${HOOK_MS}ms)" || bad "<200ms" "got ${HOOK_MS}ms"

# ---------------------------------------------------------------------------
hdr "L0: empty non-interactive stdin is a no-op, not a \$PWD lint"
# ---------------------------------------------------------------------------
# Only an interactive shell (tty stdin) gets the manual-run $PWD fallback.
touch "$SANDBOX_ROOT/pom.xml"
out=$( cd "$SANDBOX_ROOT" && LINT_ENFORCER_STATE_DIR="$SANDBOX_ROOT/empty.state" LINT_ENFORCER_DEBUG=true \
       "$HOOK" </dev/null 2>"$SANDBOX_ROOT/empty.err" )
rm -f "$SANDBOX_ROOT/pom.xml"
[[ "$out" == "{}" ]] && ok "answers {}" || bad "empty stdin stdout" "stdout='$out'"
grep -q 'empty payload' "$SANDBOX_ROOT/empty.err" && ok "trace: empty payload" \
  || bad "empty payload trace" "stderr='$(cat "$SANDBOX_ROOT/empty.err")'"

# ---------------------------------------------------------------------------
hdr "L1: no markers → {} and silent (<200ms)"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox no-markers)
run_hook "$cwd" env
[[ $HOOK_RC -eq 0 ]] && ok "exit 0" || bad "exit code" "got $HOOK_RC"
assert_noop
[[ -z "$HOOK_STDERR" ]] && ok "stderr silent" || bad "stderr silent" "stderr='$HOOK_STDERR'"
[[ $HOOK_MS -lt 200 ]] && ok "<200ms (got ${HOOK_MS}ms)" || bad "<200ms" "got ${HOOK_MS}ms"
[[ -z "$(ls -A "$(state_dir_of "$cwd")")" ]] && ok "no state written before L1 passes" \
  || bad "state written too early" "$(ls -A "$(state_dir_of "$cwd")")"

# ---------------------------------------------------------------------------
hdr "L1: pom.xml without a formatter plugin → skip Spring silently"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox plain-maven)
echo '<project></project>' > "$cwd/pom.xml"
run_hook "$cwd" env
[[ $HOOK_RC -eq 0 ]] && ok "exit 0" || bad "exit code" "got $HOOK_RC"
assert_noop
[[ -z "$HOOK_STDERR" ]] && ok "stderr silent" || bad "stderr silent" "stderr='$HOOK_STDERR'"

# ---------------------------------------------------------------------------
hdr "L1: empty .github/workflows dir does not crash bash 3.2 (set -u)"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox empty-gha)
mkdir -p "$cwd/.github/workflows"; echo 'doc' > "$cwd/.github/workflows/README.md"
run_hook "$cwd" env
[[ $HOOK_RC -eq 0 ]] && ok "exit 0" || bad "exit code" "rc=$HOOK_RC stderr='$HOOK_STDERR'"
assert_noop
printf '%s' "$HOOK_STDERR" | grep -q 'unbound variable' \
  && bad "set -u crash" "stderr='$HOOK_STDERR'" || ok "no unbound-variable error"

# ---------------------------------------------------------------------------
hdr "L1: LINT_ENFORCER_LANGS filter narrows toolchains"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox lang-filter)
echo '<project>spring-javaformat</project>' > "$cwd/pom.xml"
run_hook "$cwd" env LINT_ENFORCER_LANGS=python_uv
# pom present, but spring filtered out → no toolchain enabled → silent {}
assert_noop
[[ -z "$HOOK_STDERR" ]] && ok "no output when filter excludes only present toolchain" \
  || bad "lang filter" "stderr='$HOOK_STDERR'"

# ---------------------------------------------------------------------------
hdr "L4: the common idle turn — dirty repo, no relevant change → silent {} fast"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox no-changes)
echo '<project>spring-javaformat</project>' > "$cwd/pom.xml"; echo 'doc' > "$cwd/README.md"
git_sandbox "$cwd" "echo 'doc2' > README.md"   # change a non-java file
run_hook "$cwd" env
[[ $HOOK_RC -eq 0 ]] && ok "exit 0" || bad "exit code" "got $HOOK_RC"
assert_noop
[[ -z "$HOOK_STDERR" ]] && ok "no linter invoked" || bad "no linter invoked" "stderr='$HOOK_STDERR'"
[[ $HOOK_MS -lt 150 ]] && ok "<150ms (got ${HOOK_MS}ms): bash + jq + one git status" \
  || bad "<150ms" "got ${HOOK_MS}ms"
n_state=$(find "$(state_dir_of "$cwd")" -type f | wc -l | tr -d ' ')
[[ "$n_state" == "0" ]] && ok "nothing written: no verdict was produced" || bad "state files" "$(ls -A "$(state_dir_of "$cwd")")"

# ---------------------------------------------------------------------------
hdr "L3: identical dirty set and no edits → second run skips (no timer involved)"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox idle-skip)
echo 'resource "x" "y" {}' > "$cwd/main.tf"
git_sandbox "$cwd" "echo 'resource \"x\" \"z\" {}' >> main.tf"
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform
[[ -f "$(calls_of "$cwd")" ]] && ok "first run invoked the linter" || bad "first run" "stderr='$HOOK_STDERR'"
rm -f "$(calls_of "$cwd")"
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_DEBUG=true
printf '%s' "$HOOK_STDERR" | grep -q 'L3: unchanged since last run' \
  && ok "second run hit L3" || bad "L3" "second-run stderr: '$HOOK_STDERR'"
[[ ! -f "$(calls_of "$cwd")" ]] && ok "linter not invoked again" || bad "redundant run" "$(cat "$(calls_of "$cwd")")"
assert_noop

# ---------------------------------------------------------------------------
hdr "L3: editing an already-dirty file re-triggers (the old 60s blind spot)"
# ---------------------------------------------------------------------------
sleep 1   # mtime resolution safety margin
echo '# touched' >> "$cwd/main.tf"   # still " M main.tf" — status text unchanged
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_DEBUG=true
[[ -f "$(calls_of "$cwd")" ]] && ok "linter ran after a content-only edit" \
  || bad "content edit missed" "stderr='$HOOK_STDERR'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "L3: a formatter that rewrites files does not cause a redundant pass"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox autofix-rewrite)
echo 'resource "x" "y" {}' > "$cwd/main.tf"
git_sandbox "$cwd" "echo 'resource \"x\" \"z\" {}' >> main.tf"
stub_dir=$(mktemp -d)
# The "fmt" pass rewrites main.tf (new mtime, still dirty); the check passes.
mk_stub "$stub_dir" terraform "$RECORD" 'if [[ "$*" != *"-check"* ]]; then echo "# formatted" >> main.tf; fi' 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform
rm -f "$(calls_of "$cwd")"
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_DEBUG=true
[[ ! -f "$(calls_of "$cwd")" ]] && ok "no second pass after the formatter's own rewrite" \
  || bad "redundant pass" "$(cat "$(calls_of "$cwd")"); stderr='$HOOK_STDERR'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "L3: a STATE_DIR inside the repo does not defeat the idle check"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox state-in-repo)
echo 'resource "x" "y" {}' > "$cwd/main.tf"
git_sandbox "$cwd" "echo 'resource \"x\" \"z\" {}' >> main.tf"
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_STATE_DIR="$cwd/.lint-state"
rm -f "$(calls_of "$cwd")"
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_STATE_DIR="$cwd/.lint-state" LINT_ENFORCER_DEBUG=true
[[ ! -f "$(calls_of "$cwd")" ]] && ok "second run idle even though the state file is an untracked entry" \
  || bad "state file defeated L3" "stderr='$HOOK_STDERR'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "L4: a brand-new untracked package is detected (git status -uall)"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox new-pkg)
printf '[project]\nname="x"\nversion="0"\n' > "$cwd/pyproject.toml"
git_sandbox "$cwd" "mkdir newpkg && echo 'x=1' > newpkg/mod.py"   # shows as '?? newpkg/' without -uall
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" uv "$RECORD" 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=python_uv LINT_ENFORCER_DEBUG=true
[[ -f "$(calls_of "$cwd")" ]] && ok "ruff invoked for a .py inside a new untracked directory" \
  || bad "untracked dir missed" "stderr='$HOOK_STDERR'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "Missing binary handling: terraform-only project without terraform CLI"
# ---------------------------------------------------------------------------
cwd=$(tf_failing_sandbox no-tf-binary)
run_hook "$cwd" env PATH="$BASE_PATH" LINT_ENFORCER_LANGS=terraform
[[ $HOOK_RC -eq 0 ]] && ok "exits 0 when terraform binary missing" \
  || bad "missing binary" "rc=$HOOK_RC stderr='$HOOK_STDERR'"
assert_noop
printf '%s' "$HOOK_STDERR" | grep -q 'terraform not on PATH' \
  && ok "logged missing-binary message" || bad "missing binary message" "stderr='$HOOK_STDERR'"

# ---------------------------------------------------------------------------
hdr "Warn mode (evaluate-only): findings never block — stdout stays {}"
# ---------------------------------------------------------------------------
cwd=$(tf_failing_sandbox warn-mode)
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'if [[ "$*" == *"-check"* ]]; then echo "main.tf drift"; exit 3; fi' 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_MODE=warn
assert_noop
printf '%s' "$HOOK_STDERR" | grep -q 'terraform fmt reported drift' \
  && ok "stderr carries the finding" || bad "warn stderr" "stderr='$HOOK_STDERR'"
[[ -z "$(find "$SANDBOX_ROOT" -name '*.log' -type f)" ]] && ok "no log file written anywhere" \
  || bad "log files" "$(find "$SANDBOX_ROOT" -name '*.log' -type f)"
# Failing and unchanged: warn has nothing new to say, so the next stop is idle.
rm -f "$(calls_of "$cwd")"
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_MODE=warn LINT_ENFORCER_DEBUG=true
[[ ! -f "$(calls_of "$cwd")" ]] && ok "unchanged failing workspace is idle in warn mode" \
  || bad "warn re-ran" "stderr='$HOOK_STDERR'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "Block mode: decision:continue with a machine tag and an actionable reason"
# ---------------------------------------------------------------------------
cwd=$(tf_failing_sandbox block-mode)
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform 'if [[ "$*" == *"-check"* ]]; then echo "--- main.tf: missing newline after brace"; exit 3; fi' 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_MODE=block
rm -rf "$stub_dir"
assert_continue
reason=$(printf '%s' "$HOOK_STDOUT" | jq -r '.reason')
[[ "$reason" == lint-enforcer:lint_failed* ]] && ok "reason starts with the machine tag" \
  || bad "machine tag" "reason='$reason'"
printf '%s' "$reason" | grep -q 'terraform fmt reported drift' \
  && ok "reason lists the failing tool" || bad "reason categories" "reason='$reason'"
printf '%s' "$reason" | grep -q 'missing newline after brace' \
  && ok "reason quotes the linter output" || bad "reason excerpt" "reason='$reason'"
printf '%s' "$reason" | grep -q "Workspace $cwd" \
  && ok "reason names the workspace" || bad "reason workspace" "reason='$reason'"
[[ $(printf '%s\n' "$HOOK_STDOUT" | wc -l | tr -d ' ') -eq 1 ]] \
  && ok "stdout is a single JSON line" || bad "single line" "stdout='$HOOK_STDOUT'"
printf '%s' "$HOOK_STDERR" | grep -q 'No such file' \
  && bad "first-run stderr noise" "stderr='$HOOK_STDERR'" || ok "no shell errors on first run"

# ---------------------------------------------------------------------------
hdr "Block mode: LINT_ENFORCER_EXCERPT_CHARS bounds / drops the quoted output"
# ---------------------------------------------------------------------------
cwd=$(tf_failing_sandbox block-excerpt)
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform 'if [[ "$*" == *"-check"* ]]; then for i in $(seq 1 200); do echo "DIFF-LINE-$i"; done; exit 3; fi' 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform \
  LINT_ENFORCER_MODE=block LINT_ENFORCER_EXCERPT_CHARS=200
assert_continue
reason=$(printf '%s' "$HOOK_STDOUT" | jq -r '.reason')
printf '%s' "$reason" | grep -q 'showing the last 200' && ok "truncation is announced" \
  || bad "truncation notice" "reason='$reason'"
printf '%s' "$reason" | grep -q 'DIFF-LINE-200' && ok "the tail of the output is kept" \
  || bad "tail kept" "reason='$reason'"
printf '%s' "$reason" | grep -q 'DIFF-LINE-1$' && bad "head should be cut" "reason='$reason'" \
  || ok "the head of the output is cut"
rm -f "$(state_dir_of "$cwd")"/*   # force a fresh pass
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform \
  LINT_ENFORCER_MODE=block LINT_ENFORCER_EXCERPT_CHARS=0
assert_continue
printf '%s' "$HOOK_STDOUT" | grep -q 'DIFF-LINE' \
  && bad "excerpt suppressed" "stdout='$HOOK_STDOUT'" || ok "EXCERPT_CHARS=0 quotes no tool output"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "Block mode: non-normal terminationReason degrades to warn (lints, no continue)"
# ---------------------------------------------------------------------------
for term in MAX_INVOCATIONS ERROR TERMINAL_STEP_TYPE; do
  cwd=$(tf_failing_sandbox "block-term-$term")
  stub_dir=$(mktemp -d)
  mk_stub "$stub_dir" terraform "$RECORD" 'if [[ "$*" == *"-check"* ]]; then exit 3; fi' 'exit 0'
  RUN_TERM="$term" run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform \
    LINT_ENFORCER_MODE=block LINT_ENFORCER_DEBUG=true
  rm -rf "$stub_dir"
  [[ "$HOOK_STDOUT" == "{}" ]] && ok "$term: answers {} despite failures" \
    || bad "$term: must not continue" "stdout='$HOOK_STDOUT'"
  [[ -f "$(calls_of "$cwd")" ]] && ok "$term: linters still ran (autofix)" \
    || bad "$term: linters skipped" "stderr='$HOOK_STDERR'"
done

# ---------------------------------------------------------------------------
hdr "Block mode: terminationReason matching is case-insensitive (MODEL_STOP alias)"
# ---------------------------------------------------------------------------
cwd=$(tf_failing_sandbox block-alias)
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform 'if [[ "$*" == *"-check"* ]]; then exit 3; fi' 'exit 0'
RUN_TERM="model_stop" run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_MODE=block
rm -rf "$stub_dir"
assert_continue

# ---------------------------------------------------------------------------
hdr "Block mode: executionNum loop guard (LINT_ENFORCER_MAX_CONTINUES)"
# ---------------------------------------------------------------------------
cwd=$(tf_failing_sandbox block-loop)
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'if [[ "$*" == *"-check"* ]]; then exit 3; fi' 'exit 0'
# The agent is sent back without editing anything in between: a failing
# verdict must be re-enforced, not forgotten after the first continue.
RUN_EXEC=1 run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_MAX_CONTINUES=2
assert_continue
rm -f "$(calls_of "$cwd")"
RUN_EXEC=2 run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_MAX_CONTINUES=2 LINT_ENFORCER_DEBUG=true
assert_continue
[[ -f "$(calls_of "$cwd")" ]] && ok "unchanged failing workspace is re-linted while enforcing" \
  || bad "re-enforce" "stderr='$HOOK_STDERR'"
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -q 'forced continue 2 of 2' \
  && ok "reason reports the continue budget" || bad "budget text" "stdout='$HOOK_STDOUT'"
# executionNum 3 of max 2 → budget exhausted → let the agent stop, and do not
# even spend a linter run on it: nothing changed and nothing can be enforced.
rm -f "$(calls_of "$cwd")"
RUN_EXEC=3 run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_MAX_CONTINUES=2 LINT_ENFORCER_DEBUG=true
[[ "$HOOK_STDOUT" == "{}" ]] && ok "executionNum beyond budget → {}" \
  || bad "loop guard" "stdout='$HOOK_STDOUT'"
printf '%s' "$HOOK_STDERR" | grep -q 'max continues' && ok "trace explains the guard" \
  || bad "loop guard trace" "stderr='$HOOK_STDERR'"
[[ ! -f "$(calls_of "$cwd")" ]] && ok "no linter run spent on an unenforceable, unchanged stop" \
  || bad "wasted run" "$(cat "$(calls_of "$cwd")")"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "Block mode: a failure found on an unenforceable stop is enforced on the next normal one"
# ---------------------------------------------------------------------------
# e.g. the agent asked the user a question (TERMINAL_STEP_TYPE) with lint
# errors outstanding, then finished the next turn without touching the file.
cwd=$(tf_failing_sandbox block-deferred)
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'if [[ "$*" == *"-check"* ]]; then exit 3; fi' 'exit 0'
RUN_TERM=TERMINAL_STEP_TYPE run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform
assert_noop
rm -f "$(calls_of "$cwd")"
RUN_TERM=NO_TOOL_CALL run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_DEBUG=true
assert_continue
[[ -f "$(calls_of "$cwd")" ]] && ok "linters re-ran on the first enforceable stop" \
  || bad "deferred enforcement" "stderr='$HOOK_STDERR'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "No-git: a failing verdict is re-enforced without edits, a clean one is idle"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox nogit-failing)
echo 'resource "x" "y" {}' > "$cwd/main.tf"
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'if [[ "$*" == *"-check"* ]]; then exit 3; fi' 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform
assert_continue
rm -f "$(calls_of "$cwd")"
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform
assert_continue
[[ -f "$(calls_of "$cwd")" ]] && ok "no-git failing workspace re-linted while enforcing" \
  || bad "no-git re-enforce" "stderr='$HOOK_STDERR'"
mk_stub "$stub_dir" terraform "$RECORD" 'exit 0'     # now passes
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform
assert_noop
rm -f "$(calls_of "$cwd")"
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_DEBUG=true
[[ ! -f "$(calls_of "$cwd")" ]] && ok "no-git clean workspace is idle on the next stop" \
  || bad "no-git idle" "stderr='$HOOK_STDERR'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "Python: uv present but ruff unavailable → skip, never a failure"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox no-ruff)
printf '[project]\nname="x"\nversion="0"\n' > "$cwd/pyproject.toml"
git_sandbox "$cwd" "echo 'x=1' > mod.py"
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" uv "$RECORD" 'echo "error: Failed to spawn: \`ruff\`" >&2' 'exit 2'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=python_uv
assert_noop
printf '%s' "$HOOK_STDERR" | grep -q 'ruff not available' && ok "skip is explained on stderr" \
  || bad "ruff skip note" "stderr='$HOOK_STDERR'"
grep -q -- '--version' "$(calls_of "$cwd")" && ok "ruff was probed once" || bad "probe" "$(cat "$(calls_of "$cwd")")"
grep -q -- 'format' "$(calls_of "$cwd")" && bad "format ran without ruff" "$(cat "$(calls_of "$cwd")")" \
  || ok "no format/check attempted without ruff"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "Monorepo: a workspace that is a sub-directory of the repo sees only its own changes"
# ---------------------------------------------------------------------------
repo=$(mk_sandbox monorepo)
mkdir -p "$repo/svc-a" "$repo/svc-b"
# Each sub-directory workspace gets its own state/calls dirs (keyed by basename).
mkdir -p "$SANDBOX_ROOT/svc-a.state" "$SANDBOX_ROOT/svc-a.calls" "$SANDBOX_ROOT/svc-b.state" "$SANDBOX_ROOT/svc-b.calls"
echo 'resource "a" "a" {}' > "$repo/svc-a/main.tf"
echo 'resource "b" "b" {}' > "$repo/svc-b/main.tf"
git_sandbox "$repo" "echo 'resource \"b\" \"c\" {}' >> svc-b/main.tf"   # only B is dirty
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'exit 0'
# Workspace A: nothing of its own changed → nothing runs.
run_hook "$repo/svc-a" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_DEBUG=true
assert_noop
[[ ! -f "$(calls_of "$repo/svc-a")" ]] && ok "sibling's dirty file does not trigger workspace A" \
  || bad "monorepo leak" "$(cat "$(calls_of "$repo/svc-a")")"
# Workspace B: runs, then a content-only edit is detected via the relative path.
run_hook "$repo/svc-b" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform
[[ -f "$(calls_of "$repo/svc-b")" ]] && ok "workspace B linted its own change" || bad "workspace B" "stderr='$HOOK_STDERR'"
rm -f "$(calls_of "$repo/svc-b")"
sleep 1; echo '# edit' >> "$repo/svc-b/main.tf"
run_hook "$repo/svc-b" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_DEBUG=true
[[ -f "$(calls_of "$repo/svc-b")" ]] && ok "content edit in a sub-directory workspace is detected" \
  || bad "subdir mtime check" "stderr='$HOOK_STDERR'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "L1: terraform kept in a sub-directory is detected"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox tf-subdir)
mkdir -p "$cwd/infra/prod"
echo 'resource "x" "y" {}' > "$cwd/infra/prod/main.tf"
git_sandbox "$cwd" "echo 'resource \"x\" \"z\" {}' >> infra/prod/main.tf"
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_DEBUG=true
[[ -f "$(calls_of "$cwd")" ]] && ok "terraform invoked for infra/prod/*.tf" || bad "tf subdir" "stderr='$HOOK_STDERR'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "Paths with spaces in STATE_DIR survive the no-git find gate (no eval)"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox "spaced")
echo 'resource "x" "y" {}' > "$cwd/main.tf"
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'exit 0'
spaced_state="$SANDBOX_ROOT/state dir with spaces/and (parens)"
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_STATE_DIR="$spaced_state"
[[ -f "$(calls_of "$cwd")" ]] && ok "first run linted" || bad "first run" "stderr='$HOOK_STDERR'"
rm -f "$(calls_of "$cwd")"
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform LINT_ENFORCER_STATE_DIR="$spaced_state" LINT_ENFORCER_DEBUG=true
[[ ! -f "$(calls_of "$cwd")" ]] && ok "idle skip works with a spaced state path" \
  || bad "spaced state" "stderr='$HOOK_STDERR'"
printf '%s' "$HOOK_STDERR" | grep -qi 'syntax error\|No such file' && bad "shell error" "stderr='$HOOK_STDERR'" \
  || ok "no shell errors"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "Multi-root: every workspacePaths entry is linted independently"
# ---------------------------------------------------------------------------
ws_a=$(mk_sandbox multi-a)   # terraform project with a dirty .tf
ws_b=$(mk_sandbox multi-b)   # no markers at all
ws_c=$(mk_sandbox multi-c)   # second terraform project, clean tree → L2 skip
echo 'resource "a" "a" {}' > "$ws_a/main.tf"
git_sandbox "$ws_a" "echo 'resource \"a\" \"b\" {}' >> main.tf"
echo 'resource "c" "c" {}' > "$ws_c/main.tf"
git_sandbox "$ws_c" "true"
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'if [[ "$*" == *"-check"* ]]; then exit 3; fi' 'exit 0'
run_hook "$ws_a:$ws_b:$ws_c" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform \
  LINT_ENFORCER_MODE=block LINT_ENFORCER_DEBUG=true
rm -rf "$stub_dir"
calls="$(calls_of "$ws_a")"
grep -q "in $ws_a" "$calls" 2>/dev/null && ok "linted workspace A" || bad "workspace A" "$(cat "$calls" 2>/dev/null)"
grep -q "in $ws_c" "$calls" 2>/dev/null && bad "workspace C (clean) must be skipped" "$(cat "$calls")" \
  || ok "workspace C skipped by L2 (clean tree)"
printf '%s' "$HOOK_STDERR" | grep -q "cwd=$ws_b" && ok "workspace B visited" || bad "workspace B" "stderr='$HOOK_STDERR'"
assert_continue
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -q "Workspace $ws_a" \
  && ok "reason attributes findings to workspace A" || bad "reason attribution" "stdout='$HOOK_STDOUT'"
printf '%s' "$HOOK_STDOUT" | jq -r '.reason' | grep -q "@ multi-a" \
  && ok "quoted output is labelled with the workspace" || bad "output label" "stdout='$HOOK_STDOUT'"

# ---------------------------------------------------------------------------
hdr "No-git: first run on a fresh project runs the linters"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox nogit-first)
echo 'resource "x" "y" {}' > "$cwd/main.tf"
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" terraform "$RECORD" 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform
[[ -f "$(calls_of "$cwd")" ]] && ok "linter ran on fresh no-git project" \
  || bad "no-git first run" "stub not called; stderr='$HOOK_STDERR'"

# ---------------------------------------------------------------------------
hdr "No-git: idle second turn skips the linter via mtime gate"
# ---------------------------------------------------------------------------
# Same sandbox — the state file now exists and is newer than every .tf file.
rm -f "$(calls_of "$cwd")"
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform
[[ ! -f "$(calls_of "$cwd")" ]] && ok "linter skipped when no .tf files newer than state" \
  || bad "no-git mtime gate" "linter ran unexpectedly: $(cat "$(calls_of "$cwd")")"

# ---------------------------------------------------------------------------
hdr "No-git: editing a file re-triggers the linter via mtime gate"
# ---------------------------------------------------------------------------
sleep 1
echo 'resource "x" "z" {}' >> "$cwd/main.tf"  # now newer than state file
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform
[[ -f "$(calls_of "$cwd")" ]] && ok "linter ran after .tf file was modified" \
  || bad "no-git mtime re-trigger" "stub not called after edit; stderr='$HOOK_STDERR'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "Dockerfile: hadolint invoked on Dockerfile change"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox docker-basic)
printf 'FROM alpine:3.20\nRUN echo hi\n' > "$cwd/Dockerfile"
git_sandbox "$cwd" "printf 'FROM alpine:3.20\nRUN echo hi\nRUN echo bye\n' > Dockerfile"
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" hadolint "$RECORD" 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=dockerfile
[[ -f "$(calls_of "$cwd")" ]] && ok "hadolint invoked on Dockerfile change" \
  || bad "docker invoke" "hadolint not called; stderr='$HOOK_STDERR'"
grep -q 'Dockerfile' "$(calls_of "$cwd")" 2>/dev/null \
  && ok "hadolint received Dockerfile path as argument" \
  || bad "docker arg" "hadolint args: $(cat "$(calls_of "$cwd")" 2>/dev/null)"

# ---------------------------------------------------------------------------
hdr "Dockerfile: idle turn skips hadolint (no Dockerfile changes)"
# ---------------------------------------------------------------------------
rm -f "$(calls_of "$cwd")"
( cd "$cwd" && git add -A && git commit -q -m update )  # commit so tree clean
( cd "$cwd" && echo 'noise' > README.md )               # L2 passes, L4 must gate
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=dockerfile
[[ ! -f "$(calls_of "$cwd")" ]] && ok "hadolint NOT invoked when only non-Dockerfile changed" \
  || bad "docker gate" "hadolint ran on idle turn: $(cat "$(calls_of "$cwd")" 2>/dev/null)"

# ---------------------------------------------------------------------------
hdr "Dockerfile: hadolint failure surfaces as decision:continue in block mode"
# ---------------------------------------------------------------------------
mk_stub "$stub_dir" hadolint 'echo "DL3008 Pin versions in apt-get install" >&2' 'exit 1'
( cd "$cwd" && printf 'FROM alpine\nRUN apt-get install foo\n' > Dockerfile )
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=dockerfile LINT_ENFORCER_MODE=block
assert_continue
printf '%s' "$HOOK_STDOUT" | grep -q 'hadolint' && ok "reason mentions hadolint" \
  || bad "docker reason" "stdout='$HOOK_STDOUT'"
printf '%s' "$HOOK_STDOUT" | grep -q 'DL3008' && ok "reason quotes the hadolint finding (stderr captured too)" \
  || bad "docker excerpt" "stdout='$HOOK_STDOUT'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "GitHub Actions: actionlint invoked on workflow change"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox gha-basic)
mkdir -p "$cwd/.github/workflows"
printf 'name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' > "$cwd/.github/workflows/ci.yml"
git_sandbox "$cwd" "printf 'name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n      - run: echo bye\n' > .github/workflows/ci.yml"
stub_dir=$(mktemp -d)
mk_stub "$stub_dir" actionlint "$RECORD" 'exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=github_actions
[[ -f "$(calls_of "$cwd")" ]] && ok "actionlint invoked on workflow change" \
  || bad "gha invoke" "actionlint not called; stderr='$HOOK_STDERR'"

# ---------------------------------------------------------------------------
hdr "GitHub Actions: idle turn skips actionlint (no workflow changes)"
# ---------------------------------------------------------------------------
rm -f "$(calls_of "$cwd")"
( cd "$cwd" && git add -A && git commit -q -m update )
( cd "$cwd" && echo 'noise' > README.md )
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=github_actions
[[ ! -f "$(calls_of "$cwd")" ]] && ok "actionlint NOT invoked when only non-workflow changed" \
  || bad "gha gate" "actionlint ran on idle turn: $(cat "$(calls_of "$cwd")" 2>/dev/null)"

# ---------------------------------------------------------------------------
hdr "GitHub Actions: actionlint failure surfaces as decision:continue in block mode"
# ---------------------------------------------------------------------------
mk_stub "$stub_dir" actionlint 'echo ".github/workflows/ci.yml:6:9: shellcheck reported issue" >&2' 'exit 1'
( cd "$cwd" && printf 'name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo broken\n' > .github/workflows/ci.yml )
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=github_actions LINT_ENFORCER_MODE=block
assert_continue
printf '%s' "$HOOK_STDOUT" | grep -q 'actionlint' && ok "reason mentions actionlint" \
  || bad "gha reason" "stdout='$HOOK_STDOUT'"
rm -rf "$stub_dir"

# ---------------------------------------------------------------------------
hdr "GitHub Actions: missing actionlint binary is handled gracefully"
# ---------------------------------------------------------------------------
cwd=$(mk_sandbox gha-no-binary)
mkdir -p "$cwd/.github/workflows"
printf 'name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' > "$cwd/.github/workflows/ci.yml"
git_sandbox "$cwd" "printf 'name: ci\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n      - run: echo bye\n' > .github/workflows/ci.yml"
run_hook "$cwd" env PATH="$BASE_PATH" LINT_ENFORCER_LANGS=github_actions
[[ $HOOK_RC -eq 0 ]] && ok "exits 0 when actionlint binary missing" \
  || bad "gha missing binary" "rc=$HOOK_RC stderr='$HOOK_STDERR'"
assert_noop
printf '%s' "$HOOK_STDERR" | grep -q 'actionlint not on PATH' \
  && ok "logged missing-binary message" || bad "gha missing binary msg" "stderr='$HOOK_STDERR'"

# ---------------------------------------------------------------------------
hdr "Contract: a chatty tool cannot corrupt the JSON on stdout"
# ---------------------------------------------------------------------------
cwd=$(tf_failing_sandbox chatty)
stub_dir=$(mktemp -d)
# Tools that talk on both streams: everything they print is captured for the
# reason or dropped, never forwarded to the host's stdout, which stays `{}`.
mk_stub "$stub_dir" terraform 'exit 0'
mk_stub "$stub_dir" tflint 'echo "noise on stdout"; echo "noise on stderr" >&2; exit 0'
run_hook "$cwd" env PATH="$stub_dir:$BASE_PATH" LINT_ENFORCER_LANGS=terraform
rm -rf "$stub_dir"
assert_noop
printf '%s' "$HOOK_STDOUT" | jq -e . >/dev/null 2>&1 && ok "stdout parses as JSON" || bad "json parse" "stdout='$HOOK_STDOUT'"

# ---------------------------------------------------------------------------
hdr "Summary"
# ---------------------------------------------------------------------------
printf '  PASS: %d   FAIL: %d\n\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
