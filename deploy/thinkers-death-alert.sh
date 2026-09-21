#!/usr/bin/env bash
set -euo pipefail

# deploy/thinkers-death-alert.sh — per-death and back-up notices for
# headlong-thinkers@<identity>.service. Companion to
# deploy/thinkers-failure-alert.sh (which, with Restart=on-failure on the
# unit, only fires when auto-restart gives up); this one fires on EVERY
# unclean death and on the recovery:
#
#   ExecStopPost  → thinkers-death-alert.sh APP_DIR IDENT died
#   ExecStartPost → thinkers-death-alert.sh APP_DIR IDENT started
#
# died: systemd sets $SERVICE_RESULT/$EXIT_CODE/$EXIT_STATUS for
# ExecStopPost. Clean stops (SERVICE_RESULT=success) post nothing. Unclean
# deaths post the cause — including which signal the dispatcher trapped
# (run/last_signal, written by _dispatcher_on_signal in bin/thinkers) — and
# drop run/down_since so the next successful start can announce recovery
# with the measured downtime.
#
# started: if run/down_since exists, post the all-clear and remove it;
# otherwise stay silent (normal starts are not news).
#
# Same failure-open contract as thinkers-failure-alert.sh: missing config
# degrades to a line in /var/tmp/headlong-thinkers-alert.log, never a unit
# failure — the alert path must not add its own failure mode on top of a
# dead mind.

APP_DIR="${1:?usage: thinkers-death-alert.sh APP_DIR IDENTITY died|started}"
IDENT="${2:?identity name required}"
MODE="${3:?mode required (died|started)}"

FALLBACK_LOG="/var/tmp/headlong-thinkers-alert.log"
RUN_DIR="$APP_DIR/.identities/$IDENT/run"
unit="headlong-thinkers@${IDENT}.service"

if [[ -r "$APP_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$APP_DIR/.env" 2>/dev/null || true
    set +a
fi

# Webhook target: HEADLONG_ALERT_URL, with HEADLONG_ALERT_TOKEN sent as a
# Bearer token when set (a webhook URL usually carries its own auth). The
# box .env carries both (HEADLONG_ first, legacy SHELLM_ fallback).
ALERT_URL="${HEADLONG_ALERT_URL:-${SHELLM_ALERT_URL:-}}"
ALERT_TOKEN="${HEADLONG_ALERT_TOKEN:-${SHELLM_ALERT_TOKEN:-}}"

post_alert() {
    local text="$1"
    if [[ -z "$ALERT_URL" ]]; then
        printf '%s [thinkers-death-alert] %s (%s); alert webhook not configured (need HEADLONG_ALERT_URL in %s/.env)\n' \
            "$(date -u +%FT%TZ)" "$unit" "$MODE" "$APP_DIR" >> "$FALLBACK_LOG"
        return 0
    fi
    local payload resp headers=(-H "Content-Type: application/json; charset=utf-8")
    payload=$(jq -nc --arg text "$text" '{text: $text}')
    [[ -n "$ALERT_TOKEN" ]] && headers+=(-H "Authorization: Bearer $ALERT_TOKEN")
    resp=$(curl -sS -m 15 -X POST "$ALERT_URL" \
        "${headers[@]}" --data "$payload" 2>&1 || true)
    if [[ -n "$resp" && "$resp" != "ok" && "$resp" != '{"ok":true}' ]]; then
        printf '%s [thinkers-death-alert] alert post for %s (%s) failed: %s\n' \
            "$(date -u +%FT%TZ)" "$unit" "$MODE" "$resp" >> "$FALLBACK_LOG"
    fi
}

case "$MODE" in
    died)
        # systemd's verdict on how the service ended. Manual runs won't have
        # it set — treat unknown as unclean so a real death never goes
        # unreported.
        result="${SERVICE_RESULT:-unknown}"
        if [[ "$result" == "success" ]]; then
            exit 0
        fi

        # Which signal the dispatcher trapped, if its handler got to write
        # the marker. Only trust a marker from THIS death, not one left by
        # an earlier incident.
        sig=""
        if [[ -f "$RUN_DIR/last_signal" ]]; then
            now=$(date +%s)
            mt=$(stat -c %Y "$RUN_DIR/last_signal" 2>/dev/null || echo 0)
            if (( now - mt < 300 )); then
                sig=$(cat "$RUN_DIR/last_signal" 2>/dev/null || true)
            fi
        fi
        log_tail=$(tail -n 6 "$RUN_DIR/logs/dispatcher.log" 2>/dev/null || true)

        date +%s > "$RUN_DIR/down_since" 2>/dev/null || true

        text="${unit} DIED — result=${result}, exit=${EXIT_CODE:-?}/${EXIT_STATUS:-?}${sig:+, dispatcher trapped ${sig}}. Auto-restart in ~60s (gives up after 3 unclean deaths in 15 min).
---
${log_tail}"
        post_alert "$text"
        ;;
    started)
        if [[ ! -f "$RUN_DIR/down_since" ]]; then
            exit 0
        fi
        down_since=$(cat "$RUN_DIR/down_since" 2>/dev/null || true)
        rm -f "$RUN_DIR/down_since"
        downtime="unknown"
        if [[ "$down_since" =~ ^[0-9]+$ ]]; then
            secs=$(( $(date +%s) - down_since ))
            downtime="$(( secs / 60 ))m$(( secs % 60 ))s"
        fi
        post_alert "${unit} back up — down ${downtime}. The wake note covers the gap; queued messages deliver now."
        ;;
    *)
        echo "error: unknown mode: $MODE (want died|started)" >&2
        exit 2
        ;;
esac
