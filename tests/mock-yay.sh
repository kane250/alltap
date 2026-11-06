#!/usr/bin/env bash
# mock AUR helper (yay/paru 替身): 把 -S 的包名记入 MOCK_STATE/aur-install.log
set -u
STATE="${MOCK_STATE:?需要 MOCK_STATE}"
echo "mock-yay $*" >> "$STATE/aur-calls.log"
for a in "$@"; do
    case "$a" in
        -*|--*) ;;
        *) echo "$a" >> "$STATE/aur-install.log" ;;
    esac
done
echo "==> mock-yay: 已构建并安装 $*"
exit 0
