#!/usr/bin/env bash
# Auto-resize VM display when SPICE resolution changes
# Run this in background on VM startup
#
# The SPICE agent creates new preferred resolutions when the host window
# is resized, but doesn't auto-apply them. This script monitors for changes
# and applies the preferred resolution automatically.

LAST_RES=""
OUTPUT="Virtual-1"

echo "VM auto-resize monitor started"
echo "Monitoring $OUTPUT for resolution changes..."

while true; do
    # Get current preferred resolution (marked with +)
    PREFERRED=$(xrandr 2>/dev/null | grep -A1 "^$OUTPUT connected" | tail -1 | awk '{print $1}')

    # Get current active resolution (marked with *)
    CURRENT=$(xrandr 2>/dev/null | grep -E "^\s+[0-9]+x[0-9]+.*\*" | head -1 | awk '{print $1}')

    # If preferred exists and differs from current, apply it
    if [ -n "$PREFERRED" ] && [ "$PREFERRED" != "$CURRENT" ] && [ "$PREFERRED" != "$LAST_RES" ]; then
        echo "$(date '+%H:%M:%S') Resolution change: $CURRENT -> $PREFERRED"
        xrandr --output "$OUTPUT" --mode "$PREFERRED" 2>/dev/null || \
        xrandr --output "$OUTPUT" --auto 2>/dev/null || true
        LAST_RES="$PREFERRED"

        # Reload polybar to adjust to new resolution
        sleep 0.5
        pkill polybar 2>/dev/null || true
        sleep 0.2
        polybar main 2>/dev/null &
        disown
    fi

    sleep 0.5
done
