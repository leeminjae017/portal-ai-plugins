#!/bin/bash
# Transport evals for scripts/lib/codex.sh.
#
# Runs against a stubbed `codex exec`, so these need no sign-in and no
# subscription usage — the benchmark suite covers the real round trip.
#
# Prints one PASS/FAIL line per check plus a machine-readable "## <pass> <fail>"
# trailer for run.sh. Runs as its own process so the stub cannot leak into the
# benchmark suite.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
CAPTURED_PROMPT="$WORKDIR/captured-prompt.txt"
CAPTURED_ARGS="$WORKDIR/captured-args"

# shellcheck source=../scripts/lib/codex.sh
. "$PLUGIN_DIR/scripts/lib/codex.sh"

# Pulls the value following a flag out of the stub's argv. Usage: arg_after <flag>
stub_arg_after() {
  local want="$1"; shift
  local take=false arg
  for arg in "$@"; do
    if [ "$take" = true ]; then printf '%s' "$arg"; return; fi
    [ "$arg" = "$want" ] && take=true
  done
}

# Stub the codex binary: record argv and the prompt on stdin, write a canned
# final message to the -o file and progress noise to stdout/stderr, the way
# `codex exec` does. Stubbing the binary rather than shunt_codex keeps the
# flags shunt_codex adds under test.
STUB_ANSWER=$'- first line\n- second line'
SHUNT_CODEX_CMD=(codex_stub)
codex_stub() {
  printf '%s\n' "$@" > "$CAPTURED_ARGS"
  cat > "$CAPTURED_PROMPT"
  echo "codex progress noise"
  echo "tokens used" >&2
  printf '%s' "$STUB_ANSWER" > "$(stub_arg_after -o "$@")"
}

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$4"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-32s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

# ── Invocation ──

message_file="$WORKDIR/message.txt"
printf 'line one\nline two\n' > "$message_file"

check "answer-text-extracted" "- first line
- second line" "$(shunt_invoke bulk-reader "$message_file")" \
  "reads the -o file, not the progress output"
check "message-sent" "line one
line two" "$(tail -n 2 "$CAPTURED_PROMPT")" \
  "message survives the round trip verbatim"
check "mode-instructions-sent" "y" "$(grep -q 'precise code analyst' "$CAPTURED_PROMPT" && echo y || echo n)" \
  "the mode's instructions lead the prompt"
check "prompt-on-stdin" "-" "$(tail -n 1 "$CAPTURED_ARGS")" \
  "the prompt travels on stdin, not argv"

# ── Flags ──

stub_flag() { grep -x -A1 -- "$1" "$CAPTURED_ARGS" | tail -1; }
has_flag() { grep -qx -- "$1" "$CAPTURED_ARGS" && echo y || echo n; }

check "default-model-sent" "gpt-6-luna" "$(stub_flag -m)" "Luna is the default worker"
check "reasoning-effort-sent" 'model_reasoning_effort="low"' "$(stub_flag -c)" \
  "the worker runs at low effort by default"
check "read-only-sandbox" "read-only" "$(stub_flag --sandbox)" "the worker cannot write"
check "ephemeral" "y" "$(has_flag --ephemeral)" "every delegation is one shot"
check "user-config-ignored" "y" "$(has_flag --ignore-user-config)" \
  "the user's hooks and MCP servers stay out of the worker"
check "empty-workdir" "0" "$(ls -A "$(stub_flag -C)" 2>/dev/null | wc -l | tr -d ' ')" \
  "the worker sees only the files in the message"

SHUNT_MODEL="gpt-5.6-luna"
shunt_invoke bulk-reader "$message_file" >/dev/null
check "model-override-sent" "gpt-5.6-luna" "$(stub_flag -m)" "SHUNT_MODEL picks the worker"
SHUNT_MODEL="gpt-6-luna"

# ── Failures ──

( shunt_invoke no-such-mode "$message_file" >/dev/null 2>&1 ) && rc=0 || rc=$?
check "unknown-mode-fails" "1" "$rc" "a mode with no instructions is an error"

( codex_stub() { cat >/dev/null; echo "Not signed in" >&2; return 1; }
  guard=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && exit 1
  case "$guard" in *"Not signed in"*"codex login"*) exit 0 ;; *) exit 1 ;; esac ) \
  && rc=0 || rc=$?
check "codex-error-surfaced" "0" "$rc" "codex's own error and the login hint surface"

( codex_stub() { cat >/dev/null; echo "noise"; }
  shunt_invoke bulk-reader "$message_file" >/dev/null 2>&1 ) && rc=0 || rc=$?
check "empty-answer-fails" "1" "$rc" "an answer with no text is an error"

( codex_stub() { cat >/dev/null; sleep 5; }
  SHUNT_TIMEOUT_SECONDS=1
  guard=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && exit 1
  case "$guard" in *"timed out after 1s"*) exit 0 ;; *) exit 1 ;; esac ) \
  && rc=0 || rc=$?
check "timeout-enforced" "0" "$rc" "a hung worker is killed and reported"

# ── Payload ceiling ──

saved_payload_bytes="$SHUNT_MAX_PAYLOAD_BYTES"
SHUNT_MAX_PAYLOAD_BYTES=10
guard_output=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && rc=0 || rc=$?
check "oversized-payload-fails" "1" "$rc" "input must fit the context window"
case "$guard_output" in
  *"over the 10 byte limit"*) check "oversized-payload-explained" "y" "y" "error names the limit" ;;
  *)                          check "oversized-payload-explained" "y" "n" "error names the limit" ;;
esac
SHUNT_MAX_PAYLOAD_BYTES="$saved_payload_bytes"

rm -rf "$WORKDIR"

echo "## $PASSED $FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
