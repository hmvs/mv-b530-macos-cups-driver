#!/bin/sh
# CUPS backend for the Kmart/Anko Inkless A4 (MV-B530).
#
# Runs as _lp under cupsd. That context can never hold a Bluetooth TCC grant,
# and macOS additionally sandboxes backends away from arbitrary filesystem
# paths - a shared spool directory under /usr/local is not even stat-able.
# So the job is handed to the user-session agent over loopback HTTP, which
# the sandbox does permit (ipp/socket/lpd backends need networking).

AGENT_URL="${TIMINI_AGENT_URL:-http://127.0.0.1:9101/print}"
TIMEOUT=300

# No arguments: device discovery.
if [ $# -eq 0 ]; then
    echo 'direct timini:/mv_b530 "Anko Inkless A4" "Anko Inkless A4 Printer (MV-B530)" "MFG:KM;MDL:P800;CMD:TIMINI;"'
    exit 0
fi

if [ $# -lt 5 ] || [ $# -gt 6 ]; then
    echo "Usage: timini job-id user title copies options [file]" >&2
    exit 1
fi

OPTIONS="$5"
INPUT="$6"

DARK=$(printf '%s' "$OPTIONS" | sed -n 's/.*Darkness=\([1-5]\).*/\1/p')
[ -n "$DARK" ] || DARK=3

echo "INFO: sending job to the print agent" >&2

# CUPS backend exit codes
OK=0; FAILED=1; RETRY=6

[ -n "$INPUT" ] && SRC="@$INPUT" || SRC="@-"

RESP=$(curl -sS --max-time "$TIMEOUT" -w '\n%{http_code}' \
    -H "Content-Type: application/pdf" \
    -H "X-Timini-Darkness: $DARK" \
    --data-binary "$SRC" "$AGENT_URL" 2>&1)
CURL_STATUS=$?
CODE=$(printf '%s' "$RESP" | tail -1)
BODY=$(printf '%s' "$RESP" | sed '$d')

# Agent not running. Retry rather than fail: failing makes CUPS disable the
# whole queue, and the fix (start the agent) is one the user can still do.
if [ "$CURL_STATUS" -eq 7 ]; then
    echo "ERROR: cannot reach the print agent at $AGENT_URL - start it with start-agent.sh" >&2
    exit $RETRY
fi

if [ "$CURL_STATUS" -ne 0 ]; then
    echo "ERROR: transport error talking to the print agent (curl exit $CURL_STATUS)" >&2
    printf '%s\n' "$BODY" | tail -c 400 >&2
    exit $RETRY
fi

case "$CODE" in
    200)
        echo "INFO: printed" >&2
        exit $OK
        ;;
    503)
        # Printer asleep or out of range. Keep the queue enabled and let CUPS
        # come back to it - these printers auto-power-off constantly.
        echo "INFO: printer unreachable, will retry" >&2
        exit $RETRY
        ;;
    *)
        echo "ERROR: print failed (HTTP $CODE):" >&2
        printf '%s\n' "$BODY" | tail -c 800 >&2
        exit $FAILED
        ;;
esac
