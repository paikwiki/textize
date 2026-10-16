#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="build/Textize.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Textize" "$APP/Contents/MacOS/Textize"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# String Catalog(Sources/Textize/Resources/Localizable.xcstrings)이 컴파일된 언어별 .lproj를 앱 리소스로 옮긴다.
# Bundle.module 대신 Bundle.main에서 찾도록 번들을 풀어서 넣는다 (L10n.swift 참고).
BUNDLE=".build/$CONFIG/Textize_Textize.bundle"
if [ -d "$BUNDLE/Contents/Resources" ]; then
  cp -R "$BUNDLE/Contents/Resources/"*.lproj "$APP/Contents/Resources/"
else
  echo "warning: $BUNDLE 이 없어 UI가 영어로만 나옵니다." >&2
fi
# 아이콘(Resources/Textize.icns)은 MIT 라이선스 적용 대상이 아니다(README 참고). 없어도 기본 아이콘으로 빌드된다.
if [ -f Resources/Textize.icns ]; then cp Resources/Textize.icns "$APP/Contents/Resources/"; fi
echo -n "APPL????" > "$APP/Contents/PkgInfo"
# 로컬 개발용 인증서가 있으면 그걸로 서명한다 (재빌드해도 권한 유지). 없으면 ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-Textize Dev}"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: '$IDENTITY' 인증서가 없어 ad-hoc 서명합니다. scripts/make-dev-cert.sh 를 실행하면 권한이 유지됩니다." >&2
  codesign --force --sign - "$APP"
fi
echo "built: $APP"
