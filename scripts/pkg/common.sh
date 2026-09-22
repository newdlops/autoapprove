#!/bin/bash
# PackageKit runs these scripts with its own authorization. No password is read here.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

install_root=/Applications
target_app="$install_root/AutoApprove.app"
fail() { printf 'AutoApprove: %s\n' "$*" >&2; exit 1; }

check_volume() {
  [[ ${3:-} == / ]] || fail '시동 디스크의 응용 프로그램 폴더에 설치해주세요.'
  [[ -d "$install_root" && ! -L "$install_root" ]] || fail '응용 프로그램 폴더를 확인하지 못했습니다.'
}

check_bundle() {
  [[ -d "$target_app" && ! -L "$target_app" && ! -L "$target_app/Contents" &&
     ! -L "$target_app/Contents/Info.plist" && ! -L "$target_app/Contents/MacOS" &&
     ! -L "$target_app/Contents/MacOS/AutoApproveApp" ]] || fail '설치 대상이 일반 앱 폴더가 아닙니다.'
  local identifier executable
  identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist") || fail '앱 정보를 읽지 못했습니다.'
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$target_app/Contents/Info.plist") || fail '앱 실행 파일 정보를 읽지 못했습니다.'
  [[ "$identifier" == local.autoapprove.mac && "$executable" == AutoApproveApp ]] || fail '같은 이름의 다른 앱은 교체하지 않습니다.'
}
