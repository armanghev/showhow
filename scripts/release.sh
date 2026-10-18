#!/bin/bash
# Builds a signed, notarized DMG of Mac Helper.
#
# Needs: a Developer ID Application certificate in your keychain, your team id
# in Config/Signing.local.xcconfig, and a notarytool profile:
#   xcrun notarytool store-credentials machelper-notary --apple-id you@example.com --team-id ABCDE12345
#
# Usage: scripts/release.sh [notary-profile]
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-machelper-notary}"
ARCHIVE="dist/MacHelper.xcarchive"
EXPORT="dist/export"
APP="$EXPORT/Mac Helper.app"
VERSION=$(grep -E '^MARKETING_VERSION' Config/Base.xcconfig | awk '{print $3}')
DMG="dist/MacHelper-$VERSION.dmg"

rm -rf dist && mkdir -p dist

command -v xcodegen >/dev/null && xcodegen generate

xcodebuild -project MacHelper.xcodeproj -scheme MacHelper -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual archive

cat > dist/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist dist/ExportOptions.plist

codesign --verify --deep --strict --verbose=2 "$APP"

hdiutil create -volname "Mac Helper" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "Done: $DMG"
