#!/bin/bash
# Packs build/Runespeak.app into build/Runespeak.dmg, a compressed read-only disk image for
# handing the app to another Mac.
#
#   scripts/build-dmg.sh             builds the app first (scripts/build-app.sh), then packs it
#   scripts/build-dmg.sh --no-build  packs the app that is already in build/
#
# The image holds three things: the app, an Applications symlink to drop it on, and a first-run
# note. Nothing from the data folder (keys, settings, chat log) is read or copied.
# Runs headless: hdiutil, ditto, xattr and codesign only, no Finder scripting. It never launches the app,
# never writes to /Applications (the symlink only names it) and leaves no volume mounted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Runespeak.app"
DMG="$ROOT/build/Runespeak.dmg"
VOLUME_NAME="Runespeak 채팅 번역"
# Sorts ahead of the two Latin names in a Korean Finder, after them in other languages.
GUIDE_NAME="먼저 읽어 주세요.txt"

usage() {
    echo "사용법: scripts/build-dmg.sh [--no-build]"
    echo "  (옵션 없음)  scripts/build-app.sh로 앱을 새로 만든 뒤 build/Runespeak.dmg로 묶습니다."
    echo "  --no-build   이미 만들어 둔 build/Runespeak.app을 그대로 묶습니다."
}

BUILD=1
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "오류: 알 수 없는 옵션입니다: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

for tool in hdiutil ditto codesign xattr; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "오류: $tool 명령을 찾을 수 없습니다. macOS에서 실행해 주세요." >&2
        exit 1
    fi
done

# What would keep the finished image from being put in place is found out now: before the app
# is built anew, and not after the image has been made. (A link to a folder counts as a folder:
# the image would be moved into it. A build/ folder that is not there yet is made by
# scripts/build-app.sh.)
if [ -d "$DMG" ]; then
    echo "오류: build/Runespeak.dmg 자리에 폴더(또는 폴더로 가는 링크)가 있습니다. 옮기거나 지운 뒤 다시 실행해 주세요." >&2
    exit 1
fi
if [ -e "$ROOT/build" ] && [ ! -w "$ROOT/build" ]; then
    echo "오류: build/ 폴더에 쓸 수 없어 디스크 이미지를 둘 수 없습니다. 폴더의 권한을 확인해 주세요." >&2
    exit 1
fi
if [ -e "$DMG" ] || [ -L "$DMG" ]; then
    case "$(stat -f %Sf "$DMG" 2>/dev/null)" in
        *uchg*|*schg*)
            echo "오류: 이전 build/Runespeak.dmg가 잠겨 있어 바꿀 수 없습니다." >&2
            echo "      Finder의 [정보 가져오기]에서 「잠금」을 풀거나 파일을 지운 뒤 다시 실행해 주세요." >&2
            exit 1
            ;;
    esac
fi

if [ "$BUILD" = 1 ]; then
    /bin/bash "$ROOT/scripts/build-app.sh"
fi

if [ ! -d "$APP" ] || [ -L "$APP" ]; then
    echo "오류: build/Runespeak.app이 없습니다." >&2
    echo "      scripts/build-app.sh로 앱을 먼저 만들거나, --no-build 없이 다시 실행해 주세요." >&2
    exit 1
fi

# Prints codesign's own words under a Korean explanation and stops.
require_valid_signature() {
    local bundle="$1" label="$2" log
    if ! log="$(codesign --verify --deep --strict "$bundle" 2>&1)"; then
        echo "오류: ${label}의 서명이 확인되지 않습니다. 서명한 뒤에 내용이 바뀐 것으로 보입니다." >&2
        if [ -n "$log" ]; then printf '%s\n' "$log" | sed 's/^/      /' >&2; fi
        echo "      scripts/build-app.sh로 앱을 다시 만들어 주세요." >&2
        exit 1
    fi
}
require_valid_signature "$APP" "build/Runespeak.app"

# Everything is put together in a private folder that goes away however the script ends.
WORK="$(mktemp -d -t runespeak-dmg)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

STAGE="$WORK/stage"
mkdir "$STAGE"
chmod 755 "$STAGE"

