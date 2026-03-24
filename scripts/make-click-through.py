#!/usr/bin/env python3
"""Make an X11 window click-through by setting an empty input shape.

Uses the X SHAPE extension to set the input region to empty,
making all input events pass through to windows below.
"""

import sys

try:
    from Xlib import X, display
    from Xlib.ext import shape
except ImportError:
    print("Error: python-xlib not installed. Install with: nix-shell -p python3Packages.xlib")
    sys.exit(1)

def make_click_through(window_id):
    """Set empty input shape on a window."""
    try:
        d = display.Display()

        # Convert window ID (might be hex string or int)
        if isinstance(window_id, str):
            if window_id.startswith('0x'):
                wid = int(window_id, 16)
            else:
                wid = int(window_id)
        else:
            wid = window_id

        window = d.create_resource_object('window', wid)

        # Check if SHAPE extension is available
        if not d.has_extension('SHAPE'):
            print("Error: X SHAPE extension not available")
            return False

        # Set input shape to empty rectangle (0x0 at 0,0)
        # This makes the window not receive any input events
        # shape_kind: shape.SO_Input (input shape)
        # shape_op: shape.SO_Set (set/replace the shape)
        window.shape_rectangles(
            shape.SO_Set,      # operation: set
            shape.SK_Input,    # kind: input shape
            X.YXBanded,        # ordering
            0, 0,              # offset
            []                 # empty list = no input region
        )

        d.sync()
        print(f"Window {hex(wid)} is now click-through")
        return True

    except Exception as e:
        print(f"Error: {e}")
        return False

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: make-click-through.py <window_id>")
        print("  window_id can be decimal or hex (0x...)")
        sys.exit(1)

    window_id = sys.argv[1]
    if make_click_through(window_id):
        sys.exit(0)
    else:
        sys.exit(1)
