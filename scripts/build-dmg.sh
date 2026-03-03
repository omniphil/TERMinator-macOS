#!/usr/bin/env bash
#
# build-dmg.sh — Build, sign, notarize, and package TERMinator as a DMG
#
# Usage:
#   ./scripts/build-dmg.sh                  # Full pipeline (build + notarize + DMG)
#   ./scripts/build-dmg.sh --skip-notarize  # Skip notarization (local testing)
#
# Environment variables (prompted if not set):
#   APPLE_ID   — Apple ID email for notarization
#   TEAM_ID    — Apple Developer Team ID
#   APP_PASSWORD — App-specific password (or use @keychain:notarytool-password)
#

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

SCHEME="TERMinator"
APP_NAME="TERMinator"
BUNDLE_ID="com.terminator.macos"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODEPROJ="${PROJECT_DIR}/TERMinator.xcodeproj"
EXPORT_OPTIONS_TEMPLATE="${PROJECT_DIR}/scripts/ExportOptions.plist"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"

SKIP_NOTARIZE=false

# ── Parse arguments ───────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=true ;;
        --help|-h)
            sed -n '3,12p' "$0"
            exit 0
            ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

info()  { printf "\033[1;34m==> %s\033[0m\n" "$*"; }
ok()    { printf "\033[1;32m==> %s\033[0m\n" "$*"; }
err()   { printf "\033[1;31mError: %s\033[0m\n" "$*" >&2; exit 1; }

STAGING_DIR=""
cleanup() {
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        rm -rf "$STAGING_DIR"
    fi
}
trap cleanup EXIT

# ── Detect signing identity ──────────────────────────────────────────────────

info "Detecting Developer ID signing identity..."
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(Developer ID Application: .+)"$/\1/' || true)

if [[ -z "$SIGNING_IDENTITY" ]]; then
    err "No 'Developer ID Application' certificate found in keychain.
    Install your Developer ID certificate from https://developer.apple.com/account/resources/certificates"
fi
ok "Signing identity: ${SIGNING_IDENTITY}"

# ── Collect credentials ──────────────────────────────────────────────────────

if [[ "$SKIP_NOTARIZE" == false ]]; then
    if [[ -z "${APPLE_ID:-}" ]]; then
        printf "Apple ID (email): "
        read -r APPLE_ID
    fi
    if [[ -z "${TEAM_ID:-}" ]]; then
        printf "Team ID: "
        read -r TEAM_ID
    fi
    if [[ -z "${APP_PASSWORD:-}" ]]; then
        # Check if stored in keychain
        if xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --keychain-profile "notarytool-password" >/dev/null 2>&1; then
            APP_PASSWORD="@keychain:notarytool-password"
            info "Using keychain profile 'notarytool-password'"
        else
            printf "App-specific password (or store with: xcrun notarytool store-credentials): "
            read -rs APP_PASSWORD
            echo
        fi
    fi
else
    # Still need TEAM_ID for ExportOptions.plist
    if [[ -z "${TEAM_ID:-}" ]]; then
        # Extract from the signing identity
        TEAM_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*\(([A-Z0-9]+)\)"$/\1/' || true)
        if [[ -z "$TEAM_ID" ]]; then
            printf "Team ID: "
            read -r TEAM_ID
        fi
        info "Using Team ID from certificate: ${TEAM_ID}"
    fi
fi

# ── Prepare ExportOptions.plist ──────────────────────────────────────────────

STAGING_DIR=$(mktemp -d)
EXPORT_OPTIONS="${STAGING_DIR}/ExportOptions.plist"
sed "s/\${TEAM_ID}/${TEAM_ID}/g" "$EXPORT_OPTIONS_TEMPLATE" > "$EXPORT_OPTIONS"

# ── Step 1: Archive ──────────────────────────────────────────────────────────

info "Building Release archive..."
mkdir -p "$BUILD_DIR"

HOME_DIR=$(echo ~)
xcodebuild archive \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ONLY_ACTIVE_ARCH=NO \
    OTHER_SWIFT_FLAGS="-file-prefix-map ${HOME_DIR}/=./" \
    OTHER_CFLAGS="-ffile-prefix-map=${HOME_DIR}/=./" \
    | tail -5

if [[ ! -d "$ARCHIVE_PATH" ]]; then
    err "Archive failed — ${ARCHIVE_PATH} not found"
fi
ok "Archive created: ${ARCHIVE_PATH}"

# ── Step 2: Export signed app ────────────────────────────────────────────────

EXPORT_DIR="${BUILD_DIR}/export"
rm -rf "$EXPORT_DIR"

info "Exporting signed app bundle..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR" \
    | tail -5