# ditto keeps the bundle exactly as it was signed (modes, symlinks). Extended attributes are left
# behind: the signature of this bundle lives in its files, and Finder or quarantine marks picked
# up on this Mac (where a file was downloaded from, a Finder comment) are not for the recipient.
# ditto's own flags drop them from folders only, so they are cleared from the copy as well.
# The copy is checked before it is packed.
ditto --norsrc --noextattr --noqtn --noacl "$APP" "$STAGE/Runespeak.app"
xattr -cr "$STAGE/Runespeak.app" 2>/dev/null || true
require_valid_signature "$STAGE/Runespeak.app" "복사한 Runespeak.app"

# The app's own files (keys, settings, chat log) live in the data folder, never in the bundle.
# Should a future build step ever put one there, stop instead of handing it out.
leaked="$(find "$STAGE" \( -name 'key_*.txt' -o -name 'settings.json' -o -name 'chat_history.txt' \) -print)"
if [ -n "$leaked" ]; then
    echo "오류: 앱 안에 개인 파일로 보이는 것이 들어 있어 디스크 이미지를 만들지 않습니다." >&2
    printf '%s\n' "$leaked" | sed "s|^$STAGE/|      |" >&2
    exit 1
fi

ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/$GUIDE_NAME" <<'GUIDE'
Runespeak 채팅 번역 — 처음 실행 안내

월드 오브 워크래프트의 외국어 채팅을 한국어로 옮겨 게임 채팅창 위에 보여 주는 앱입니다.
macOS 14 이상의 Apple Silicon(M1 이후) Mac에서만 동작합니다.

1. 설치
   이 창의 Runespeak을 옆의 Applications(응용 프로그램) 폴더로 끌어다 놓습니다.
   그런 다음 응용 프로그램 폴더에서 Runespeak을 엽니다. 이 창 안에서 바로 열지는 마세요.

2. 처음 열 때 (한 번만)
   Apple의 확인(공증)을 받지 않은 앱이라, 처음 열면 macOS가 막고 안내 창을 띄웁니다.
   그 창의 [휴지통으로 이동]은 누르지 마세요.

   macOS 15 이상
   - 안내 창을 [완료]로 닫습니다.
   - 시스템 설정 > 개인정보 보호 및 보안을 열어, 아래쪽 "보안" 부분의 [그래도 열기]를 누릅니다.
   - 한 번 더 [그래도 열기]를 누르고 Mac 로그인 암호(또는 Touch ID)를 입력합니다.
   [그래도 열기]는 앱을 열어 본 뒤 한 시간쯤만 보입니다. 보이지 않으면 앱을 다시 열어 보세요.

   macOS 14
   - 응용 프로그램 폴더의 Runespeak을 Control-클릭(우클릭)해 [열기]를 고르고,
     이어서 뜨는 창에서 [열기]를 누릅니다. 위의 [그래도 열기] 방법으로 해도 됩니다.

   한 번 허용하면 다음부터는 그냥 열립니다.

3. 화면 기록 허용
   화면에 보이는 채팅창에서 글자를 읽기 때문에 화면 기록을 허용해야 합니다.
   - Runespeak 창의 [시스템 설정 열기]를 누릅니다. (직접 찾아가려면
     시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음)
   - 목록에서 Runespeak의 스위치를 켭니다.
   - Runespeak 창의 [다시 실행]을 누릅니다. 허용은 앱을 새로 띄워야 적용됩니다.
     (시스템 설정이 [종료 및 다시 열기]를 물으면 그것을 눌러도 됩니다.)

4. 채팅창 위치 잡기
   게임을 띄워 둔 채로 Runespeak 창의 [채팅창 위치 잡기]를 누르고, 게임 화면 위에
   채팅창을 감싸는 사각형을 그립니다. 줄 맨 앞의 [길드] 같은 채널 이름까지
   사각형 안에 들어오게 하세요.

