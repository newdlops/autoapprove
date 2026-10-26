# 터미널 입력·커서 지연 · 0.2.182/209

원본 직접 입력의 trailing 80ms debounce를 **최초 입력 뒤 8ms**의 고정
창으로 바꿨다. 다음 문자가 기존 대기를 늦추지 않으며, 특수키는 앞선
문자와의 순서를 유지해 바로 깨운다. 원본 화면·커서를 같은 렌더링 프레임에
배치하고, animation frame이 멈출 때의 100ms 보완 경로는 유지한다.

PTY의 trailing 15ms 대기도 고정 **4ms**로 바꿨다. 응답을 기다리는 동안
쌓인 **미전달** 바이트를 최대 16,000B로 합친다. 요청 하나의 확인을 받은 뒤
다음 순번을 보내며, 입력 대기 상한 128,000B와 원본 식별·writer lease는 유지한다.
전송 결과가 불확실하면 다시 보내지 않고, 아직 전송하지 않은 내용만 보존한다.

대용량 입력 검사에서 기존 PTY 쓰기가 `EAGAIN`을 기다리는 동안 출력 읽기도
같은 잠금에 막히는 문제를 확인했다. 자식이 출력을 쓰느라 입력을 읽지 못하면
부분 입력 뒤 1초 제한으로 실패했다. 이제 그 경로에서 같은 소유 FD의 출력을
비우며 남은 바이트부터 이어 쓴다. monotonic 1초 예산·선점한 입력 순번은 유지한다.
터미널의 질의 응답은 현재 쓰기의 중간에 끼우지 않고 최대 65,536B로 보관했다가
그 쓰기 뒤에 처리한다. 입력 전체를 다시 쓰거나 다른 TTY를 여는 경로는 없다.

## 브라우저 대조

같은 최종 Core에 0.2.181과 최종 `app.js`/`pty.js`를 번갈아 제공했다.
원본은 정확한 PID·시작 시각·TTY를 가진 합성 편집 어댑터이며, PTY는 실제
격리 zsh다. 실제 키보드 이벤트부터 텍스트·원본 커서가 맞는 첫 브라우저
animation frame까지 측정했다. PTY는 xterm의 실제 render 콜백도 확인한다.
물리 디스플레이·OS compositor, 실제 Terminal 접근성 읽기, 무선망 지연은 제외한다.

각 셀은 **12회 중앙값(ms)** 이다. 원본 방향키와 PTY 방향키는 좌우 각 6회다.

| 경로 | Chromium 이전→개선 | WebKit 이전→개선 |
|---|---:|---:|
| 원본 문자·커서 반영 | 157→47 | 145→51 |
| 원본 방향키 반영 | 98→47 | 50→51 |
| 실제 PTY 문자 반영 | 48→31 | 38→24 |
| 실제 PTY 방향키 반영 | 48→48 | 37→25 |

방향키가 모든 환경에서 빨라졌다는 의미는 아니다. Chromium 원본 문자 반영
범위는 145~165→46~73ms, PTY 문자는 27~49→30~32ms였다. 연속 입력의
첫 POST는 Chromium **231→30ms**, WebKit **288→10ms**에 시작했다.
이 입력 중 총 요청은 Chromium 1→10회, WebKit 1→28회였다. 입력이 끝날
때까지 기다리지 않는 대신 실제 읽기·망 지연에 따라 전송 횟수가 늘 수 있다.

동일한 첫 입력 응답만 120ms 늦춘 PTY burst에서는 두 브라우저 모두
**21→2 POST**, HTTP JSON 본문 **4,771→486B**였다. 실제 입력 바이트와
순서는 같았다. 이 값은 해당 구간의 본문이며 전체 TCP 전송량 감소율이 아니다.

## 안정성·시각 확인

- 두 브라우저 모두 Unicode **56,003B**를 16KB 이하 4요청으로 전송하고
  실제 자식 프로세스가 기록한 바이트와 완전히 일치했다. 다중 바이트 문자의
  중간에서 나뉘는 경계도 포함한다. 수정 전 네이티브 후보는 56,000B 검사에서
  3,066B 뒤 부분 전송·결과 불확실로 멈췄다.
- 응답 유실은 실제 쓰기 성공을 먼저 확인한 뒤 주입한다. `UNCERTAIN`은
  실제 자식에 1회만 도착하고 추가 POST는 0회다. 대기 중인 `PRESERVE`는
  자식에 도착하지 않고 미전달 내용으로 보존된다.
- 원본의 모든 문자·방향키는 합성 어댑터 기록과 정확히 일치했다. 한글 조합
  중간 입력은 전송하지 않고 완성 문자열을 1회 보냈다. 이는 DOM 조합 이벤트
  검사이며 실제 휴대폰 IME 검증과 구별한다.
- 최종 Core **451/451**, 원본 복구 **9개**, 정지된 animation frame·이전 대상
  이벤트·권한 변경 등 브라우저 연결 회귀 **11개**, 실제 PTY **15개**를 통과했다.
  실제 PTY 역압은 최대 58,325B/64이벤트에서 멈춘 뒤 Ctrl C·완료 위치 재개를
  확인했다. 전체 CLI 입력·출력 5회는 80~91ms였으며 자동 타이핑 시간도 포함한다.
- 네이티브 PTY 통합 **17개**에서 중복 영수증·순번·writer/origin 격리,
  크기 변경·지속 출력/Ctrl C·자식/고아 그룹 종료·원격 생성/입출력/종료와
  조각난 원격 스트림의 상한·식별·취소도 확인했다.
- Chromium/WebKit의 **390×844·768×1024·1440×900** 화면을 별도로 확인했다.
  기존 글꼴·색·조작 배치를 보존하고 커서·포커스·한글/이모지 줄바꿈·가로 넘침을
  확인했다. Impeccable 변경 JS 정적 detector는 0건이다. 실제 휴대폰·VoiceOver·
  장시간 무선망의 네이티브 동등 반응 속도를 보증하는 측정은 아니다.

기존 ANSI 검증은 절대 행 이동 뒤 zsh가 지울 수 있는 중간 출력에 의존했다.
입력과 실제 원본 출력 바이트를 대조해 누락이 없음을 확인하고, 검증 문구를
지워지지 않는 첫 행에 출력하도록 fixture를 수정했다.

## 재현

```sh
swift build -c release --scratch-path .build/native-input
.build/native-input/release/autoapprove-checks
node scripts/terminal-input-latency-check.mjs --build=.build/native-input/release --baseline=v0.2.181
node scripts/terminal-input-latency-check.mjs --build=.build/native-input/release --baseline=v0.2.181 --webkit
node scripts/terminal-continuity-browser-check.mjs --core-build=.build/native-input/release
node scripts/terminal-connection-browser-check.mjs
node scripts/pty-browser-check.mjs --build=.build/native-input/release
node scripts/pty-integration-check.mjs --release --build=.build/native-input/release
```

Playwright와 Chromium/WebKit 실행 파일이 필요하다. 외부 모듈 경로는
`AUTOAPPROVE_PLAYWRIGHT_MODULE`, Chromium은 `AUTOAPPROVE_CHROMIUM_PATH`로
지정할 수 있다. 모든 입력·화면은 격리 fixture이며 사용자 원본을 조작하지 않는다.
