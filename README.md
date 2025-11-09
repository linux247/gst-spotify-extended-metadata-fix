# GStreamer Spotify Plugin – Extended Metadata Fix (Temporary Build)

This repo provides a reproducible build to produce a working `libgstspotify.so` that uses librespot's extended-metadata endpoint, fixing Spotify playback errors in Mopidy and other GStreamer-based applications.

## Problem Solved

Symptoms (one or more of):
- **Mopidy logs**: `GStreamer error: Resource not found.` when trying to play Spotify tracks
- **Spotifyd/librespot**: `Track should be available, but no alternatives found`

**Root cause**: Spotify deprecated the `/metadata/4/` endpoint. Older librespot versions (< 0.5) fail to fetch track metadata.

**Fix**: librespot PR #1622 (commit `a9122dcbf430bc0c690191cf245dac0cb038035e`) implements the new `/extended-metadata/v0/extended-metadata` endpoint. This build applies that fix to `libgstspotify.so`.

## Source Repos

- Build harness: https://github.com/kingosticks/gst-plugins-rs-build
- GStreamer plugins: https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs/
- Librespot: https://github.com/librespot-org/librespot

## Requirements

- Linux x86_64 host
- Podman or Docker
- Internet access (to fetch sources and crates)

Optional (for verification):
- `gst-inspect-1.0`, `strings`

## Quick Start

```bash
# 1) Build inside a container (produces unstripped artifact in subfolder)
./build-spotify-plugin-v2.sh

# 2) Copy to current dir and strip debug symbols (~7MB final)
./strip-debug.sh
```

### Outputs

- Unstripped: `gst-plugins-rs-build/libgstspotify.so` (~180MB, contains debug info)
- Final: `./libgstspotify.so` (~7MB, stripped)

## Verify the Fix

```bash
# Extended metadata endpoint present
strings ./libgstspotify.so | grep '/extended-metadata/v0/extended-metadata'

# Librespot commit reference present
strings ./libgstspotify.so | grep 'a9122dc'
```

## Install (optional)

If you want to install the plugin system-wide (example path for Debian/Ubuntu):

```bash
sudo install -m 0755 ./libgstspotify.so /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstspotify.so
# Refresh GStreamer plugin cache if needed
rm -f ~/.cache/gstreamer-1.0/registry.* 2>/dev/null || true

# Confirm it's detected
gst-inspect-1.0 spotify
```

## Troubleshooting

- Large file (~180MB)?
  - Run `./strip-debug.sh` to strip debug symbols and copy to `./libgstspotify.so` (~7MB).
- "patch already applied" during build?
  - The build is idempotent; patching will be skipped safely and the build will continue.
- No `.so` found?
  - Check container logs above for errors. Ensure Podman/Docker is running and you have network access.
- Permission denied when installing system-wide?
  - Use `sudo install` as shown above.

## Details

For a deeper walkthrough (what's patched and how it builds), see `SPOTIFY_PLUGIN_BUILD.md` in this repo.

- The build pins librespot to commit `a9122dc...` and applies small API adjustments to gst-plugins-rs' Spotify plugin sources to match current librespot dev API.
- We build in release mode and strip on the host to keep final size small.

## Maintenance Notes

- This repo is a temporary workaround. Once gst-plugins-rs integrates a librespot release that includes the extended-metadata support, this project may be archived.
- To update to a newer librespot commit, edit `librespot-fix.patch` and change the `rev =` values.

## Credits

- Build harness: `kingosticks/gst-plugins-rs-build`
- GStreamer Rust plugins: `gst-plugins-rs`
- Librespot maintainers for the extended-metadata work
