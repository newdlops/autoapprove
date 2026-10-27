# 다른 네트워크에서 웹 접속

AutoApprove의 **연결 설정 → 다른 네트워크에서 접속**에서 켠다.
외부 접속은 기본적으로 꺼져 있다. 0.2.185부터 연결을 시작하면 필요한 연결 도구와
이 Mac의 웹 접속을 자동으로 준비한다.
기존 LAN의 연결 코드 없는 사용과 외부 접속의 인증은 별개다.

## 네트워크가 바뀌거나 잠시 끊겼을 때

0.2.191부터 일시적인 HTTPS 443 중계 실패와 연결 도구 종료는 횟수 제한으로
영구 중단하지 않는다. 재시도 간격은 분산해 최대 30초로 제한하고,
서버가 `Retry-After`를 지정하면 그 대기를 우선한다. 네트워크 복귀·Mac 깨우기는
대기를 줄이며, 명시적인 **연결 종료/취소**는 이후 재시도까지 중지한다.
접속 PIN·게이트웨이·브라우저 인증은 단순 재접속 동안 유지하고 불확실한 입력은 재전송하지 않는다.
중계의 401/403이나 연결 도구의 명확한 인증 거절은 승인을 확인할 수 있도록 오류로 표시한다.

연결 도구가 준비되어도 공개 주소의 DNS·경로 반영은 늦을 수 있다.
초기 확인에 실패하면 30초 간격의 자동 확인을 계속하며 **공개 주소 확인**으로
즉시 확인할 수도 있다. 실제로 이 Mac의 nonce가 일치한 뒤 접속 링크를 표시한다.
Tunnel 복구 대기 중에도 **HTTPS (443)로 연결**로 방식을 바꿀 수 있다.
관리 API를 이용한 Worker 코드 갱신은 연결 시작 때 3초까지만 기다린다.
갱신이 늦으면 취소하고 기존 중계의 호환 기능으로 연결하며 다음 연결에서 다시 시도한다.

LAN은 IP가 그대로인 재접속도 경로 복귀로 인식해 이전 읽기·경로 통계와 검색 상태를 갱신한다.
관리 페이지의 선택적 입력 스크립트가 늦어도 목록을 열며, 입력 기능이 나중에 도착하면
기존 HTTP 입력의 확인 응답 뒤에 전환한다. 터미널 구성 JS·CSS는 병렬로 받고
8초 안에 받지 못하면 기존 **화면 다시 연결**에서 새 요청으로 재시도한다.

## 연결 품질과 빠른 입력

0.2.190부터 웹 터미널은 지원되는 연결에서 입력 전용 WebSocket을 사용한다.
이전 키의 확인 응답을 기다리는 동안에도 제한된 양의 다음 입력을 순서대로 전송한다.
첫 입력은 즉시 전달하고 뒤따르는 짧은 입력만 묶는다. 화면 출력과 입력은 각각 복구하며,
미확인 입력이 없는 유휴 연결은 자동으로 다시 확인한다. 결과가 불확실한 입력은
자동 재전송하지 않으며 아직 전송하지 않은 텍스트를 보존한다.
구버전이나 WebSocket을 차단한 환경에서는 입력을 시작하기 전에 기존 HTTP 방식으로 전환한다.

웹 터미널 상단의 `ms`는 **접속 기기에서 측정한 입력 왕복 지연**이다.
Mac의 **연결 품질**을 펼치면 이 Mac에서 공개 주소를 돌아오는 지연의 중앙값/95백분위,
Cloudflare 처리 지점, 재연결 횟수를 볼 수 있다. Tunnel 도구가 제공하는 QUIC 지연·유지 연결·
누적 손실과 443 중계의 WSS 왕복은 별도로 표시한다. 제공되지 않은 값은 만들어 표시하지 않는다.
연결 중 30초마다 확인하며 **다시 측정**으로 갱신한다. 최근 확인 실패는 마지막 성공값과 구분한다.
Mac의 자기 주소 확인 값과 휴대폰의 입력 지연은 서로 다른 경로의 측정이다.

