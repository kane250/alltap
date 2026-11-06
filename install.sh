#!/usr/bin/env bash
# alltap 安装脚本
#   ./install.sh              -> ~/.local/bin + ~/.local/share/alltap
#   sudo ./install.sh /usr/local  -> /usr/local/bin + /usr/local/share/alltap
set -e
cd "$(dirname "$0")"

PREFIX="${1:-$HOME/.local}"
BIN="$PREFIX/bin"
SHARE="$PREFIX/share/alltap"

# 单前缀模式: PREFIX 传 "--usr" 时装 /usr | "usr" 类似
mkdir -p "$BIN" "$SHARE"
install -m 755 alltap "$BIN/alltap"
install -m 644 data/dep-map.conf "$SHARE/dep-map.conf"

echo "已安装:"
echo "  $BIN/alltap"
echo "  $SHARE/dep-map.conf"
case "$BIN" in
    "$HOME"/.local/bin|*/.local/bin)
        grep -q '.local/bin' <<<"$PATH" || echo '提示: 请把 ~/.local/bin 加入 PATH'
        ;;
esac
echo "验证: alltap --show-version"