5. AI 키 넣기
   Runespeak 창의 [설정]을 열어 "AI 연결"에서 쓸 AI를 고르고, 자기 API 키를
   붙여 넣은 뒤 [저장]을 누릅니다. 키가 없으면 [키 만드는 곳 열기]에서 만듭니다.
   - 키는 각자 자기 것을 만들어 이 앱에만 넣습니다. 메신저, 메일, 게임 채팅
     어디에도 키를 적거나 보내지 마세요.
   - 요금은 번역한 만큼 AI 회사가 키 주인에게 청구합니다. 월 구독과는 별개입니다.
   - 키가 없어도 무료 번역(MyMemory)으로 동작하지만, 게임 용어에 약하고
     하루에 옮길 수 있는 분량이 정해져 있습니다.

알아 둘 것
- 읽어 들인 채팅 글은 번역을 위해 고른 AI 회사(키가 없으면 MyMemory)로 전송됩니다.
- 팬이 만든 도구이며 Blizzard Entertainment의 제품이 아닙니다.
- 설치가 끝나면 이 디스크는 추출하고 dmg 파일은 지워도 됩니다.
- 새 버전을 받으면 Runespeak을 종료한 뒤 같은 방법으로 덮어씁니다.
  그때 2번과 3번을 다시 해야 할 수 있습니다. 3번에서 Runespeak의 스위치가 이미 켜져
  있는데도 앱이 화면 기록을 허용해 달라고 하면, 스위치를 껐다가 다시 켜 보세요. 그래도
  안 되면 목록에서 Runespeak을 골라 [−]로 지우고 앱을 다시 열어 새로 허용합니다.
GUIDE
chmod 644 "$STAGE/$GUIDE_NAME"

# The image is made beside the staging folder and moved into place only when it is whole, so a
# failed run leaves an earlier build/Runespeak.dmg as it was.
OUT="$WORK/Runespeak.dmg"
LOG="$WORK/image.log"

# hdiutil writes an HFS+ image on every macOS the app supports. It mounts a scratch volume while
# it copies and detaches it itself. macOS 27 prints a deprecation notice for `hdiutil create` (the
# output is kept in the log and shown only on failure) and offers `diskutil image create from`,
# which makes an APFS image: that is the fallback for the day hdiutil stops doing this.
make_image() {
    local status=0
    hdiutil create -srcfolder "$STAGE" -volname "$VOLUME_NAME" -fs HFS+ \
        -format UDZO -imagekey zlib-level=9 "$OUT" >"$LOG" 2>&1 || status=$?
    if [ "$status" = 0 ]; then return 0; fi
    rm -f "$OUT"
    # Stopped by somebody (Ctrl-C reaches hdiutil even when this script was started with the
    # signal ignored; hdiutil then says "create canceled" and ends with 1): that is no reason
    # to make the image with another tool after all.
    if [ "$status" -gt 128 ] || grep -Eqi 'cancell?ed|취소' "$LOG"; then return 1; fi
    if command -v diskutil >/dev/null 2>&1; then
        echo "hdiutil로 만들지 못해 diskutil로 다시 만듭니다…"
        if diskutil image create from --format UDZO --volumeName "$VOLUME_NAME" \
                "$STAGE" "$OUT" >>"$LOG" 2>&1; then
            return 0
        fi
    fi
    return 1
}

echo "디스크 이미지 만드는 중…"
if ! make_image; then
    echo "오류: 디스크 이미지를 만들지 못했습니다." >&2
    sed 's/^/      /' "$LOG" >&2
    exit 1
fi
if ! hdiutil verify "$OUT" >"$LOG" 2>&1; then
    echo "오류: 만든 디스크 이미지가 검사를 통과하지 못했습니다." >&2
    sed 's/^/      /' "$LOG" >&2
    exit 1
fi

if ! mv -f "$OUT" "$DMG" 2>"$LOG"; then
    echo "오류: 만든 디스크 이미지를 build/Runespeak.dmg로 옮기지 못했습니다. 이전 파일은 그대로입니다." >&2
    sed 's/^/      /' "$LOG" >&2
    exit 1
fi

BYTES="$(stat -f %z "$DMG")"
SIZE="$(awk -v b="$BYTES" 'BEGIN { printf "%.1f MB", b / 1000000 }')"
echo "완성: $DMG ($SIZE, ${BYTES}바이트)"
echo "받는 사람은 이 파일을 열어 「${GUIDE_NAME}」를 따라 하면 됩니다."
