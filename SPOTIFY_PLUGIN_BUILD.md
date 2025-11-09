# GStreamer Spotify Plugin - Extended Metadata Patch

## Overview
This build applies the librespot extended-metadata endpoint fix (PR #1622, commit `a9122dcbf430bc0c690191cf245dac0cb038035e`) to resolve Spotify playback errors:
- **Error Fixed**: "Track should be available, but no alternatives found."
- **Root Cause**: Spotify deprecated the `/metadata/4/` endpoint; new endpoint is `/extended-metadata/v0/extended-metadata`

## Build Process

### Prerequisites
- Podman or Docker
- Linux x86_64 host (for native build)

### Build Commands
```bash
# 1) Build inside container (produces unstripped .so in gst-plugins-rs-build/)
./build-spotify-plugin-v2.sh

# 2) On the host, copy and strip to ./libgstspotify.so (~7MB)
./strip-debug.sh
```

The build script:
1. Clones gst-plugins-rs from upstream
2. Applies `librespot-fix.patch` to update Cargo.toml dependencies to librespot dev branch
3. Applies inline API adaptations:
   - `common.rs`: Replaces removed `SpotifyId::from_uri()` with `SpotifyId::from_base62()`
   - `imp.rs`: Wraps `SpotifyId` as `SpotifyUri::Track` for `player.load()` call
4. Builds release binary with Rust toolchain
5. Exports `libgstspotify.so` to `gst-plugins-rs-build/` (unstripped, ~180MB)

Then run `strip-debug.sh` to:
1. Copy `gst-plugins-rs-build/libgstspotify.so` to `./libgstspotify.so`
2. Strip debug symbols to reduce file size to ~7MB

### Build Output
- **Plugin (unstripped)**: `gst-plugins-rs-build/libgstspotify.so` (~180MB)
- **Plugin (stripped, final)**: `./libgstspotify.so` (~7MB)
- **Debian Package**: `gst-plugins-rs-build/gst-plugins-rs/target/debian/gst-plugin-spotify_*.deb`
- **Build Logs**: Container stdout (visible during build)

## Verification

### 1. Check Plugin Version
```bash
gst-inspect-1.0 spotify
```
**Expected Output**:
- Version: `0.15.0-alpha.1-XXXXXXX+` (commit hash appended)
- Filename: `/usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstspotify.so`
- Elements: `spotifyaudiosrc`, `spotifylyricssrc`

### 2. Verify Extended Metadata Endpoint
```bash
strings ./libgstspotify.so | grep '/extended-metadata/v0/extended-metadata'
```
**Expected Output**: `/extended-metadata/v0/extended-metadata`

### 3. Verify Librespot Commit Hash
```bash
strings ./libgstspotify.so | grep 'a9122dc'
```
**Expected Output**: `a9122dclibrespot--0.7.1` (or similar string containing commit hash)

**Note**: After installing to `/usr/lib/x86_64-linux-gnu/gstreamer-1.0/`, use that path for verification.

### 4. Test Playback (Inside Mopidy Container)
```bash
# Start Mopidy (replace with your credentials)
export SPOTIFY_CLIENT_ID="your_client_id"
export SPOTIFY_CLIENT_SECRET="your_client_secret"
export SPOTIFY_USERNAME="your_username"
export SPOTIFY_PASSWORD="your_password"

mopidy -o spotify/client_id=$SPOTIFY_CLIENT_ID \
       -o spotify/client_secret=$SPOTIFY_CLIENT_SECRET \
       -o spotify/username=$SPOTIFY_USERNAME \
       -o spotify/password=$SPOTIFY_PASSWORD &

sleep 8

# Add and play a test track
curl -s localhost:6680/mopidy/rpc -d '{
  "jsonrpc":"2.0",
  "id":1,
  "method":"core.tracklist.add",
  "params":{"uris":["spotify:track:3n3Ppam7vgaVa1iaRUc9Lp"]}
}'

curl -s localhost:6680/mopidy/rpc -d '{
  "jsonrpc":"2.0",
  "id":2,
  "method":"core.playback.play"
}'
```

**Check Logs**:
```bash
# Look for successful playback, no "Track should be available" errors
journalctl -u mopidy -f
# or
docker logs -f <mopidy_container>
```

### 5. GStreamer Plugin Cache Refresh (If Needed)
If the plugin doesn't load after copying:
```bash
rm -f ~/.cache/gstreamer-1.0/registry.* 2>/dev/null || true
gst-inspect-1.0 spotify
```

## Files Modified

### Build Script
- **File**: `build-spotify-plugin-v2.sh`
- **Changes**:
  - Mounts `librespot-fix.patch` into container
  - Applies inline sed edits for API compatibility
  - Removed `--locked` flag from cargo build
  - Exports .so from container to host

### Patches Applied
1. **librespot-fix.patch**: Updates Cargo.toml to use librespot git commit `a9122dcbf430bc0c690191cf245dac0cb038035e`
2. **Inline API fixes**:
   - `audio/spotify/src/common.rs` line ~166: `SpotifyId::from_uri()` → `SpotifyId::from_base62()`
   - `audio/spotify/src/spotifyaudiosrc/imp.rs` line ~415: `player.load(track, ...)` → `player.load(SpotifyUri::Track { id: track }, ...)`

### Dockerfile
- **File**: `Dockerfile`
- **Line 72**: `COPY libgstspotify.so /usr/lib/x86_64-linux-gnu/gstreamer-1.0/`
- **Removed**: Old wget + dpkg install of pre-built .deb (outdated version without fix)

## Troubleshooting

### Build Fails with "patch already applied"
The script is idempotent. If you rerun without cleaning, it detects already-patched Cargo.toml and continues (uses `-N` flag).

### Build Fails with Compilation Errors
Check:
- Internet connectivity (cargo needs crates.io and GitHub)
- Disk space (Rust builds are large)
- Podman/Docker is running and has sufficient resources

### Plugin Not Detected After Container Rebuild
1. Ensure `libgstspotify.so` exists in workspace root before `docker build`
2. Clear GStreamer cache inside container: `rm ~/.cache/gstreamer-1.0/registry.*`
3. Check file permissions: plugin must be readable by `mopidy` user

### Playback Still Fails
1. Verify credentials are correct
2. Check Spotify account type (Premium required for streaming)
3. Inspect Mopidy logs for other errors (network, OAuth, etc.)
4. Confirm plugin is actually loaded: `gst-inspect-1.0 spotify` should show version with commit hash

## References
- **Original Issue**: https://github.com/Spotifyd/spotifyd/issues/1370
- **Librespot PR**: https://github.com/librespot-org/librespot/pull/1622
- **Commit with Fix**: https://github.com/librespot-org/librespot/commit/a9122dcbf430bc0c690191cf245dac0cb038035e
- **GStreamer Spotify Plugin**: https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs/-/tree/main/audio/spotify

## Build Environment
- **Base Image**: `ghcr.io/mopidy/gst-plugins-rs-build:latest`
- **Rust Version**: 1.91.0 (as of Nov 2025)
- **GStreamer Version**: 1.24.2 (in final container)
- **Target**: `x86_64-unknown-linux-gnu` (native build, not cross-compile)

## Maintenance Notes
- This patch may become obsolete when:
  1. gst-plugins-rs updates to a newer librespot version (> 0.7)
  2. Official releases include the extended-metadata endpoint
- To update to future librespot commits, edit `librespot-fix.patch` and change the `rev=` parameter
- API changes in future librespot versions may require adjusting the inline sed commands in `build-spotify-plugin-v2.sh`