APP_BUNDLE="${EXPORT_DIR}/${APP_NAME}.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
    err "Export failed — ${APP_BUNDLE} not found"
fi
ok "Exported: ${APP_BUNDLE}"

# Verify code signature
info "Verifying code signature..."
codesign --verify --deep --strict "$APP_BUNDLE"
ok "Code signature valid"

# ── Step 3: Notarize the app ────────────────────────────────────────────────

if [[ "$SKIP_NOTARIZE" == false ]]; then
    info "Creating ZIP for notarization..."
    NOTARIZE_ZIP="${STAGING_DIR}/${APP_NAME}.zip"
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"

    info "Submitting to Apple notary service (this may take several minutes)..."
    NOTARY_ARGS=(
        --apple-id "$APPLE_ID"
        --team-id "$TEAM_ID"
        --wait
    )
    if [[ "$APP_PASSWORD" == "@keychain:"* ]]; then
        PROFILE_NAME="${APP_PASSWORD#@keychain:}"
        NOTARY_ARGS=(--keychain-profile "$PROFILE_NAME" --wait)
    else
        NOTARY_ARGS+=(--password "$APP_PASSWORD")
    fi

    NOTARY_OUTPUT=$(xcrun notarytool submit "$NOTARIZE_ZIP" "${NOTARY_ARGS[@]}" 2>&1) || {
        echo "$NOTARY_OUTPUT"
        # Try to extract the submission ID and show the log
        SUB_ID=$(echo "$NOTARY_OUTPUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)
        if [[ -n "$SUB_ID" ]]; then
            echo "--- Notarization log ---"
            xcrun notarytool log "$SUB_ID" "${NOTARY_ARGS[@]}" 2>&1 || true
        fi
        err "Notarization failed"
    }
    echo "$NOTARY_OUTPUT"

    if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
        ok "Notarization accepted"
    else
        err "Notarization was not accepted. Check output above."
    fi

    # ── Step 4: Staple ───────────────────────────────────────────────────────
    info "Stapling notarization ticket to app..."
    xcrun stapler staple "$APP_BUNDLE"
    ok "Stapled"
else
    info "Skipping notarization (--skip-notarize)"
fi

# ── Step 5: Read version and create DMG ──────────────────────────────────────

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_BUNDLE}/Contents/Info.plist")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
DMG_STAGING="${STAGING_DIR}/dmg-contents"

info "Creating DMG (v${VERSION})..."

mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Set volume icon if available
DMG_ICON="${PROJECT_DIR}/scripts/dmg-icon.icns"

# Remove any previous DMG
rm -f "$DMG_PATH"

if [[ -f "$DMG_ICON" ]]; then
    # Create writable DMG first so we can apply the volume icon
    DMG_RW="${STAGING_DIR}/${APP_NAME}-rw.dmg"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$DMG_STAGING" \
        -ov \
        -format UDRW \
        "$DMG_RW"

    info "Applying volume icon..."
    DMG_MOUNT=$(hdiutil attach "$DMG_RW" -noverify -noautoopen | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/')
    cp "$DMG_ICON" "${DMG_MOUNT}/.VolumeIcon.icns"
    SetFile -a C "${DMG_MOUNT}"
    hdiutil detach "$DMG_MOUNT" -quiet
    ok "Volume icon applied"

    # Convert to compressed read-only
    hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
    rm -f "$DMG_RW"
else
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$DMG_STAGING" \
        -ov \
        -format UDZO \
        -imagekey zlib-level=9 \
        "$DMG_PATH"
fi

ok "DMG created: ${DMG_PATH}"

# ── Step 6: Sign and notarize the DMG ────────────────────────────────────────

info "Signing DMG..."
codesign --force --sign "$SIGNING_IDENTITY" "$DMG_PATH"
codesign --verify "$DMG_PATH"
ok "DMG signed"

if [[ "$SKIP_NOTARIZE" == false ]]; then
    info "Notarizing DMG..."
    NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" 2>&1) || {
        echo "$NOTARY_OUTPUT"
        err "DMG notarization failed"
    }
    echo "$NOTARY_OUTPUT"

    if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
        ok "DMG notarization accepted"
    else
        err "DMG notarization was not accepted. Check output above."
    fi

    info "Stapling DMG..."
    xcrun stapler staple "$DMG_PATH"
    ok "DMG stapled"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
ok "Build complete!"
echo "  DMG: ${DMG_PATH}"
echo "  Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""

if [[ "$SKIP_NOTARIZE" == false ]]; then
    info "Verify with:"
    echo "  spctl --assess --type open --context context:primary-signature \"${DMG_PATH}\""
else
    info "Note: DMG is not notarized. For distribution, run without --skip-notarize"
fi
