#!/bin/zsh
# 빌드하고 .app 으로 묶어 개발 인증서로 서명한다. 서명이 같으면 접근성 권한이 재빌드 뒤에도 유지된다.
# 인증서가 없으면 임시(ad-hoc) 서명이라, 다시 빌드할 때마다 권한을 새로 켜야 한다.
# CONFIG=debug ./build.sh 는 확인용 명령(--dump 등)이 든 개발용 빌드를 build/debug 에 만든다.
set -e
cd "${0:A:h}"
CONFIG=${CONFIG:-release}
swift build -c $CONFIG
APP=build/KakaoAdCover.app
[[ $CONFIG == debug ]] && APP=build/debug/KakaoAdCover.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cp .build/$CONFIG/KakaoAdCover $APP/Contents/MacOS/
cp Info.plist $APP/Contents/
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
# Hardened Runtime: 다른 프로그램이 DYLD 환경 변수 등으로 이 앱에 코드를 끼워 넣지 못하게 한다
codesign --force --options runtime --sign "${IDENTITY:--}" $APP
echo "built $APP"
