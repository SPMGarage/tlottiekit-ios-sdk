#!/usr/bin/env bash
# Publishes a TLottieKit release:
#
#   apple/release.sh 0.1.0
#
# Builds CTLottie.xcframework, points Package.swift at the release zip,
# commits, tags, pushes, and uploads the zip to GitHub Releases (needs gh).
set -euo pipefail

VERSION="${1:?usage: apple/release.sh <version>}"
REPO="${TLOTTIEKIT_REPO:-SPMGarage/tlottiekit-ios-sdk}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="apple/Artifacts/CTLottie.xcframework.zip"

cd "$ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
    echo "working tree is not clean" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    echo "tag $VERSION already exists" >&2
    exit 1
fi

./apple/build-xcframework.sh

CHECKSUM="$(swift package compute-checksum "$ZIP")"
URL="https://github.com/$REPO/releases/download/$VERSION/CTLottie.xcframework.zip"
sed -i '' -E \
    -e "s|^let releaseURL = \".*\"|let releaseURL = \"$URL\"|" \
    -e "s|^let releaseChecksum = \".*\"|let releaseChecksum = \"$CHECKSUM\"|" \
    Package.swift
grep -q "$CHECKSUM" Package.swift || { echo "Package.swift was not updated" >&2; exit 1; }

UPSTREAM="$(git log -1 --format=%h upstream/main 2>/dev/null || echo unknown)"
git add Package.swift
git commit -m "released $VERSION"
git tag "$VERSION"
git push origin HEAD "refs/tags/$VERSION"

gh release create "$VERSION" "$ZIP" \
    --repo "$REPO" \
    --title "TLottieKit $VERSION" \
    --notes "CTLottie.xcframework (iOS, iOS Simulator, macOS) built from tlottie at upstream $UPSTREAM.

SwiftPM checksum: \`$CHECKSUM\`"

echo "released $VERSION: $URL"
