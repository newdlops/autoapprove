#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 022

install_root=/Applications
should_open=1
privileged=0
work=
lock_owned=0
backup_moved=0
committed=0

fail() { printf '\n설치 중단: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
AutoApprove 설치 및 실행

DMG 안에서 실행하면 AutoApprove를 응용 프로그램 폴더에 설치하고,
해당 앱의 다운로드 차단 표시를 제거한 뒤 실행합니다.
관리자 권한이 필요한 경우에만 Mac 로그인 암호를 요청합니다.

사용법: /bin/bash "설치 및 실행.command" [옵션]
  --destination 폴더  다른 응용 프로그램 폴더에 설치 (기본: /Applications)
  --no-open          설치 후 앱을 실행하지 않음
  --help             이 도움말 표시
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination)
      [[ $# -ge 2 ]] || fail '--destination 뒤에 설치 폴더가 필요합니다.'
      install_root=$2
      shift 2
      ;;
    --no-open) should_open=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "알 수 없는 옵션: $1 (--help로 사용법 확인)" ;;
  esac
done

[[ $(/usr/bin/uname -s) == Darwin ]] || fail 'macOS에서 실행해주세요.'
[[ $EUID -ne 0 ]] || fail 'sudo 없이 실행해주세요. 필요한 단계에서 관리자 암호를 요청합니다.'
script_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source_app="$script_root/AutoApprove.app"
[[ "$install_root" == /* && -d "$install_root" && ! -L "$install_root" ]] || fail '설치 폴더는 이미 존재하는 절대 경로여야 합니다.'
install_root=$(cd -- "$install_root" && pwd -P)
target_app="$install_root/AutoApprove.app"
lock="$install_root/.AutoApprove-install.lock"

validate_bundle() {
  local app=$1
  [[ -d "$app" && ! -L "$app" ]] || fail "AutoApprove 앱 폴더를 찾을 수 없습니다: $app"
  local identifier executable
  identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null) || fail "앱 정보를 읽을 수 없습니다: $app"
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null) || fail "앱 실행 파일 정보를 읽을 수 없습니다: $app"
  [[ "$identifier" == local.autoapprove.mac && "$executable" == AutoApproveApp ]] || fail "AutoApprove가 아닌 파일은 교체하지 않습니다: $app"
}

check_running() {
  local processes executable
  processes=$(/bin/ps -axo comm=) || fail '실행 중인 앱을 확인하지 못했습니다. 터미널에서 다시 실행해주세요.'
  while IFS= read -r executable; do
    if [[ "$executable" == "$target_app/Contents/MacOS/AutoApproveApp" ||
          "$executable" -ef "$target_app/Contents/MacOS/AutoApproveApp" ]] ||
       [[ $should_open -eq 1 && "$executable" == */AutoApprove.app/Contents/MacOS/AutoApproveApp ]]; then
      fail '실행 중인 AutoApprove를 메뉴에서 종료한 뒤 다시 실행해주세요.'
    fi
  done <<< "$processes"
}

authorize() {
  [[ $privileged -eq 0 ]] || return 0
  printf '\n관리자 권한이 필요합니다. Mac 로그인 암호를 입력해주세요.\n입력한 암호는 화면에 표시되지 않습니다.\n'
  /usr/bin/sudo -p 'Mac 로그인 암호: ' -v || fail '관리자 인증을 완료하지 못했습니다. 기존 앱은 유지됩니다.'
  privileged=1
}

run_target() {
  if [[ $privileged -eq 1 ]]; then
    /usr/bin/sudo -n "$@"
  else
    "$@"
  fi
}

cleanup() {
  local result=$? keep_work=0
  trap - EXIT INT TERM
  if [[ $backup_moved -eq 1 && $committed -eq 0 ]]; then
    if [[ ! -e "$target_app" && ! -L "$target_app" ]] && run_target /bin/mv "$work/Previous.app" "$target_app"; then
      printf '기존 앱을 복원했습니다.\n' >&2
    else
      printf '기존 앱이 다음 위치에 보관되어 있습니다: %s/Previous.app\n' "$work" >&2
      keep_work=1
    fi
  fi
  if [[ -n "$work" && $keep_work -eq 0 ]]; then
    run_target /bin/rm -rf -- "$work" || printf '임시 설치 폴더를 정리하지 못했습니다: %s\n' "$work" >&2
  fi
  if [[ $lock_owned -eq 1 ]]; then
    run_target /bin/rmdir "$lock" || printf '설치 잠금 폴더를 정리하지 못했습니다: %s\n' "$lock" >&2
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'AutoApprove 설치 및 실행\n\n1/3 앱 파일 검사\n'
validate_bundle "$source_app"
[[ "$source_app" != "$target_app" ]] || fail 'DMG 안의 설치 스크립트를 실행해주세요.'
/usr/bin/codesign --verify --deep --strict "$source_app" || fail '앱 파일 검사에 실패했습니다. DMG를 다시 받아주세요.'
if [[ -e "$target_app" || -L "$target_app" ]]; then validate_bundle "$target_app"; fi
check_running
# Replacing an app installed by an administrator also requires permission to
# remove its old Contents directory after a successful replacement.
[[ -w "$install_root" && ( ! -d "$target_app" || -w "$target_app/Contents" ) ]] || authorize
run_target /bin/mkdir "$lock" 2>/dev/null || fail '다른 설치가 진행 중이거나 설치 잠금 폴더가 남아 있습니다. 설치를 완료한 뒤 다시 실행해주세요.'
lock_owned=1
work=$(run_target /usr/bin/mktemp -d "$install_root/.AutoApprove-install.XXXXXXXX") || fail '임시 설치 폴더를 만들 수 없습니다.'
staged_app="$work/AutoApprove.app"

printf '\n2/3 앱 복사 및 실행 허용\n설치 위치: %s\n' "$target_app"
run_target /usr/bin/ditto "$source_app" "$staged_app" || fail '앱 복사에 실패했습니다. 저장 공간과 폴더 권한을 확인해주세요.'
# Delete only quarantine, including nested files. -s does not follow symlinks.
if ! run_target /usr/bin/xattr -r -s -d com.apple.quarantine "$staged_app" 2>/dev/null; then
  authorize
  run_target /usr/bin/xattr -r -s -d com.apple.quarantine "$staged_app" || fail '앱 실행 허용에 실패했습니다. 설치를 다시 실행해주세요.'
fi
run_target /usr/bin/codesign --verify --deep --strict "$staged_app" || fail '복사한 앱의 파일 검사에 실패했습니다.'
check_running
if [[ -e "$target_app" || -L "$target_app" ]]; then
  validate_bundle "$target_app"
  run_target /bin/mv "$target_app" "$work/Previous.app" || fail '기존 앱을 이동하지 못했습니다.'
  backup_moved=1
fi
run_target /bin/mv "$staged_app" "$target_app" || fail '새 앱을 설치 위치로 이동하지 못했습니다.'
committed=1

printf '\n3/3 설치 완료\n설정과 승인 내역은 유지됩니다.\n'
if [[ $should_open -eq 1 ]]; then
  /usr/bin/open "$target_app" || fail "앱은 설치되었습니다. 응용 프로그램 폴더에서 직접 열어주세요: $target_app"
  printf 'AutoApprove를 열었습니다. DMG를 추출해도 됩니다.\n'
else
  printf '설치한 앱: %s\n' "$target_app"
fi
