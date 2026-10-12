#!/usr/bin/env bash
# Builds a release Dbee.app in build/ and signs it.
#
#   scripts/build-app.sh
#
# Environment:
#   ARCHS          universal (default; falls back to arm64 if the universal build fails) or arm64
#   SIGN_IDENTITY  codesign identity; defaults to "-" (ad-hoc). Use a "Developer ID Application: …"
#                  identity for distribution; a secure timestamp is added for real identities.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Dbee"
APP="$ROOT/build/$APP_NAME.app"
ARCHS="${ARCHS:-universal}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

log() { printf '==> %s\n' "$*" >&2; }

case "$ARCHS" in
  universal) arch_flags=(--arch arm64 --arch x86_64) ;;
  arm64) arch_flags=(--arch arm64) ;;
  *) echo "ARCHS must be 'universal' or 'arm64' (got '$ARCHS')" >&2; exit 64 ;;
esac

# Keep the builder's home directory out of the binary (#file / __FILE__ strings in assertions).
remap_flags=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT=/dbee" -Xcc "-ffile-prefix-map=$ROOT=/dbee")

log "Building $APP_NAME (release, ${arch_flags[*]})"
if ! swift build -c release "${arch_flags[@]}" "${remap_flags[@]}"; then
  if [[ "$ARCHS" == "universal" ]]; then
    log "Universal build failed; retrying for arm64 only"
    arch_flags=(--arch arm64)
    swift build -c release "${arch_flags[@]}" "${remap_flags[@]}"
  else
    exit 1
  fi
fi

BIN_DIR="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"
[[ -x "$EXECUTABLE" ]] || { echo "Built executable not found at $EXECUTABLE" >&2; exit 1; }

log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"
# Drop local symbols (about half the binary size); the signature is re-applied below.
strip -x -no_code_signature_warning "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM resource bundles (none today, but dependencies may add some).
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  log "Copying $(basename "$bundle")"
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

plutil -lint -s "$APP/Contents/Info.plist"

log "Signing (identity: $SIGN_IDENTITY, hardened runtime)"
xattr -cr "$APP"
sign_flags=(--force --deep --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  sign_flags+=(--timestamp)
fi
codesign "${sign_flags[@]}" "$APP"
codesign --verify --strict --deep "$APP"

log "Architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
echo "$APP"
