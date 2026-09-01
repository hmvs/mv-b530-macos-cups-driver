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

# --fail-with-body gives a non-zero exit on 5xx while still surfacing the
# agent's diagnostics, which CUPS records in the job's error log.
if [ -n "$INPUT" ]; then
    BODY=$(curl -sS --fail-with-body --max-time "$TIMEOUT" \
        -H "Content-Type: application/pdf" \
        -H "X-Timini-Darkness: $DARK" \
        --data-binary "@$INPUT" "$AGENT_URL" 2>&1)
    STATUS=$?
else
    BODY=$(curl -sS --fail-with-body --max-time "$TIMEOUT" \
        -H "Content-Type: application/pdf" \
        -H "X-Timini-Darkness: $DARK" \
        --data-binary @- "$AGENT_URL" 2>&1)
    STATUS=$?
fi

if [ "$STATUS" -eq 0 ]; then
    echo "INFO: printed" >&2
    exit 0
fi

if [ "$STATUS" -eq 7 ]; then
    echo "ERROR: cannot reach the print agent at $AGENT_URL." >&2
    echo "ERROR: start it with start-agent.sh, then retry." >&2
else
    echo "ERROR: print failed (curl exit $STATUS):" >&2
    printf '%s\n' "$BODY" | tail -c 800 >&2
fi
exit 1
