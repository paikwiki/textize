#!/bin/zsh
# 배포용 DMG를 만든다: 릴리스 빌드 → Developer ID 서명 → 앱 공증·스테이플 → DMG → DMG 공증·스테이플.
# 결과물은 dist/Textize-<버전>.dmg 이며 GitHub Releases에 올린다.
#
# 사전 준비 (한 번만):
#   1. 키체인에 "Developer ID Application: …" 인증서 (Xcode > Settings > Accounts > Manage Certificates)
#   2. 공증 자격 증명을 키체인에 저장:
#        xcrun notarytool store-credentials textize-notary --apple-id <Apple ID> --team-id <팀 ID>
#      암호는 account.apple.com 에서 만든 앱 암호를 입력한다. 저장소에는 아무것도 적지 않는다.
#
# 환경 변수:
#   CODESIGN_IDENTITY  서명 인증서 이름. 기본값은 키체인의 첫 "Developer ID Application" 인증서.
#   NOTARY_PROFILE     store-credentials 로 저장한 프로필 이름. 기본값 textize-notary.
#   SKIP_NOTARIZE=1    공증 없이 서명과 DMG까지만 만든다 (로컬 확인용).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

NOTARY_PROFILE="${NOTARY_PROFILE:-textize-notary}"
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$IDENTITY" ]; then
  echo "error: Developer ID Application 인증서가 키체인에 없습니다." >&2; exit 1
fi

# 1. 빌드. build-app.sh 가 개발 인증서로 서명한 .app 을 만들면 아래에서 Developer ID 로 다시 서명한다.
./scripts/build-app.sh release
APP="build/Textize.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
DIST="dist"
DMG="$DIST/Textize-$VERSION.dmg"
mkdir -p "$DIST"
rm -f "$DMG"

# 2. Developer ID 서명. 공증에는 Hardened Runtime(--options runtime)과 보안 타임스탬프가 필수다.
#    Textize 는 시스템 오디오만 캡처하고 마이크는 쓰지 않으므로 별도 엔타이틀먼트가 필요 없다.
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "signed: $APP ($VERSION build $BUILD) as $IDENTITY"

# 3. 앱 공증과 스테이플. 앱에 티켓을 붙여 두면 DMG 에서 꺼낸 뒤 오프라인에서 처음 열어도 Gatekeeper 가 통과시킨다.
notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$2"
}
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  ZIP="$DIST/Textize-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP" "$APP"
  rm -f "$ZIP"
fi

# 4. DMG. 앱과 /Applications 바로가기만 넣은 읽기 전용 이미지. DMG 도 따로 서명하고 공증한다.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Textize" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "skipped notarization: $DMG"
  exit 0
fi
notarize "$DMG" "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "ready: $DMG"
