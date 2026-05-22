#!/bin/sh
set -e

# Fix data directory permissions when running as root.
# Docker named volumes / host bind-mounts may be owned by root,
# preventing the non-root sub2api user from writing files.
if [ "$(id -u)" = "0" ]; then
    mkdir -p /app/data /app/redis
    # Use || true to avoid failure on read-only mounted files (e.g. config.yaml:ro)
    chown -R sub2api:sub2api /app/data /app/redis 2>/dev/null || true
    # Re-invoke this script as sub2api so the flag-detection below
    # also runs under the correct user.
    exec su-exec sub2api "$0" "$@"
fi

should_start_embedded_redis() {
    case "${EMBEDDED_REDIS:-auto}" in
        true|1|yes)
            return 0
            ;;
        false|0|no)
            return 1
            ;;
    esac

    if [ -n "${REDIS_URL:-}" ] || [ -n "${REDIS_DSN:-}" ]; then
        return 1
    fi

    case "${REDIS_HOST:-127.0.0.1}" in
        127.0.0.1|localhost)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

start_embedded_redis() {
    should_start_embedded_redis || return 1

    export REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
    export REDIS_PORT="${REDIS_PORT:-6379}"
    export REDIS_DB="${REDIS_DB:-0}"

    mkdir -p /app/redis
    REDIS_BIND_HOST="$REDIS_HOST"
    if [ "$REDIS_BIND_HOST" = "localhost" ]; then
        REDIS_BIND_HOST="127.0.0.1"
    fi

    if [ -n "${REDIS_PASSWORD:-}" ]; then
        redis-server \
            --bind "$REDIS_BIND_HOST" \
            --port "$REDIS_PORT" \
            --dir /app/redis \
            --save "" \
            --appendonly no \
            --protected-mode yes \
            --requirepass "$REDIS_PASSWORD" &
    else
        redis-server \
            --bind "$REDIS_BIND_HOST" \
            --port "$REDIS_PORT" \
            --dir /app/redis \
            --save "" \
            --appendonly no \
            --protected-mode yes &
    fi
    REDIS_PID="$!"

    i=0
    until REDISCLI_AUTH="${REDIS_PASSWORD:-}" redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge "${REDIS_STARTUP_RETRIES:-50}" ]; then
            echo "Redis failed to start" >&2
            exit 1
        fi
        sleep 0.1
    done
}

stop_embedded_redis() {
    if [ -n "${REDIS_PID:-}" ]; then
        kill "$REDIS_PID" 2>/dev/null || true
        wait "$REDIS_PID" 2>/dev/null || true
    fi
}

# Compatibility: if the first arg looks like a flag (e.g. --help),
# prepend the default binary so it behaves the same as the old
# ENTRYPOINT ["/app/sub2api"] style.
if [ "${1#-}" != "$1" ]; then
    set -- /app/sub2api "$@"
fi

if [ "$1" = "/app/sub2api" ] || [ "$1" = "sub2api" ]; then
    if start_embedded_redis; then
        "$@" &
        APP_PID="$!"
        trap 'kill "$APP_PID" 2>/dev/null || true; stop_embedded_redis' INT TERM EXIT
        STATUS=0
        wait "$APP_PID" || STATUS="$?"
        stop_embedded_redis
        trap - INT TERM EXIT
        exit "$STATUS"
    fi
fi

exec "$@"