443 중계는 새 기능을 협상한 뒤 큰 출력을 gzip으로 압축하고, 입력 확인/제어 프레임을
대량 출력보다 먼저 처리한다. 압축 해제 크기와 전송 창을 제한한다. 앱 업데이트 후 연결할 때
소유한 Worker 코드만 갱신하며 DNS·도메인·연결 비밀을 바꾸지 않는다. 관리 API를 사용할 수
없으면 기존 중계를 유지하고 연결 품질에 호환 모드임을 표시한다. 다음 연결에서 다시 시도한다.
계측에는 숫자와 지점 코드만 보관하며 PIN·접속 키·터미널 내용을 넣지 않는다.
[전송 형식](TERMINAL_WIRE.md#persistent-input-channel).

## 내 PIN으로 접속

0.2.189부터 클라이언트의 **내 접속 PIN**에서 숫자 **6~12자리**를 입력하고
**PIN 설정**을 누른다. 앞의 `0`도 유지된다. 이후 공유 링크와 QR에는 긴 접속 키가
붙지 않으며, 짧은 주소를 연 뒤 웹의 **접속 PIN**에 지정한 숫자만 입력하면 된다.
브라우저 접속은 최대 8시간 유지된다. 이 PIN은 해당 Mac의 외부 접속에 적용한다.

PIN은 연결 전이나 연결 중에 설정할 수 있다. 바꾸려면 새 PIN을 입력하고 **PIN 변경**을
누른다. 변경·해제하면 이전 로그인과 접속 키를 폐기한다. 기존 페이지는 미전송 입력을
보존한 채 다시 연결하도록 안내한다. **해제**하면 새 긴 접속 키 방식으로 돌아간다.
PIN이 없는 기존 연결은 이전과 같은 키·링크 방식으로 사용한다.

원문 PIN은 저장하지 않는다. 무작위 salt와 PBKDF2-HMAC-SHA256 600,000회로 만든
검증값을 Mac 키체인에 저장하고 화면·URL·상태 응답에는 넣지 않는다.
PIN 검증은 백그라운드에서 수행하며 동시 요청도 합쳐 60초에 5회로 제한한다.
횟수를 초과하면 60초 뒤 다시 시도한다.
[해시 비용 기준](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html#pbkdf2).

## HTTPS 443 연결 · 승인 → 도메인 선택 → 연결

0.2.188부터 새 설정의 기본은 **Cloudflare HTTPS (443)**다.
Tunnel의 UDP/TCP 7844가 막혀 있고 HTTPS·WebSocket 443이 허용된 네트워크에서 사용한다.
기존 Tunnel 실패 화면의 **HTTPS (443)로 연결** 버튼으로 전환할 수도 있다.

1. **Cloudflare에서 승인**을 누른다. 공식 Wrangler 도구를 앱 전용 폴더에 준비한다.
   브라우저에서 사용자가 직접 Workers 관리와 도메인 연결을 승인한다.
   기존 Tunnel 승인과 Workers 승인은 권한이 달라 최초 한 번 더 필요하다.
2. 등록된 도메인을 선택하고 `a`, `cp`, `term`처럼 원하는 **서브도메인**을 입력한다.
3. **연결**을 누른다. 앱이 계정에 Worker·SQLite Durable Object와 도메인을 설정하고,
   이 Mac까지 공개 주소를 검증한 뒤 접속 링크와 QR을 표시한다.

별도 서버 운영이나 토큰 복사는 필요 없다. 앱과 Workers 사이는 네이티브 지속 WSS 443이며
터미널의 기존 비트 스트림을 중계한다. 작은 바이너리 출력도 줄바꿈을 기다리지 않고 전달한다.
공개 주소에는 기존 접속 키와 Secure/HttpOnly/SameSite 쿠키 인증이 적용된다.
중계 연결의 비밀은 별도로 발급하고 Worker에는 그 해시만 둔다.
재접속 중에는 진행 중 요청을 버리고 입력을 자동 재전송하지 않는다.

승인 정보와 중계 비밀은 앱 전용 Mac 키체인에 저장한다. 공식 도구는 승인·갱신에만 사용하며
기존 `~/.wrangler` 설정은 읽거나 수정하지 않는다. 승인 중 임시 파일은 `0700/0600`으로
제한하고 작업 완료·취소 시 삭제한다. 공식 OAuth의 이 Mac 콜백은 `localhost:8976`이다.
외부 통신 포트가 아니며, 이 포트를 다른 앱이 사용하면 해당 앱을 닫고 다시 승인한다.
유효한 Node가 없으면 체크섬을 고정한 공식 Node LTS도 앱 전용 폴더에 준비한다.

기존 다른 DNS/Worker는 덮어쓰지 않는다. 충돌 시 다른 이름을 선택한다.
첫 연결이 도메인 충돌로 실패하면 이 앱 소유의 미연결 Worker만 계정에 남을 수 있으며,
재시도할 때 같은 Worker를 재사용한다. 이름을 바꾸면 이전 DNS를 삭제하지 않지만
이전 주소의 접속은 보장하지 않으므로 새 링크를 사용한다.
연결을 종료하면 Mac의 외부 접속을 닫고, 원격 Worker와 도메인 설정은 재사용을 위해 남긴다.

Workers Free에서 사용하는 SQLite Durable Object를 구성하며 유료 요금제를 자동 신청하지 않는다.
Cloudflare 계정의 사용량 한도가 적용되고, 방화벽이 HTTPS의 WebSocket까지 차단하면 연결할 수 없다.
[공식 WebSocket 연결](https://developers.cloudflare.com/durable-objects/best-practices/websockets/),
[Workers 요금·한도](https://developers.cloudflare.com/workers/platform/pricing/).

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

## Cloudflare 고정 주소 · 승인 → 도메인 선택 → 연결

**Cloudflare Tunnel (자동)**을 선택한다. 0.2.186에서 추가한 기존 방식이며 별도 서버나 토큰 복사 없이 진행한다.

1. **Cloudflare에서 승인**을 누른다. 필요한 공식 연결 도구를 준비하고 브라우저의
   Cloudflare 로그인·도메인 승인 화면을 연다. 사용자가 직접 로그인하고 허용한다.
2. 앱의 **등록된 도메인**에서 사용할 도메인을 선택하고 **서브도메인**을 입력한다.
   `a`를 입력하면 `https://a.선택한도메인`으로 연결한다. 새 설정의 제안 값은 `aa`이며
   영문·숫자·하이픈 1~63자를 사용할 수 있다. 처음과 끝에는 하이픈을 쓸 수 없다.
   승인된 계정의 활성 도메인을
   표시한다. Cloudflare 승인이 선택한 도메인만 조회하도록 제한된 경우 그 도메인을 표시한다.
3. **연결**을 누른다. 앱이 이 Mac의 터널과 직접 지정한 주소를
   만들고 DNS·내부 포트·웹 접속을 자동 설정한다. 공개 주소가 이 Mac의 인증 게이트웨이에
   연결되는지 확인한 뒤 접속 링크·QR을 제공한다.

Cloudflare에 이미 등록되어 활성화된 도메인이 필요하다. 승인 인증서는 계정의 터널
관리와 도메인 연결을 허용한다. 승인 정보는 이 Mac의 앱 전용 키체인에 보관하며,
연결 도구에는 해당 터널만 실행할 수 있는 정보만 `0600` 임시 파일로 전달한다.
승인 파일은 앱 전용 임시 HOME에서 읽고 삭제한다. 기존 `~/.cloudflared` 설정은 사용하지 않는다.
[공식 로컬 관리 터널 설정](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/),
[승인 인증서와 실행 인증 정보의 권한](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/tunnel-permissions/).

기존 DNS 기록은 변경하거나 삭제하지 않는다. 지정한 주소가 이미 사용 중이면 오류를
표시하므로 다른 이름을 입력한다. 임의의 접미사를 붙이지 않는다. 생성 응답을 받지 못해
다시 연결할 때는 저장한 생성 의도와 실행 정보를
이용해 이전 결과부터 확인한다. 준비 중 **취소**하면 이 앱의 승인·연결 작업을 중지한다.
DNS 반영이 늦으면 연결 도구를 유지하며 **공개 주소 확인**으로 재검사할 수 있다.

기존에 저장한 주소는 업데이트 후에도 유지한다. 주소를 바꾸려면 **연결 종료** 후
서브도메인을 수정하고 다시 연결한다. 이후에는 새 접속 링크·QR을 사용한다.

## Cloudflare 토큰 직접 입력 · 기존 수동 설정

1. 앱에서 **Cloudflare 토큰 직접 입력 → Cloudflare 터널 열기**를 누른다.
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

0.2.187부터 연결 도구의 QUIC/HTTP2와 IPv4/IPv6 선택을 자동으로 맡긴다. TCP가 막혀도
UDP가 허용되면 QUIC을 사용할 수 있고, UDP가 막히면 HTTP2를 사용할 수 있다.
Cloudflare Tunnel은 **UDP 또는 TCP 7844**가 필요하며 443으로 포트만 바꾸는 기능은 없다.
443 전용 연결은 별도 Workers 중계 기능이 필요하며 0.2.187의 자동 전환과 구분한다.
사용 가능한 경로가 없으면 실패를 표시하고 접속 링크를 준비된 상태로 표시하지 않는다.
현재 검증 환경에서도 공식 도구의 DNS 검사는 통과했지만 양쪽 edge의 TCP 연결은
시간 초과되어 실제 인터넷을 통한 Quick Tunnel 검사는 완료하지 못했다.
[Cloudflare 방화벽 요구사항](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/).
[자동 프로토콜과 연결 진단](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/connectivity-prechecks/).

```sh
swift build -c release --scratch-path .build/cloudflare-address
.build/cloudflare-address/release/autoapprove-checks
node scripts/tunnel-browser-check.mjs --build=.build/cloudflare-address/release
node scripts/tunnel-browser-check.mjs --build=.build/cloudflare-address/release --webkit
node scripts/tunnel-browser-check.mjs --build=.build/cloudflare-address/release --public
node scripts/tunnel-settings-preview.mjs --build=.build/cloudflare-address/release
node scripts/tunnel-setup-ui-preview.mjs --build=.build/cloudflare-address/release --output=.runtime/cf-address-187
```

브라우저 검사는 합성 HTTPS 호스트·실제 인증 게이트웨이·격리 PTY를 사용한다.
`--validate-cli=/검증한/cloudflared`를 추가하면 생성한 로컬 설정과 실행 옵션을 해당
공식 도구의 `ingress validate`·`run --help`로 검사하며 외부 연결은 시작하지 않는다.
`--public`은 공식 도구를 임시 폴더에 설치하고 합성 데이터만 있는 실제 임시 주소를
검사한 뒤 종료한다. 사용자 터미널이나 Cloudflare 계정 토큰은 사용하지 않는다.
실물 휴대폰·모든 인터넷 환경·사용자 계정의 고정 도메인 검증과 구분한다.
네이티브 조작용 미리보기는 빈 loopback 프로필·합성 계정/DNS API·외부 통신이 없는
합성 연결 도구를 사용한다. 승인·도메인 선택·연결·취소·재시도를 실제 네이티브 조작으로
검사할 수 있다. 실제 Cloudflare 계정 승인과 도메인 생성·인터넷 경유 연결 검증은
이 합성 검사와 별개이며 사용자 승인 후 완료해야 한다.
