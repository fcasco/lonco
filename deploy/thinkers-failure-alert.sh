#!/usr/bin/env bash
set -euo pipefail

# deploy/thinkers-failure-alert.sh — OnFailure= hook for
# headlong-thinkers@<identity>.service (fired via headlong-thinkers-alert@).
# With Restart=on-failure on the unit, OnFailure fires only when the start
# limit is exhausted, so this alert means "died repeatedly, auto-restart
# gave up, the mind is STAYING DOWN". Per-death and recovery notices are
# deploy/thinkers-death-alert.sh's job.
#
# Usage: thinkers-failure-alert.sh APP_DIR IDENTITY
#
# Config (APP_DIR/.env): HEADLONG_ALERT_URL — the webhook to POST the alert
# to (HEADLONG_ALERT_TOKEN is sent as a Bearer header when set). Missing
# config degrades to a line in
# /var/tmp/headlong-thinkers-alert.log, never a unit failure: the alert path
# must not add its own failure mode on top of a dead mind.

APP_DIR="${1:?usage: thinkers-failure-alert.sh APP_DIR IDENTITY}"
IDENT="${2:?identity name required}"

FALLBACK_LOG="/var/tmp/headlong-thinkers-alert.log"

# Belt-and-suspenders: the unit's EnvironmentFile= already loads this (as
# root); sourcing here covers manual runs. Never fatal — the alert must not
# add its own failure mode.
if [[ -r "$APP_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$APP_DIR/.env" 2>/dev/null || true
    set +a
fi

# Framework var: HEADLONG_ first, legacy SHELLM_ fallback (the box .env still
# carries the old name until it is rewritten).
ALERT_URL="${HEADLONG_ALERT_URL:-${SHELLM_ALERT_URL:-}}"
ALERT_TOKEN="${HEADLONG_ALERT_TOKEN:-${SHELLM_ALERT_TOKEN:-}}"

unit="headlong-thinkers@${IDENT}.service"
info=$(systemctl show "$unit" \
    -p Result,ExecMainStatus,ExecMainExitTimestampMonotonic,ExecMainExitTimestamp 2>/dev/null || true)
log_tail=$(tail -n 8 "$APP_DIR/.identities/$IDENT/run/logs/dispatcher.log" 2>/dev/null || true)

text="${unit} FAILED and auto-restart GAVE UP — the ${IDENT} dispatcher died repeatedly (start limit: 3 unclean deaths in 15 min) and is STAYING DOWN.
---
${info}
--- dispatcher.log tail ---
${log_tail}
---
Investigate first, then restart: \`sudo headlong-thinkersctl start ${IDENT}\` on the box."

if [[ -z "$ALERT_URL" ]]; then
    printf '%s [thinkers-alert] %s failed; alert webhook not configured (need HEADLONG_ALERT_URL in %s/.env)\n' \
        "$(date -u +%FT%TZ)" "$unit" "$APP_DIR" >> "$FALLBACK_LOG"
    exit 0
fi

payload=$(jq -nc --arg text "$text" '{text: $text}')
headers=(-H "Content-Type: application/json; charset=utf-8")
[[ -n "$ALERT_TOKEN" ]] && headers+=(-H "Authorization: Bearer $ALERT_TOKEN")
resp=$(curl -sS -m 15 -X POST "$ALERT_URL" \
    "${headers[@]}" --data "$payload" 2>&1 || true)
if [[ -n "$resp" && "$resp" != "ok" && "$resp" != '{"ok":true}' ]]; then
    printf '%s [thinkers-alert] alert post for %s failed: %s\n' \
        "$(date -u +%FT%TZ)" "$unit" "$resp" >> "$FALLBACK_LOG"
fi
