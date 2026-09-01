#!/bin/sh
# CUPS backend for the Anko Inkless A4 (MV-B530).
#
# Runs as _lp under cupsd, which can never hold a Bluetooth TCC grant, so this
# only spools the job. TiMiniRunner.app in the user session does the printing.

SPOOL=/usr/local/var/spool/timini
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

JOB_ID="$1"
OPTIONS="$5"
INPUT="$6"

if [ ! -d "$SPOOL" ]; then
    echo "ERROR: spool directory $SPOOL is missing" >&2
    exit 1
fi

ID="${JOB_ID}-$$-$(date +%s)"
DATA="$SPOOL/$ID.pdf"

if [ -n "$INPUT" ]; then
    cp "$INPUT" "$DATA" || { echo "ERROR: cannot stage $INPUT" >&2; exit 1; }
else
    cat > "$DATA" || { echo "ERROR: cannot stage job from stdin" >&2; exit 1; }
fi

if [ ! -s "$DATA" ]; then
    echo "ERROR: empty print job" >&2
    rm -f "$DATA"
    exit 1
fi

# Carry a darkness option through if the user set one.
DARK=$(printf '%s' "$OPTIONS" | sed -n 's/.*Darkness=\([1-5]\).*/\1/p')
printf '{"darkness": "%s"}\n' "${DARK:-3}" > "$SPOOL/$ID.opts"

chmod 664 "$DATA" "$SPOOL/$ID.opts" 2>/dev/null
: > "$SPOOL/$ID.ready"
chmod 664 "$SPOOL/$ID.ready" 2>/dev/null

echo "INFO: job queued, waiting for the print agent" >&2

i=0
while [ $i -lt $((TIMEOUT * 2)) ]; do
    if [ -f "$SPOOL/$ID.done" ]; then
        rm -f "$SPOOL/$ID.done"
        echo "INFO: printed" >&2
        exit 0
    fi
    if [ -f "$SPOOL/$ID.err" ]; then
        echo "ERROR: print agent reported a failure:" >&2
        tail -c 800 "$SPOOL/$ID.err" >&2
        rm -f "$SPOOL/$ID.err"
        exit 1
    fi
    sleep 0.5
    i=$((i + 1))
done

echo "ERROR: timed out after ${TIMEOUT}s. Is the printer on and the TiMini print agent running?" >&2
rm -f "$DATA" "$SPOOL/$ID.opts" "$SPOOL/$ID.ready"
exit 1
