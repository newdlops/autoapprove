# 연결 중 ‘상태 미확인’이 반복되는 문제

0.2.184는 연결된 CLI의 현재 화면을 판독하지 못해 ‘상태 미확인’으로 남는 세 가지
경우를 수정한다. 기존 LAN 검색·실시간 스트림·폴링 간격·원본 입력 경로는 유지한다.

- Claude의 입력창 아래에 `프로젝트 | 브랜치 | Opus 5.5 | ctx 42% | 7d 94%` 형태의
  사용자 상태줄이 있고 정식 단축키 안내가 함께 있으면 입력 대기 화면으로 인식한다.
  Opus·Sonnet·Haiku 모델명과 0~100% 수치만 허용한다.
- Codex의 정식 상태 안내 뒤 `⚠ 2 warnings · f2 to view`가 있어도 현재 입력창을
  인식한다. 실제 초안이 있으면 ‘응답 필요’, 비어 있으면 반복 확인 뒤 ‘대기 중’이다.
- Codex의 정확한 서버 대기 대화상자(‘Giving this request a little extra thought’,
  ‘Dismiss and keep waiting’, ‘Learn more’, 응답을 계속 기다린다는 안내)는 ‘작업 중’이다.
  앱이 해당 메뉴를 누르거나 입력을 보내지 않는다.

임의의 하단 문구·질문 메뉴·불명확한 화면은 계속 ‘상태 미확인’으로 남는다.
새 원본 세대와 입력 대기 전환에는 기존 2초 반복 확인을 유지한다. 실제 화면 읽기
실패·권한 거부·연결 해제·프로세스 종료도 기존대로 처리한다. 기존 입력 검증이나
자동 승인 허용 범위를 넓히지 않는다.

## 확인한 원인과 재현

수정 전 실제 두 Mac을 75초·31표본 관찰했을 때 요청 실패·오프라인 표본은 0개였다.
‘상태 미확인’은 일반 화면 판독 실패 217회, 입력 대기 반복 확인 중 2회였다(세션별
합계). 당시 캡처한 미확인 화면 7개를 같은 입력으로 대조하면 0.2.183은 7개 모두
미확인, 수정 판독기는 Claude 대기 5개·Codex 작업 중 1개·Codex 초안 1개로 구분한다.
사용자 화면 원문은 비공개로 보관하며 공개 테스트는 합성 화면으로 재현한다.

```sh
swift build -c release --scratch-path .build/status-stability
.build/status-stability/release/autoapprove-checks
node scripts/activity-status-browser-check.mjs --build=.build/status-stability/release
node scripts/realtime-check.mjs --build=.build/status-stability/release
```

브라우저 재현은 격리한 실제 Swift 엔진·HTTP·합성 CLI 4개를 사용한다.
0.2.183에서는 네 상태가 모두 미확인으로 재현되고, 수정 후에는 각각 대기·초안·대기·
작업 중으로 표시된다. Chromium/WebKit의 모바일·태블릿·데스크톱 렌더링과 초안,
불명확한 화면, 실제 읽기 실패/복구, 명시적 연결 해제/재연결을 검사한다.
물리 휴대폰·모든 CLI 플러그인·여러 무선망의 장기 안정성 보장과 구분한다.
