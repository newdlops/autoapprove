# 다른 네트워크에서 웹 접속

AutoApprove의 **연결 설정 → 다른 네트워크에서 접속**에서 켠다.
외부 접속은 기본적으로 꺼져 있다. 0.2.185부터 연결을 시작하면 필요한 연결 도구와
이 Mac의 웹 접속을 자동으로 준비한다.
기존 LAN의 연결 코드 없는 사용과 외부 접속의 인증은 별개다.

## 임시 주소

1. **Cloudflare 임시 주소**를 선택한다.
2. **임시 주소 만들기**를 누른다. 연결 도구가 없으면 공식 파일을 내려받아 검증하고
   관리자 권한 없이 앱 전용 폴더에 설치한다. 웹 접속도 함께 준비한다.
3. 공개 HTTPS 주소가 이 Mac에 연결되는지 확인한 뒤
   접속 링크·QR 코드가 표시된다. 본인 기기에서 링크 또는 QR로 연다.

준비 중에는 **취소**할 수 있다. 연결 도구는 기존 `cloudflared`를 자동으로 찾거나
‘연결 세부 설정’에서 선택할 수 있다. 임시 주소의 내부 포트는 자동 배정한다.

계정이나 도메인이 필요하지 않다. 다시 만들면 주소가 달라진다.
Cloudflare의 임시 터널은 가동 시간 보장과 SSE 지원이 없으므로, 이 모드에서는
원본 화면과 실제 PTY를 **순서대로 조회**한다. 입력은 같은 원본에 순서대로 전달하고,
원본 식별과 불확실한 쓰기의 재전송 금지는 유지한다. 고정 터널은 기존 실시간
비트 스트림을 사용한다. [Cloudflare 임시 터널 공식 설명](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/).

## 고정 도메인

1. 앱에서 **Cloudflare 고정 도메인 → Cloudflare 터널 열기**를 누른다.
   Cloudflare의 **Networking → Tunnels**에서 터널을 만들고 macOS 설치 명령을 복사한다.
2. 앱의 **설치 명령 또는 터널 토큰**에 복사한 명령 전체를 붙여넣는다. 앱은 명령을
   실행하지 않고 토큰만 추출한다. 이미 저장한 토큰을 쓰려면 비워 둘 수 있다.
3. 사용할 도메인(예: `terminal.example.com`)을 입력하고 **고정 도메인 연결**을 누른다.
   `https://`는 자동 보완한다. 필요한 도구 설치와 웹 접속을 준비한다.
4. Cloudflare에서 연결된 터널의 **Routes → Published application** 경로를 추가한다.
   같은 도메인과 앱의 **서비스 주소 복사**로 복사한 값을 지정한다. 기본은
   **`http://127.0.0.1:8766`** 이며 기존 LAN 페이지 포트와 다르다.
5. 앱이 **공개 경로 설정 필요** 상태면 **공개 주소 확인**을 누른다. 설정 중에도 연결
   도구는 유지된다. 주소 확인 후에만 접속 링크와 QR을 제공한다.

