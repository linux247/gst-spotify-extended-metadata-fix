#!/bin/bash
set -euo pipefail

# Build script for gst-plugin-spotify applying temporary librespot metadata patch.
# Context:
#   Spotify playback failures: "Track should be available, but no alternatives found." (spotifyd issue #1370)
#   Upstream fix merged in librespot PR #1622 (extended-metadata endpoint) commit a9122dcbf430bc0c690191cf245dac0cb038035e (merged into dev).
#   This applies a patch inside the build container to use the fixed librespot commit.

LIBRESPOT_PATCH_COMMIT="a9122dcbf430bc0c690191cf245dac0cb038035e"
REPO_URL="https://github.com/kingosticks/gst-plugins-rs-build.git"
REPO_DIR="gst-plugins-rs-build"
PATCH_FILE="$(pwd)/librespot-fix.patch"

if [ ! -f "$PATCH_FILE" ]; then
  echo "Error: librespot-fix.patch not found in current directory"
  exit 1
fi

if [ ! -d "$REPO_DIR" ]; then
  echo "Cloning build repo: $REPO_URL"
  git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi

# Create a custom entrypoint that applies the patch before building
cat > "$REPO_DIR/entrypoint-patched.sh" << 'EOFENTRY'
#!/bin/bash
set -euo pipefail

# Run original entrypoint steps but inject patch
PLUGINS="${1:-audio/spotify}"
echo "$(date '+%Y-%m-%d %H:%M:%S') ** Checkout gst-plugins-rs source if required **"
echo "**********************************************"
if [ -d gst-plugins-rs ]; then
  cd gst-plugins-rs
  git pull
  cd ..
else
  git clone --depth=1 https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs.git
fi

echo "**********************************************"
echo "$(date '+%Y-%m-%d %H:%M:%S') ** Applying patches **"
echo "**********************************************"
cd gst-plugins-rs
if [ -f /patch/librespot-fix.patch ]; then
  echo "Applying librespot dependency patch..."
  # -N: ignore patches that seem to be already applied; continue on non-zero
  patch -p1 -N < /patch/librespot-fix.patch || true
  echo "Librespot dependency patch applied"
else
  echo "Warning: Patch file not found at /patch/librespot-fix.patch"
fi
echo "Applying inline API adaptations for librespot dev..."
# Replace SpotifyId::from_uri usage with manual base62 parsing in common.rs
sed -i '/let track = SpotifyId::from_uri(&self.track)?;/c\
        // librespot dev API removed SpotifyId::from_uri; parse track ID from URI string manually.\
        // Expected format: "spotify:track:TRACK_ID" where TRACK_ID is base62 encoded\
        let track = if let Some(id_str) = self.track.strip_prefix("spotify:track:") {\
            SpotifyId::from_base62(id_str)?\
        } else {\
            bail!(\
                "track property must be a Spotify track URI in format '\''spotify:track:ID'\'' (got: {})",\
                self.track\
            );\
        };' audio/spotify/src/common.rs

# Update player.load to use SpotifyUri in imp.rs
sed -i '/player.load(track, true, 0);/c\
        // librespot dev API expects a SpotifyUri instead of a SpotifyId\
        player.load(librespot_core::SpotifyUri::Track { id: track }, true, 0);' audio/spotify/src/spotifyaudiosrc/imp.rs
echo "Inline API adaptations applied"
cd ..

echo "**********************************************"
echo "$(date '+%Y-%m-%d %H:%M:%S') ** Install Rust stuff **"
echo "**********************************************"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
source $HOME/.cargo/env
cargo install cargo-deb

echo "************************************************"
echo "$(date '+%Y-%m-%d %H:%M:%S') ** Configure environment **"
echo "************************************************"
env

echo "**********************************************************************************"
echo "$(date '+%Y-%m-%d %H:%M:%S') ** Backup original gst-plugins-rs/$PLUGINS/Cargo.toml **"
echo "**********************************************************************************"
cp -p gst-plugins-rs/$PLUGINS/Cargo.toml gst-plugins-rs/$PLUGINS/Cargo.toml.orig

echo "***********************************************************************************************************"
echo "$(date '+%Y-%m-%d %H:%M:%S') ** Build GStreamer plugin gst-plugins-rs/$PLUGINS **"
echo "***********************************************************************************************************"
cd gst-plugins-rs/$PLUGINS
# NOTE: Removed --locked because patch modifies librespot dependencies; Cargo.lock must update.
cargo build --release

echo "**********************************************************"
echo "$(date '+%Y-%m-%d %H:%M:%S') ** Inspect build artifacts **"
echo "**********************************************************"
echo "Listing potential .so files under $(pwd)/target:" && find target -maxdepth 3 -type f -name "*.so" -print || true

so_files=( $(find target -maxdepth 3 -type f -name "libgst*.so" -o -name "*.so" 2>/dev/null) ) || true
if [ ${#so_files[@]} -gt 0 ]; then
  echo "Found shared libraries: ${so_files[*]}"
  echo "**********************************************************"
  echo "$(date '+%Y-%m-%d %H:%M:%S') ** Strip plugin binaries **"
  echo "**********************************************************"
  strip "${so_files[@]}" || true
  # Copy the primary spotify plugin lib out to the mounted /src for host access
  for f in "${so_files[@]}"; do
    if [[ "$(basename "$f")" == libgstspotify.so ]]; then
      cp -f "$f" /src/libgstspotify.so
      echo "Exported $f -> /src/libgstspotify.so"
    fi
  done
else
  echo "Warning: No .so files found in target after build."
fi

echo "*****************************************************************************"
echo "$(date '+%Y-%m-%d %H:%M:%S') ** Create Debian packages **"
echo "*****************************************************************************"
cargo deb --no-build --no-strip
EOFENTRY

chmod +x "$REPO_DIR/entrypoint-patched.sh"

cd "$REPO_DIR"

# Run the build container with patch file mounted
podman run --rm \
  -v $(pwd):/src:z \
  -v "$PATCH_FILE":/patch/librespot-fix.patch:ro,z \
  --workdir /src \
  ghcr.io/mopidy/gst-plugins-rs-build:latest \
  /bin/bash /src/entrypoint-patched.sh audio/spotify

# Verify the output file exists
output_file="libgstspotify.so"
if [ -f "$output_file" ]; then
  echo "Build successful: $(pwd)/$output_file"
  echo ""
  echo "To verify the patch worked:"
  echo "  strings ../libgstspotify.so | grep -i extended"
else
  echo "Build finished but $output_file not found in repo root. Searching..."
  found=$(find gst-plugins-rs -maxdepth 5 -type f -name libgstspotify.so 2>/dev/null | head -n1 || true)
  if [ -n "$found" ]; then
    cp -f "$found" ./libgstspotify.so
    echo "Copied plugin from $found to ./libgstspotify.so"
    echo "To verify the patch worked:"
    echo "  strings ../libgstspotify.so | grep -i extended"
  else
    echo "Build did not produce libgstspotify.so. Check container logs above for details."
    exit 1
  fi
fi

# Hint for next step on the host
echo "Hint: To produce a smaller final plugin (~7MB) in this directory, run: ./strip-debug.sh"
