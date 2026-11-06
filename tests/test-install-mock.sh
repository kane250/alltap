#!/usr/bin/env bash
# 安装闭环 mock 测试: 精确控制 pacman 失败场景 (无需 root)
set -u
cd "$(dirname "$0")/.."
PROJ="$PWD"
OUT=$(mktemp -d /tmp/alltap-it-XXXXXX)
export ALLTAP_NO_SUDO=1
export ALLTAP_PACMAN="$PROJ/tests/mock-pacman.sh"
PASS=0; FAIL=0

ok()  { echo "✓ $*"; PASS=$((PASS+1)); }
bad() { echo "✗ $*"; FAIL=$((FAIL+1)); }

runtest() {  # runtest <名称> <fixture> <输出目录名> <额外参数...>
    local name="$1" fixture="$2" tag="$3"; shift 3
    rm -rf "$OUT/$tag" "$OUT/state-$tag"
    MOCK_STATE="$OUT/state-$tag" ./alltap "$fixture" -o "$OUT/$tag" -i -y --max-tries 4 "$@" 2>&1
}

echo "=== alltap 安装闭环 mock 测试 $(date '+%F %T') ==="

# ---- A: 未知依赖 -> 移除 -> 重打包 -> 成功 ----
LOG=$(runtest "未知依赖" tests/fixtures/installtest_1.0_amd64.deb a)
if grep -q "仓库中找不到依赖" <<<"$LOG" && grep -q "已移除上述依赖" <<<"$LOG" \
   && grep -q "✓ 安装成功" <<<"$LOG" \
   && grep -q "Si nonexistent-dep-xyz" "$OUT/state-a/calls.log"; then
    ok "A. 未知依赖 -> 自动移除 -> 重打包 -> 安装成功"
else
    bad "A. 未知依赖修复失败"; echo "$LOG" | tail -8
fi

# ---- B: 仓库有依赖 -> pacman -S --asdeps 补装 -> 成功 ----
LOG=$(runtest "仓库依赖" tests/fixtures/repodep_1.0_amd64.deb b)
if grep -q "已补装依赖: fake-repo-dep" <<<"$LOG" && grep -q "✓ 安装成功" <<<"$LOG" \
   && grep -qx "fake-repo-dep" "$OUT/state-b/asdeps.log" 2>/dev/null; then
    ok "B. 仓库内缺失依赖 -> --asdeps 补装 -> 安装成功"
else
    bad "B. 仓库依赖补装失败"; echo "$LOG" | tail -8
fi

# ---- C: 文件冲突 -> --overwrite 精确覆盖 -> 成功 ----
LOG=$(runtest "文件冲突" tests/fixtures/conflicttest_1.0_amd64.deb c)
if grep -q "检测到文件冲突 1 个" <<<"$LOG" && grep -q "✓ 安装成功" <<<"$LOG" \
   && grep -q "overwrite=1" "$OUT/state-c/calls.log"; then
    ok "C. 文件冲突 -> --overwrite 精确覆盖 -> 安装成功"
else
    bad "C. 文件冲突修复失败"; echo "$LOG" | tail -8
fi

# ---- D: --no-autodeps 禁止补装 ----
LOG=$(runtest "禁用补装" tests/fixtures/repodep_1.0_amd64.deb d --no-autodeps)
if grep -q "已禁用自动补装" <<<"$LOG"; then
    ok "D. --no-autodeps 生效 (拒绝自动补装)"
else
    bad "D. --no-autodeps 未生效"; echo "$LOG" | tail -8
fi

# ---- E: --no-overwrite 禁止冲突覆盖 ----
LOG=$(runtest "禁用覆盖" tests/fixtures/conflicttest_1.0_amd64.deb e --no-overwrite)
if grep -q "已禁用文件覆盖" <<<"$LOG"; then
    ok "E. --no-overwrite 生效 (拒绝覆盖文件)"
else
    bad "E. --no-overwrite 未生效"; echo "$LOG" | tail -8
fi

# ---- F: 重试上限 ----
LOG=$(runtest "上限" tests/fixtures/installtest_1.0_amd64.deb f --max-tries 1 --no-autodeps 2>/dev/null)
# 上限场景: 未知依赖会被移除, 用 1 轮 -y 时也能成功; 这里验证 --max-tries 参数被接受
if grep -q "\[安装 1/1\]" <<<"$LOG"; then
    ok "F. --max-tries 轮数控制生效"
else
    bad "F. --max-tries 未生效"; echo "$LOG" | tail -5
fi

# ---- G: 多包事务: 依赖由同批包互相满足, 一次 -U 成功 ----
rm -rf "$OUT/g" "$OUT/state-g"
LOG=$(MOCK_STATE="$OUT/state-g" ./alltap tests/fixtures/multia_1.0_amd64.deb tests/fixtures/multib_2.1_amd64.deb \
      -o "$OUT/g" -i -y --max-tries 4 2>&1)
