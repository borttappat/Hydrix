#!/usr/bin/env bash
# Auto-resize VM display when SPICE resolution changes
# Run this in background on VM startup
#
# The SPICE agent creates new preferred resolutions when the host window
# is resized, but doesn't auto-apply them. This script monitors for changes
# and applies the preferred resolution automatically.

LOGFILE="/tmp/vm-auto-resize.log"
exec >> "$LOGFILE" 2>&1

LAST_RES=""
OUTPUT="Virtual-1"

# Detect if we're in a VM (hostname contains "vm" case-insensitive)
hostname=$(hostnamectl hostname 2>/dev/null || hostname)
if [[ $hostname =~ [vV][mM] ]]; then
    IS_VM=1
    BAR_TOP="vm-top"
    BAR_BOTTOM="vm-bottom"
else
    IS_VM=0
    BAR_TOP="top"
    BAR_BOTTOM="main"
fi

echo "$(date '+%H:%M:%S') VM auto-resize monitor started (IS_VM=$IS_VM)"
echo "$(date '+%H:%M:%S') Monitoring $OUTPUT for resolution changes..."
echo "$(date '+%H:%M:%S') Using polybar bars: $BAR_TOP, $BAR_BOTTOM"

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
        polybar "$BAR_TOP" 2>/dev/null &
        polybar "$BAR_BOTTOM" 2>/dev/null &
        disown
        echo "$(date '+%H:%M:%S') Restarted polybar ($BAR_TOP + $BAR_BOTTOM)"
    fi

    sleep 0.5
done