도메인·터널 생성에는 본인의 Cloudflare 계정이 필요하다. 계정의 토큰은 채팅이나
명령줄 인자에 붙이지 말고 앱의 가려진 입력란에 넣는다. 토큰은 이 Mac의 키체인에
저장하며 연결 시에만 권한 `0600`의 임시 파일로 읽힌다.
[Cloudflare 설정](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/),
[토큰 파일 지원](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/#token-file).

## 이미 실행하는 로컬 터널

**기존 로컬 터널 연결**을 선택한다. 사용하는 터널의 원본 주소를 위 서비스 URL로
지정하고 공개 HTTPS 주소를 입력한다. 이 모드에서는 터널 프로그램을 별도로
실행한다. 앱은 공개 주소가 자신의 인증 게이트웨이에 연결되는지 확인한다.
도메인만 입력할 수 있으며 서비스 주소를 버튼으로 복사할 수 있다.
중간 인증 페이지가 응답을 대체하는 제공자는 그 페이지의 설정을 먼저 확인해야 한다.

## 접속·종료

- 접속 링크와 QR에는 무작위 256비트 접속 키가 포함된다. 가진 사람은 연결된 Mac의
  관리 페이지와 터미널을 제어할 수 있으므로 본인 기기에만 공유한다.
- 키는 URL fragment에서 읽고 제거한다. 요청 URL·referrer·브라우저 저장소에 넣지
  않는다. 브라우저 인증은 Secure/HttpOnly/SameSite=Strict 쿠키로 최대 8시간 유지한다.
- 일반 주소만 열면 접속 키 입력 화면이 나온다. Mac 설정에서 키를 복사해 입력할 수 있다.
- **로그아웃**은 그 브라우저의 인증과 연결을 해제한다. 작성 중인 입력을 확인한 뒤
  종료한다. 만료된 접속에서는 입력을 막고 재인증 경로를 제공한다.
- Mac의 **연결 종료**는 외부 연결과 접속 키를 폐기한다. 다시 시작하면 새 키를 공유한다.
  기존 원본 CLI는 종료하지 않는다.
- 켜 둔 설정은 앱 재실행 후 복원된다. 주소나 키가 바뀌면 새 링크를 사용한다.
  외부 터널이 활성 상태이면 LAN 자동 업데이트는 기다린다.

## 구현·검증 범위

외부 터널은 별도의 IPv4 loopback 전용 게이트웨이에 연결한다. 기존 LAN
리스너의 사설 주소·Origin 검사와 검색을 바꾸지 않는다. 공개 요청은 지정한 HTTPS
Origin과 인증을 확인한 후 기존 엔진으로 전달한다. 쿠키·프록시 인증은 LAN 피어로
전달하지 않는다. 외부 페이지의 원본·업데이트 링크도 사설 IP 페이지로 보내지 않는다.
앱 설치 파일의 LAN 배포 경로는 외부 게이트웨이에서 제공하지 않는다.

게이트웨이는 연결 32개·스트림 12개·브라우저 인증 32개를 제한하고, 만료·로그아웃·
종료 때 진행 중인 연결도 해제한다. 터널 도구가 종료되면 최대 5회(1/2/4/8/16초)
재시도하고 실패를 표시한다. 앱 종료 시 소유한 연결 도구도 종료한다.
도구가 연결됐지만 공개 경로가 미완성인 경우에는 연결을 유지하며 주소 재확인을
기다린다. 로그 한 줄만 출력하는 연결 도구도 즉시 읽도록 비차단 단일 읽기를 사용한다.

설치 도구는 공식 **cloudflared 2026.10.3**의 아키텍처별 크기와 SHA-256을 고정해
검증한 뒤 실행 파일만 설치한다. 토큰·키·진단 원문은 공개 상태나 실행 인자에 넣지 않는다.
시스템 서비스·키체인 신뢰·VPN·전원 정책은 변경하지 않는다.
[공식 다운로드](https://developers.cloudflare.com/tunnel/downloads/),
[해당 배포](https://github.com/cloudflare/cloudflared/releases/tag/2026.10.3).

Cloudflare 연결 도구는 외부 **TCP 7844** 연결이 필요하다. 해당 경로가 막힌 네트워크에서는
연결 시간 초과와 원인을 표시하며 접속 링크를 준비된 상태로 표시하지 않는다.
현재 검증 환경에서도 공식 도구의 DNS 검사는 통과했지만 양쪽 edge의 TCP 연결은
시간 초과되어 실제 인터넷을 통한 Quick Tunnel 검사는 완료하지 못했다.
[Cloudflare 방화벽 요구사항](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/).

```sh
swift build -c release --scratch-path .build/tunnel
.build/tunnel/release/autoapprove-checks
node scripts/tunnel-browser-check.mjs --build=.build/tunnel/release
node scripts/tunnel-browser-check.mjs --build=.build/tunnel/release --webkit
node scripts/tunnel-browser-check.mjs --build=.build/tunnel/release --public
node scripts/tunnel-settings-preview.mjs --build=.build/tunnel/release
node scripts/tunnel-setup-ui-preview.mjs --build=.build/tunnel-setup/release
```

브라우저 검사는 합성 HTTPS 호스트·실제 인증 게이트웨이·격리 PTY를 사용한다.
`--public`은 공식 도구를 임시 폴더에 설치하고 합성 데이터만 있는 실제 임시 주소를
검사한 뒤 종료한다. 사용자 터미널이나 Cloudflare 계정 토큰은 사용하지 않는다.
실물 휴대폰·모든 인터넷 환경·사용자 계정의 고정 도메인 검증과 구분한다.
네이티브 조작용 미리보기는 빈 loopback 프로필과 외부 통신이 없는 합성 연결 도구를
사용한다. 자동 도구 다운로드의 원본은 기존 고정 SHA-256 검증 설치기이며, 이 조작
fixture에서는 실제 공개 터널이나 사용자 계정 토큰을 사용하지 않는다.
