#!/bin/zsh
cd "$(dirname "$0")"
pkill -x Imager 2>/dev/null
sleep 1
nohup "$PWD/build/Imager.app/Contents/MacOS/Imager" >/dev/null 2>&1 &
disown
exit 0