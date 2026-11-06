#!/usr/bin/env bash
# 真实 pacman 安装闭环测试
# 使用 unshare 用户命名空间 + 临时 --root, 完全隔离, 不触碰宿主系统
set -u
cd "$(dirname "$0")/.."
PROJ="$PWD"
OUT=$(mktemp -d /tmp/alltap-real-XXXXXX)
ROOT="$OUT/root"
CONF="$OUT/pacman-test.conf"
mkdir -p "$ROOT/var/lib/pacman" "$OUT/out"

cat > "$CONF" <<'EOF'
[options]
SigLevel = Never
Architecture = auto
EOF

PASS=0; FAIL=0
say_ok()  { echo "✓ $*"; PASS=$((PASS+1)); }
say_bad() { echo "✗ $*"; FAIL=$((FAIL+1)); }

echo "=== alltap 真实 pacman 安装闭环测试 $(date '+%F %T') ==="
echo "隔离根目录: $ROOT"

# ---- 测试 1: 正常安装 (无依赖 tarball 包) ----
CMD="export ALLTAP_NO_SUDO=1 ALLTAP_PACMAN_ROOT='$ROOT' ALLTAP_PACMAN_EXTRA='--config $CONF'
cd '$PROJ'
./alltap tests/fixtures/topdir-usr-tree.tar.gz -o '$OUT/out/t1' -i -y --max-tries 3 -q"
if unshare -r bash -c "$CMD" > "$OUT/t1.log" 2>&1 && [ -f "$ROOT/usr/bin/myapp" ]; then
    say_ok "真实 pacman 安装成功 (文件落地 $ROOT/usr/bin/myapp)"
else
    say_bad "真实 pacman 正常安装失败"; tail -20 "$OUT/t1.log"
fi

# ---- 测试 2: 缺依赖 -> 仓库无 -> 自动移除重打包 -> 安装成功 ----
CMD="export ALLTAP_NO_SUDO=1 ALLTAP_PACMAN_ROOT='$ROOT' ALLTAP_PACMAN_EXTRA='--config $CONF'
cd '$PROJ'
./alltap tests/fixtures/installtest_1.0_amd64.deb -o '$OUT/out/t2' -i -y --max-tries 4"
unshare -r bash -c "$CMD" > "$OUT/t2.log" 2>&1
if grep -q "nonexistent-dep-xyz" "$OUT/t2.log" \
   && grep -q "已移除上述依赖" "$OUT/t2.log" \
   && grep -q "✓ 安装成功" "$OUT/t2.log"; then
    say_ok "缺依赖(仓库无) -> 自动移除 -> 重打包 -> 安装成功"
else
    say_bad "缺依赖修复回路失败"; tail -25 "$OUT/t2.log"
fi

# ---- 测试 3: 真实文件冲突 -> --overwrite 精确覆盖 ----
echo "conflict-owner" > /dev/null
mkdir -p "$ROOT/usr/bin" && echo "preexisting" > "$ROOT/usr/bin/mockconflict"
CMD="export ALLTAP_NO_SUDO=1 ALLTAP_PACMAN_ROOT='$ROOT' ALLTAP_PACMAN_EXTRA='--config $CONF'
cd '$PROJ'
./alltap tests/fixtures/conflicttest_1.0_amd64.deb -o '$OUT/out/t3' -i -y --max-tries 4"
unshare -r bash -c "$CMD" > "$OUT/t3.log" 2>&1
if grep -q "检测到文件冲突" "$OUT/t3.log" && grep -q "✓ 安装成功" "$OUT/t3.log" \
   && grep -q "mockconflict" "$OUT/t3.log"; then
    say_ok "真实文件冲突 -> --overwrite 精确覆盖 -> 安装成功"
else
    say_bad "文件冲突修复回路失败"; tail -25 "$OUT/t3.log"
fi

# ---- 测试 4: 未加 -i 时不安装 (默认行为不变) ----
CMD="export ALLTAP_NO_SUDO=1 ALLTAP_PACMAN_ROOT='$ROOT' ALLTAP_PACMAN_EXTRA='--config $CONF'
cd '$PROJ'
./alltap tests/fixtures/helloworld-1.0.tar.gz -o '$OUT/out/t4' -q"
if unshare -r bash -c "$CMD" > /dev/null 2>&1 && [ ! -d "$ROOT/opt/helloworld" ]; then
    say_ok "默认模式不触发安装 (行为隔离正确)"
else
    say_bad "默认模式意外触发了安装"
fi

# ---- 测试 5: 多包事务: 依赖由同批包互相满足 (真实 pacman 同一 -U 事务) ----
CMD="export ALLTAP_NO_SUDO=1 ALLTAP_PACMAN_ROOT='$ROOT' ALLTAP_PACMAN_EXTRA='--config $CONF'
cd '$PROJ'
./alltap tests/fixtures/multia_1.0_amd64.deb tests/fixtures/multib_2.1_amd64.deb -o '$OUT/out/t5' -i -y --max-tries 3"
unshare -r bash -c "$CMD" > "$OUT/t5.log" 2>&1
if grep -q "依赖 multib 由同批包提供" "$OUT/t5.log" \
   && grep -q "✓ 安装成功" "$OUT/t5.log" \
   && [ -x "$ROOT/usr/bin/multa" ] && [ -x "$ROOT/usr/bin/multib" ]; then
    say_ok "多包事务: 互赖同批满足, 真实 pacman 一次安装两包成功"
else
    say_bad "多包事务安装失败"; tail -25 "$OUT/t5.log"
fi

# ---- 测试 6: --dry-run 预演 (真实 pacman 环境, 计划正确且未安装) ----
CMD="export ALLTAP_NO_SUDO=1 ALLTAP_PACMAN_ROOT='$ROOT' ALLTAP_PACMAN_EXTRA='--config $CONF'
cd '$PROJ'
./alltap tests/fixtures/multia_1.0_amd64.deb tests/fixtures/multib_2.1_amd64.deb -o '$OUT/out/t6' --dry-run -f"
unshare -r bash -c "$CMD" > "$OUT/t6.log" 2>&1
DRYOK=1
grep -q "由同批包互相提供 (同一 pacman -U 事务自动满足): multib" "$OUT/t6.log" || DRYOK=0
grep -q "此为 --dry-run 预演, 未执行任何安装" "$OUT/t6.log" || DRYOK=0
[ -f "$OUT/out/t6/alltap-plan.txt" ] || DRYOK=0
# 隔离根不应出现 dry-run 声称会装的文件 (multia 尚未安装过? 已被 t5 装过, 改查 t6 独有标记)
# t5 已装 multa/multib; dry-run 不应有任何新安装动作 -> 用一个全新包验证不落地
CMD2="export ALLTAP_NO_SUDO=1 ALLTAP_PACMAN_ROOT='$ROOT' ALLTAP_PACMAN_EXTRA='--config $CONF'
cd '$PROJ'
./alltap tests/fixtures/helloworld-1.0.tar.gz -o '$OUT/out/t6b' --dry-run -f"
unshare -r bash -c "$CMD2" > "$OUT/t6b.log" 2>&1
[ -d "$ROOT/opt/helloworld" ] && DRYOK=0
if [ "$DRYOK" == 1 ]; then
    say_ok "--dry-run 计划正确且未实际安装"
else
    say_bad "--dry-run 行为异常"; tail -20 "$OUT/t6.log"; tail -10 "$OUT/t6b.log"
fi

echo "-----------------------------------------"
echo "结果: $PASS 通过, $FAIL 失败"
echo "（真实 pacman 测试状态保留在 $OUT 便于排查）"
[ "$FAIL" -eq 0 ]