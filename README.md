# KakaoAdCover

맥용 카카오톡 메인 창 아래쪽 광고 자리에 배경색 판을 덮는 메뉴바 앱. 카카오톡 앱 파일은 건드리지 않는다.

## 사용 책임

- 카카오(Kakao Corp.)와 관계없는 개인 비공식 프로젝트다.
- 이 프로그램을 써서 생기는 모든 결과의 책임은 사용자 본인에게 있다. 카카오 이용약관 위반 여부 판단, 계정 제재, 데이터 손실, 오작동이 모두 여기에 든다.
- 비공개 macOS API(SkyLight)를 쓴다. macOS 나 카카오톡 업데이트로 동작이 바뀌거나 멈출 수 있다.
- 있는 그대로 제공하며 어떤 보증도 하지 않는다.

This is an unofficial personal project, not affiliated with Kakao Corp. Use it entirely at your own risk. It is provided as is, without warranty of any kind, and the author is not liable for any consequence of using it, including account restrictions under KakaoTalk's terms.

## 빌드와 실행

    ./build.sh
    open build/KakaoAdCover.app

처음 실행하면 두 권한이 필요하다.

- Accessibility(필수): 광고 자리 위치를 읽는다. 없으면 아무것도 안 한다.
- Screen & System Audio Recording(선택): 광고 바로 위 한 줄만 찍어 판 색을 배경에서 뽑는다. 없으면 짐작한 기본색으로 칠한다. 찍은 화면은 저장하지 않는다.

build.sh 는 Apple Development 인증서가 있으면 그것으로 서명해서, 다시 빌드해도 권한이 유지된다. 인증서가 없으면 임시 서명이라 다시 빌드할 때마다 권한을 새로 켜야 한다. 서명에는 Hardened Runtime 을 켠다.

## 창을 따라가는 방식

창 이동은 비공개 SkyLight API(창 서버 알림, JankyBorders 와 같은 방식)로 받아 판을 창 서버에 바로 옮긴다. 크기 변경은 창 서버 알림이 오지 않아, 끄는 동안 마우스 이벤트마다 창 서버에서 창 크기를 읽는다. SkyLight 함수를 못 찾으면 접근성 알림만으로 따라간다.

## 카카오톡이 업데이트돼 안 가려질 때

확인용 명령은 개발용 빌드에만 들어 있다. 배포용 빌드에 두면 다른 프로그램이 이 앱을 그 인자로 띄워, 이 앱이 받은 권한으로 카카오톡 화면과 창 내용을 가져갈 수 있어서다. 확인이 끝나면 개발용 빌드는 지운다.

    CONFIG=debug ./build.sh
    open -n -W build/debug/KakaoAdCover.app --args --dump ~/kakao-tree.txt
    rm -rf build/debug

`--dump` 는 창 구조(역할, 식별자, 위치)만 남기고 창 제목이나 글은 적지 않는다. 광고 자리는 `Main Window` 의 직속 AXGroup 중 창 아래쪽에 창 너비로 붙은 것이다(`findAd`).
`--shot <경로>.png` 는 메인 창과 판만 찍는다. 이 그림에는 대화 목록이 그대로 담기니 남에게 보낼 때 조심한다.
`--followtest <ms>` 는 카카오톡 창을 접근성 API 로 40번 옮기고 40번 줄이면서, 매번 <ms> 뒤 판이 제자리에 왔는지 센다. 끝나면 창을 되돌린다.
`--login-on` 은 로그인 시 실행을 켜고 끝난다(메뉴의 로그인 시 실행과 같다).
확인용 명령이 만드는 파일은 본인만 읽을 수 있게 쓴다.
