#!/bin/bash
# Shared Codex plumbing for shunt's delegation scripts.
#
# Everything goes through `codex exec`, which signs in with the ChatGPT
# account Codex is logged into — the work is billed to that subscription,
# not to an API key.
#
# The worker instructions live here rather than in a server-side mode: each
# call sends the instructions for its mode followed by the message.
#
# Every delegation is one shot. --ephemeral keeps nothing on disk, and the
# only way to carry context across calls would be to replay it from this
# side, which for a file corpus is the very cost the plugin exists to avoid.
# Ask again with the files instead.

# Worker model. Any model `codex exec -m` accepts.
SHUNT_MODEL="${SHUNT_MODEL:-gpt-6-luna}"

# Reasoning effort for the worker; bulk reads and boilerplate need little.
SHUNT_REASONING_EFFORT="${SHUNT_REASONING_EFFORT:-low}"

# The message travels on stdin, so ARG_MAX no longer bounds it. The ceiling
# that remains is the worker's context window; ~4 bytes per token keeps the
# default well inside it.
SHUNT_MAX_PAYLOAD_BYTES="${SHUNT_MAX_PAYLOAD_BYTES:-800000}"

# Ceiling for one invocation; large generations can take a while.
SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-180}"

if [ -n "${CODEX_BIN:-}" ]; then
  read -ra SHUNT_CODEX_CMD <<< "$CODEX_BIN"
else
  SHUNT_CODEX_CMD=(codex)
fi

# --ignore-user-config and --ignore-rules keep the user's own Codex setup
# (default model, hooks, MCP servers, exec rules) out of the worker: they add
# thousands of tokens per call and nothing the worker needs. Auth still comes
# from CODEX_HOME. The worker runs in an empty read-only directory, so the
# only files it can see are the ones in the message.
shunt_codex() {
  "${SHUNT_CODEX_CMD[@]}" exec \
    -m "$SHUNT_MODEL" \
    -c "model_reasoning_effort=\"$SHUNT_REASONING_EFFORT\"" \
    --sandbox read-only \
    --skip-git-repo-check \
    --ephemeral \
    --ignore-user-config \
    --ignore-rules \
    --color never \
    "$@"
}

# mktemp with cleanup on script exit. Usage: shunt_tmpfile <varname>
SHUNT_TMPFILES=()
shunt_tmpfile() {
  local f
  f=$(mktemp) || return 1
  SHUNT_TMPFILES+=("$f")
  trap 'rm -rf "${SHUNT_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$f"
}

# mktemp -d with the same cleanup. Usage: shunt_tmpdir <varname>
shunt_tmpdir() {
  local d
  d=$(mktemp -d) || return 1
  SHUNT_TMPFILES+=("$d")
  trap 'rm -rf "${SHUNT_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$d"
}

shunt_preflight() {
  local missing=""
  command -v jq >/dev/null 2>&1 || missing=" jq"
  if ! command -v "${SHUNT_CODEX_CMD[0]}" >/dev/null 2>&1; then
    missing="$missing ${SHUNT_CODEX_CMD[0]}"
  fi

  if [ -n "$missing" ]; then
    echo "Error: missing required command(s):$missing" >&2
    echo "  jq    — brew install jq" >&2
    echo "  codex — npm i -g @openai/codex (or the ChatGPT app's bundled CLI), or set CODEX_BIN" >&2
    return 1
  fi
  return 0
}

# Instructions for each worker mode, sent ahead of the message.
shunt_mode_instructions() {
  case "$1" in
    bulk-reader)
      echo "You are a precise code analyst. Read the provided files and answer the question concisely. Output structured bullets only. No greetings, no prose, no preambles, no summaries. Lead every bullet with the exact name, type, or line number. Use nested bullets for details. Skip anything the caller did not ask for."
      ;;
    code-writer)
      echo "You generate code files based on a spec and reference files. Match the existing patterns, conventions, naming, and style exactly. Output only the code — no explanations, no markdown fences unless asked. If the spec is ambiguous, make reasonable choices that match the patterns in the reference code."
      ;;
    *)
      return 1
      ;;
  esac
  echo "Everything you need is in this message. Do not run commands, read files, or edit anything — reply with text only."
}

# Runs `codex exec` with a watchdog: macOS ships no timeout(1).
#   $1 seconds, $2 file fed on stdin, rest: arguments for shunt_codex
# Returns 124 on timeout, like timeout(1).
#
# stdin is redirected explicitly: a background job in a non-interactive
# shell otherwise reads /dev/null.
shunt_run_with_timeout() {
  local seconds="$1" input="$2"; shift 2
  local pid watcher rc

  shunt_codex "$@" < "$input" &
  pid=$!
  ( sleep "$seconds" && kill -TERM "$pid" ) 2>/dev/null &
  watcher=$!

  wait "$pid"
  rc=$?
  if kill -0 "$watcher" 2>/dev/null; then
    pkill -P "$watcher" 2>/dev/null
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return "$rc"
  fi
  return 124
}

# Runs one ephemeral turn against a mode and prints the answer.
#   $1 mode name
#   $2 file holding the message
shunt_invoke() {
  local mode_name="$1" message_file="$2"
  local instructions prompt_file answer_file log_file workdir bytes rc text

  if ! instructions=$(shunt_mode_instructions "$mode_name"); then
    echo "Error: unknown mode \"$mode_name\"." >&2
    return 1
  fi

  shunt_tmpfile prompt_file || return 1
  shunt_tmpfile answer_file || return 1
  shunt_tmpfile log_file || return 1
  shunt_tmpdir workdir || return 1

  { printf '%s\n\n' "$instructions"; cat "$message_file"; } > "$prompt_file"

  bytes=$(wc -c < "$prompt_file" | tr -d ' ')
  if [ "$bytes" -gt "$SHUNT_MAX_PAYLOAD_BYTES" ]; then
    echo "Error: request is $bytes bytes, over the $SHUNT_MAX_PAYLOAD_BYTES byte limit." >&2
    echo "The worker model's context window bounds a single call." >&2
    echo "Send fewer or smaller files, or raise SHUNT_MAX_PAYLOAD_BYTES if there is headroom." >&2
    return 1
  fi

  # The answer comes from -o, which holds only the final message. Progress
  # output on stdout/stderr goes to the log, read only when the call fails.
  shunt_run_with_timeout "$SHUNT_TIMEOUT_SECONDS" "$prompt_file" \
    -C "$workdir" -o "$answer_file" - > "$log_file" 2>&1
  rc=$?

  if [ "$rc" -eq 124 ]; then
    echo "Error: codex exec timed out after ${SHUNT_TIMEOUT_SECONDS}s." >&2
    echo "Raise SHUNT_TIMEOUT_SECONDS or split the work into smaller calls." >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "Error: codex exec failed (exit $rc, model $SHUNT_MODEL):" >&2
    tail -n 20 "$log_file" >&2
    echo "If Codex is not signed in, run \`codex login\` and pick ChatGPT sign-in." >&2
    return 1
  fi

  text=$(cat "$answer_file")
  if [ -z "$text" ]; then
    echo "Error: codex exec returned no answer (model $SHUNT_MODEL):" >&2
    tail -n 20 "$log_file" >&2
    return 1
  fi

  printf '%s\n' "$text"
}
