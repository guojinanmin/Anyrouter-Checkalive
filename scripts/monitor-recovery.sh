#!/usr/bin/env bash
# monitor-recovery.sh - Poll all tokens every 30min, detect recovery, alert immediately
# Designed for manual-trigger GitHub Actions workflow (6h container).
# Reuses keepalive.sh for health checks.
# Usage: monitor-recovery.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
BASE_URL="${BASE_URL:-https://a-ocnfniawgw.cn-shanghai.fcapp.run}"
MODEL="${MODEL:-opus[1m]}"
POLL_INTERVAL="${POLL_INTERVAL:-1800}"          # 30 minutes between rounds
MAX_DURATION_SEC="${MAX_DURATION_SEC:-21500}"   # ~5h58m (just under 6h)
QQ_EMAIL="${QQ_EMAIL:-}"
QQ_SMTP_AUTH_CODE="${QQ_SMTP_AUTH_CODE:-}"

# --- Load tokens (reused from run-all.sh) ---
load_tokens() {
    if [ -n "${ANYROUTER_TOKENS:-}" ]; then
        echo "$ANYROUTER_TOKENS"
        return
    fi
    if [ -f "$SCRIPT_DIR/../.env" ]; then
        local val
        val=$(grep -E '^ANYROUTER_TOKENS=' "$SCRIPT_DIR/../.env" 2>/dev/null | sed 's/^ANYROUTER_TOKENS=//' | sed 's/^"//;s/"$//' || true)
        if [ -n "$val" ]; then
            echo "$val" | tr ',' '\n'
            return
        fi
    fi
    echo "ERROR: No tokens found. Set ANYROUTER_TOKENS env var or create .env file." >&2
    exit 1
}

# --- Send email alert (reused from run-all.sh) ---
send_email() {
    local subject="$1" body="$2"
    if [ -z "$QQ_EMAIL" ] || [ -z "$QQ_SMTP_AUTH_CODE" ]; then
        echo "  (Skipping email: QQ_EMAIL or QQ_SMTP_AUTH_CODE not configured)"
        return 0
    fi
    if ! curl --version 2>/dev/null | grep -qi "smtp"; then
        echo "  Email failed: curl was not compiled with SMTP support"
        return 1
    fi
    local mail_file
    mail_file=$(mktemp)
    cat > "$mail_file" <<EOF
From: $QQ_EMAIL
To: $QQ_EMAIL
Subject: $subject
Content-Type: text/plain; charset=utf-8

$body
EOF
    echo "  Sending alert email via QQ SMTP to $QQ_EMAIL ..."
    local curl_exit=0
    curl -sS --ssl-reqd --fail-with-body \
        --url "smtps://smtp.qq.com:465" \
        --user "$QQ_EMAIL:$QQ_SMTP_AUTH_CODE" \
        --login-options "AUTH=LOGIN" \
        --mail-from "$QQ_EMAIL" \
        --mail-rcpt "$QQ_EMAIL" \
        --upload-file "$mail_file" \
        || curl_exit=$?
    rm -f "$mail_file"
    if [ "$curl_exit" -eq 0 ]; then
        echo "  Alert email sent to $QQ_EMAIL"
        return 0
    else
        echo "  Alert email FAILED (curl exit: $curl_exit)"
        return 1
    fi
}

# --- Main ---
TOKENS_DATA=$(load_tokens)
mapfile -t TOKENS <<< "$TOKENS_DATA"
if [ ${#TOKENS[@]} -eq 0 ]; then
    echo "ERROR: No tokens loaded. Exiting." >&2
    exit 1
fi
echo "Loaded ${#TOKENS[@]} token(s)"
echo "Base URL: $BASE_URL"
echo "Model: $MODEL"
echo "Poll interval: ${POLL_INTERVAL}s"
echo ""

# Track each token's previous state. Values: "success" or "failed"
# On first round the token has no previous state (empty) — no alert sent.
declare -A PREV_STATES

START_TIME=$(date +%s)
ROUND=1
ALERTS_SENT=0

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -le 0 ]; then
        echo "=== Time limit reached. Exiting. ==="
        break
    fi

    echo "============================================="
    echo " Round $ROUND  |  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo " Elapsed: ${ELAPSED}s  |  Remaining: ~${REMAINING}s"
    echo "============================================="

    for i in "${!TOKENS[@]}"; do
        token="${TOKENS[$i]}"
        token_preview="${token:0:5}..."
        prev_state="${PREV_STATES[$token]:-}"

        # Check remaining time before each token
        NOW=$(date +%s)
        if [ $((NOW - START_TIME)) -ge "$MAX_DURATION_SEC" ]; then
            echo "Time limit reached mid-round. Breaking."
            break
        fi

        echo "[$((i+1))/${#TOKENS[@]}] Testing $token_preview ..."

        # Measure wall-clock time of the health check
        CHECK_START=$(date +%s)
        if result=$(bash "$SCRIPT_DIR/keepalive.sh" "$token" "$BASE_URL" "$MODEL" 2>&1); then
            CHECK_END=$(date +%s)
            response_time=$((CHECK_END - CHECK_START))
            echo "$result"
            echo "  ✓ $token_preview active (${response_time}s)"

            PREV_STATES[$token]="success"

            # Recovery detected: was not in success state, now succeeds
            if [ "$prev_state" != "success" ]; then
                ALERTS_SENT=$((ALERTS_SENT + 1))
                echo ""
                echo "  ########################################"
                echo "  #  RECOVERY DETECTED: $token_preview"
                echo "  #  Response time: ${response_time}s"
                echo "  ########################################"
                echo ""

                send_email \
                    "ANYROUTER 已恢复 - 现在可以用了！" \
                    "Token: $token_preview
状态: ✅ 已恢复 (从不可用变为可用)
响应时间: ${response_time} 秒
检测时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
轮次: 第 ${ROUND} 轮

Anyrouter 已恢复工作，请确认使用。"
            fi
        else
            echo "$result"
            echo "  ✗ $token_preview failed"
            PREV_STATES[$token]="failed"
        fi

        # Brief pause between tokens
        if [ "$i" -lt "$(( ${#TOKENS[@]} - 1 ))" ]; then
            JITTER=$(( 30 + (RANDOM % 21) - 10 ))
            [ "$JITTER" -lt 10 ] && JITTER=10
            echo "  Waiting ${JITTER}s ..."
            sleep "$JITTER"
        fi
    done

    ROUND=$((ROUND + 1))

    # Sleep until next poll (respecting time limit)
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -gt "$POLL_INTERVAL" ]; then
        echo ""
        echo "--- Next round in ${POLL_INTERVAL}s ($((POLL_INTERVAL / 60)) min) ---"
        sleep "$POLL_INTERVAL"
    elif [ "$REMAINING" -gt 60 ]; then
        echo ""
        echo "--- Time nearly up, sleeping final ${REMAINING}s ---"
        sleep "$REMAINING"
    else
        echo "Time limit reached."
    fi
done

echo ""
echo "========================================"
echo " Monitor completed."
echo " Total rounds: $((ROUND - 1))"
echo " Recovery alerts sent: $ALERTS_SENT"
echo "========================================"
