#!/bin/bash
set -euo pipefail

# Copy and strip the built plugin from the build subfolder to the current directory.
# This is run on the HOST (not inside the container) to ensure the final .so is small (~7MB).

SRC="gst-plugins-rs-build/libgstspotify.so"
DST="./libgstspotify.so"

if [ ! -f "$SRC" ]; then
	echo "Error: $SRC not found. Did you run ./build-spotify-plugin-v2.sh yet?" >&2
	exit 1
fi

if ! command -v strip >/dev/null 2>&1; then
	echo "Error: 'strip' command not found. Install binutils (e.g., apt-get install binutils) and retry." >&2
	exit 1
fi

echo "Copying $SRC -> $DST"
cp -f "$SRC" "$DST"

echo "Before strip:"
ls -lh "$DST"

# Prefer --strip-unneeded to safely remove debug symbols while keeping needed symbols
strip --strip-unneeded "$DST" || strip "$DST"

echo "After strip:"
ls -lh "$DST"

echo "File info:"
file "$DST"

echo "Quick verification (extended metadata endpoint present):"
if strings "$DST" | grep -qi '/extended-metadata/v0/extended-metadata'; then
	echo "OK: extended metadata endpoint string found"
else
	echo "Warning: could not find extended metadata endpoint string in binary. This may still be fine." >&2
fi

echo "Done. Final plugin: $DST"
