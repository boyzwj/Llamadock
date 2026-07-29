#!/bin/bash

set -euo pipefail

LLAMADOCK_SMOKE_HOST="127.0.0.1"
LLAMADOCK_SMOKE_PORT="${LLAMADOCK_SMOKE_PORT:-18080}"
LLAMADOCK_READINESS_TIMEOUT="${LLAMADOCK_READINESS_TIMEOUT:-120}"
LLAMADOCK_SERVER_PATH="${LLAMADOCK_LLAMA_SERVER:-}"
LLAMADOCK_MODEL_PATH="${LLAMADOCK_MODEL:-}"
LLAMADOCK_SMOKE_PID=""
LLAMADOCK_SMOKE_LOG="$(mktemp /tmp/llamadock-real-smoke.XXXXXX)"
LLAMADOCK_HEALTH_RESPONSE="$(mktemp /tmp/llamadock-health.XXXXXX)"
LLAMADOCK_MODELS_RESPONSE="$(mktemp /tmp/llamadock-models.XXXXXX)"
LLAMADOCK_COMPLETION_RESPONSE="$(mktemp /tmp/llamadock-completion.XXXXXX)"

fail() {
    echo "error: $*" >&2
    exit 1
}

require_absolute_file() {
    local label="$1"
    local path="$2"

    [[ "$path" == /* ]] || fail "$label must be an absolute path"
    [[ -f "$path" ]] || fail "$label does not exist: $path"
}

port_is_listening() {
    nc -z "$LLAMADOCK_SMOKE_HOST" "$LLAMADOCK_SMOKE_PORT" \
        >/dev/null 2>&1
}

stop_owned_server() {
    [[ -n "$LLAMADOCK_SMOKE_PID" ]] || return 0
    kill -0 "$LLAMADOCK_SMOKE_PID" 2>/dev/null || return 0

    kill -TERM "$LLAMADOCK_SMOKE_PID"
    local attempt=0
    while kill -0 "$LLAMADOCK_SMOKE_PID" 2>/dev/null; do
        if [[ "$attempt" -ge 50 ]]; then
            kill -KILL "$LLAMADOCK_SMOKE_PID"
            break
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    wait "$LLAMADOCK_SMOKE_PID" 2>/dev/null || true
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    stop_owned_server

    if [[ "$status" -ne 0 ]]; then
        echo "llama-server log: $LLAMADOCK_SMOKE_LOG" >&2
        tail -n 200 "$LLAMADOCK_SMOKE_LOG" >&2 || true
    else
        rm -f \
            "$LLAMADOCK_SMOKE_LOG" \
            "$LLAMADOCK_HEALTH_RESPONSE" \
            "$LLAMADOCK_MODELS_RESPONSE" \
            "$LLAMADOCK_COMPLETION_RESPONSE"
    fi
    exit "$status"
}

trap cleanup EXIT INT TERM

require_absolute_file "LLAMADOCK_LLAMA_SERVER" "$LLAMADOCK_SERVER_PATH"
[[ -x "$LLAMADOCK_SERVER_PATH" ]] \
    || fail "LLAMADOCK_LLAMA_SERVER is not executable"
require_absolute_file "LLAMADOCK_MODEL" "$LLAMADOCK_MODEL_PATH"

[[ "$LLAMADOCK_SMOKE_PORT" =~ ^[0-9]+$ ]] \
    || fail "LLAMADOCK_SMOKE_PORT must be numeric"
[[ "$LLAMADOCK_SMOKE_PORT" -ge 1 && "$LLAMADOCK_SMOKE_PORT" -le 65535 ]] \
    || fail "LLAMADOCK_SMOKE_PORT must be between 1 and 65535"
[[ "$LLAMADOCK_READINESS_TIMEOUT" =~ ^[0-9]+$ ]] \
    || fail "LLAMADOCK_READINESS_TIMEOUT must be numeric"
command -v nc >/dev/null 2>&1 \
    || fail "nc is required to verify the listening socket"
port_is_listening \
    && fail "${LLAMADOCK_SMOKE_HOST}:${LLAMADOCK_SMOKE_PORT} is already in use"

LLAMADOCK_BASE_URL="http://${LLAMADOCK_SMOKE_HOST}:${LLAMADOCK_SMOKE_PORT}"

"$LLAMADOCK_SERVER_PATH" \
    --model "$LLAMADOCK_MODEL_PATH" \
    --host "$LLAMADOCK_SMOKE_HOST" \
    --port "$LLAMADOCK_SMOKE_PORT" \
    >"$LLAMADOCK_SMOKE_LOG" 2>&1 &
LLAMADOCK_SMOKE_PID=$!

ready=0
for ((attempt = 0; attempt < LLAMADOCK_READINESS_TIMEOUT; attempt++)); do
    kill -0 "$LLAMADOCK_SMOKE_PID" 2>/dev/null \
        || fail "llama-server exited before readiness"

    if curl \
        --fail \
        --silent \
        --max-time 2 \
        --output "$LLAMADOCK_HEALTH_RESPONSE" \
        "${LLAMADOCK_BASE_URL}/health" \
        && grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' \
            "$LLAMADOCK_HEALTH_RESPONSE"; then
        ready=1
        break
    fi
    sleep 1
done
[[ "$ready" -eq 1 ]] || fail "readiness timed out"

curl \
    --fail \
    --silent \
    --show-error \
    --max-time 10 \
    --output "$LLAMADOCK_MODELS_RESPONSE" \
    "${LLAMADOCK_BASE_URL}/v1/models"
grep -q '"object"[[:space:]]*:[[:space:]]*"list"' \
    "$LLAMADOCK_MODELS_RESPONSE" \
    || fail "/v1/models did not return an OpenAI-compatible model list"

curl \
    --fail \
    --silent \
    --show-error \
    --max-time 30 \
    --header "Content-Type: application/json" \
    --data '{"prompt":"Once upon a time","max_tokens":8,"stream":false}' \
    --output "$LLAMADOCK_COMPLETION_RESPONSE" \
    "${LLAMADOCK_BASE_URL}/v1/completions"
grep -q '"choices"[[:space:]]*:' "$LLAMADOCK_COMPLETION_RESPONSE" \
    || fail "/v1/completions did not return choices"

stop_owned_server
kill -0 "$LLAMADOCK_SMOKE_PID" 2>/dev/null \
    && fail "owned llama-server process is still running"
port_is_listening \
    && fail "server socket is still listening after process shutdown"

echo "real runtime smoke passed"
echo "runtime: $LLAMADOCK_SERVER_PATH"
echo "model: $LLAMADOCK_MODEL_PATH"
echo "endpoint: $LLAMADOCK_BASE_URL"
