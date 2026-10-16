#!/bin/zsh
# 앱을 정상 종료(quit 이벤트)한 뒤 다시 띄운다. 강제 종료하면 오디오 탭·집계 장치가 정리되지 않는다.
cd "$(dirname "$0")/.."
APP=build/Textize.app

if pgrep -x Textize >/dev/null; then
  # 앱이 멈춰 있으면 osascript가 오래 기다리므로 백그라운드로 보내고 프로세스가 사라지는지만 본다 (최대 10초).
  osascript -e 'tell application id "wiki.paik.textize" to quit' >/dev/null 2>&1 &
  for i in {1..40}; do pgrep -x Textize >/dev/null || break; sleep 0.25; done
  if pgrep -x Textize >/dev/null; then
    echo "warning: quit에 응답하지 않아 강제 종료합니다." >&2
    pkill -x Textize
    for i in {1..8}; do pgrep -x Textize >/dev/null || break; sleep 0.25; done
  fi
fi

# 프로세스가 사라진 직후에는 LaunchServices가 아직 종료 중으로 보아 open이 -600으로 실패한다. 떠오를 때까지 재시도한다.
for i in {1..10}; do
  if open "$APP" 2>/dev/null; then
    sleep 1
    pgrep -x Textize >/dev/null && break
  fi
  sleep 1
done

PIDS=($(pgrep -x Textize))
if (( ${#PIDS} == 0 )); then echo "error: 앱이 실행되지 않았습니다." >&2; exit 1; fi
if (( ${#PIDS} > 1 )); then echo "warning: Textize 프로세스가 ${#PIDS}개입니다: $PIDS" >&2; fi
echo "restarted: pid $PIDS"