U_LINE=$(grep -E "^U " "$OUT/state-g/calls.log" | head -1)
if grep -q "依赖 multib 由同批包提供" <<<"$LOG" \
   && grep -q "✓ 安装成功" <<<"$LOG" \
   && grep -q "multia" <<<"$U_LINE" && grep -q "multib" <<<"$U_LINE" \
   && [ "$(grep -cE '^U ' "$OUT/state-g/calls.log")" -eq 1 ] \
   && grep -q "mock: 安装成功" "$OUT/state-g/success.log"; then
    ok "G. 多包事务: 同批依赖互满足, 单次 -U 安装成功"
else
    bad "G. 多包事务失败"; echo "$LOG" | tail -12; echo "calls: $(cat "$OUT/state-g/calls.log" 2>/dev/null)"
fi

# ---- H: AUR 兜底: 仓库无依赖 -> AUR 查到 -> mock-yay 补装 -> 成功 ----
rm -rf "$OUT/h" "$OUT/state-h"
mkdir -p "$OUT/h-aur"
cat > "$OUT/h-aur/aur-aur-only-dep.json" <<'JSON'
{"version":5,"type":"multiinfo","resultcount":1,"results":[{"ID":123456,"Name":"aur-only-dep","Version":"1.2.3-1","Maintainer":"someone","NumVotes":12,"OutOfDate":null}]}
JSON
LOG=$(MOCK_STATE="$OUT/state-h" \
      ALLTAP_AUR_RPC="file://$OUT/h-aur/aur-{name}.json" \
      ALLTAP_AUR_HELPER="bash $PROJ/tests/mock-yay.sh" \
      ./alltap tests/fixtures/aurapp_1.0_amd64.deb -o "$OUT/h" -i -y --aur --max-tries 4 2>&1)
if grep -q "下列依赖在 AUR 存在" <<<"$LOG" \
   && grep -q "aur-only-dep  (版本 1.2.3-1" <<<"$LOG" \
   && grep -q "已通过 AUR 补装: aur-only-dep" <<<"$LOG" \
   && grep -qx "aur-only-dep" "$OUT/state-h/aur-install.log" 2>/dev/null \
   && grep -q "✓ 安装成功" <<<"$LOG"; then
    ok "H. AUR 兜底: 查询 -> 补装 -> 安装成功"
else
    bad "H. AUR 兜底失败"; echo "$LOG" | tail -15
fi

# ---- I: --dry-run 预演: 输出计划但不安装 ----
rm -rf "$OUT/i" "$OUT/state-i"
LOG=$(MOCK_STATE="$OUT/state-i" ./alltap tests/fixtures/multia_1.0_amd64.deb tests/fixtures/multib_2.1_amd64.deb \
      -o "$OUT/i" --dry-run 2>&1)
if grep -q "由同批包互相提供 (同一 pacman -U 事务自动满足): multib" <<<"$LOG" \
   && [ -f "$OUT/i/alltap-plan.txt" ] \
   && grep -q "待安装包 (2 个)" <<<"$LOG" \
   && ! grep -qE "^U " "$OUT/state-i/calls.log" 2>/dev/null; then
    ok "I. --dry-run 输出安装计划且未实际安装"
else
    bad "I. --dry-run 异常"; echo "$LOG" | tail -15
fi

# ---- J: --dry-run 文件冲突预检 (对照隔离根本地数据库) ----
rm -rf "$OUT/j" "$OUT/state-j" "$OUT/j-root"
mkdir -p "$OUT/j-root/var/lib/pacman/local/preowner-1.0-1"
printf '%%FILES%%\nusr/\nusr/bin/\nusr/bin/mockconflict\n' > "$OUT/j-root/var/lib/pacman/local/preowner-1.0-1/files"
LOG=$(MOCK_STATE="$OUT/state-j" ALLTAP_PACMAN_ROOT="$OUT/j-root" \
      ./alltap tests/fixtures/conflicttest_1.0_amd64.deb -o "$OUT/j" --dry-run 2>&1)
if grep -q "文件冲突预检: 1 个文件已被其它包占用" <<<"$LOG" \
   && grep -q "usr/bin/mockconflict.*preowner" <<<"$LOG" \
   && ! grep -qE "^U " "$OUT/state-j/calls.log" 2>/dev/null; then
    ok "J. --dry-run 文件冲突预检命中"
else
    bad "J. 冲突预检异常"; echo "$LOG" | tail -15
fi

echo "-----------------------------------------"
echo "结果: $PASS 通过, $FAIL 失败"
rm -rf "$OUT"
[ "$FAIL" -eq 0 ]