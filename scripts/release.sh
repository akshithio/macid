#!/bin/bash
#   scripts/release.sh setup      once: create the update-signing key
#   scripts/release.sh 0.2.0      every release
# Needs a Developer ID Application certificate, the "macid-notary" notarytool profile and gh logged in.

set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=app/Resources/Info.plist
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
PROFILE=macid-notary
SITE=https://macid.akshith.io

die() { echo "release: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }

[ -x "$SPARKLE_BIN/generate_keys" ] || swift package resolve >/dev/null

if [ "${1:-}" = "setup" ]; then
    "$SPARKLE_BIN/generate_keys"
    KEY=$("$SPARKLE_BIN/generate_keys" -p)
    plist "Set :SUPublicEDKey $KEY"
    echo
    echo "Public key written to $PLIST."
    echo "Back up the private key somewhere safe. Lose it and installed copies"
    echo "can never be updated again:"
    echo "  $SPARKLE_BIN/generate_keys -x sparkle-private-key.txt"
    exit 0
fi

VERSION=${1:-}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh <version, e.g. 0.2.0> | setup"

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
[ -n "$IDENTITY" ] || die "no Developer ID Application certificate in your keychain. Create one at developer.apple.com > Certificates."

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "no notarytool profile '$PROFILE'. Run: xcrun notarytool store-credentials $PROFILE --apple-id <you> --team-id <TEAMID>"

gh auth status >/dev/null 2>&1 || die "gh isn't logged in. Run: gh auth login"
! gh release view "v$VERSION" >/dev/null 2>&1 || die "release v$VERSION already exists on GitHub"

case "$(plist 'Print :SUPublicEDKey')" in
    ""|REPLACE*) die "no update-signing key yet. Run: scripts/release.sh setup" ;;
esac

[ -z "$(git status --porcelain)" ] || echo "release: warning: the working tree has uncommitted changes" >&2

BUILD=$(( $(plist 'Print :CFBundleVersion') + 1 ))
plist "Set :CFBundleShortVersionString $VERSION"
plist "Set :CFBundleVersion $BUILD"
sed -i '' "s/^VERSION  := .*/VERSION  := $VERSION/" Makefile
echo "== MacID $VERSION (build $BUILD)"

make clean >/dev/null
make all SIGN_ID="$IDENTITY" CSFLAGS=--timestamp
codesign --verify --deep --strict build/MacID.app

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

ditto -c -k --keepParent build/MacID.app build/MacID-notarize.zip
notarize build/MacID-notarize.zip
xcrun stapler staple build/MacID.app
rm build/MacID-notarize.zip

mkdir -p web/public/updates
ditto -c -k --sequesterRsrc --keepParent build/MacID.app "web/public/updates/MacID-$VERSION.zip"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "$SITE/updates/" \
    -o web/public/appcast.xml \
    web/public/updates

rm -rf build/dmg build/MacID.dmg
mkdir -p build/dmg
cp -R build/MacID.app build/dmg/MacID.app
ln -s /Applications build/dmg/Applications
hdiutil create -volname MacID -srcfolder build/dmg -ov -quiet -format UDZO build/MacID.dmg
codesign --force --timestamp --sign "$IDENTITY" build/MacID.dmg
notarize build/MacID.dmg
xcrun stapler staple build/MacID.dmg

gh release create "v$VERSION" build/MacID.dmg --title "MacID $VERSION" --notes "MacID $VERSION"

echo
echo "MacID $VERSION is on GitHub Releases, where the site's download button serves it from."
echo "Commit web/public (appcast and update) and deploy the site so installed copies update."
