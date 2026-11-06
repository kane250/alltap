#!/usr/bin/env bash
# alltap 回归测试: 全格式转换 + pacman 认证
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT=$(mktemp -d)
chmod 755 "$OUT"   # root 容器中 nobody 构建需要穿透中间目录
PASS=0; FAIL=0

# 1. 生成 fixtures (幂等)
python3 tests/build-fixtures.py > /dev/null || { echo "✗ fixtures 生成失败"; exit 1; }

run() {  # run <fixture路径> <期望包名>
    local fixture="$1" want="$2"
    rm -rf "$OUT/$want"
    if ! ./alltap "$fixture" -o "$OUT" -q 2>/dev/null; then
        echo "✗ $want 转换失败"; FAIL=$((FAIL+1)); return
    fi
    local pkg
    pkg=$(ls "$OUT/$want/"*.pkg.tar.zst 2>/dev/null | head -1)
    [ -z "$pkg" ] && { echo "✗ $want 未产出 pkg.tar.zst"; FAIL=$((FAIL+1)); return; }
    if pacman -Qp "$pkg" > /dev/null 2>&1; then
        echo "✓ $(basename "$fixture")  ->  $(basename "$pkg")  [pacman 认证通过]"; PASS=$((PASS+1))
    else
        echo "✗ $pkg pacman -Qp 不认可"; FAIL=$((FAIL+1))
    fi
}

echo "=== alltap 回归测试 $(date '+%F %T') ==="
run tests/fixtures/alltapdemo_1.4-2ubuntu1_amd64.deb   alltapdemo
run tests/fixtures/rpmdemo-3.7.2-1.el9.x86_64.rpm      rpmdemo
run tests/hello-2.12.3-1.fc44.x86_64.rpm               hello
run tests/fixtures/alpinedemo-5.0.1-r2.apk             alpinedemo
run tests/fixtures/slackdemo-2.2.0-x86_64-3.tgz        slackdemo
run tests/fixtures/CoolApp-2.5.AppImage                coolapp
run tests/fixtures/helloworld-1.0.tar.gz               helloworld
run tests/fixtures/topdir-usr-tree.tar.gz              myapp


# 仅校验 PKGBUILD 语法/变量 (不打包), 同样规避 root 限制
mkpkg_srcinfo() {
    local d="$1"
    if [ "$(id -u)" = "0" ]; then
        chown -R nobody: "$d" 2>/dev/null || chmod -R a+rwX "$d"
        ( cd "$d" && runuser -u nobody -- env HOME=/tmp makepkg --printsrcinfo > /dev/null 2>&1 )
    else
        ( cd "$d" && makepkg --printsrcinfo > /dev/null 2>&1 )
    fi
}

# ---- P1 回归 ----
# 1) 顶层目录本身就是 usr/ 时不得被当作包装层剥掉
rm -rf "$OUT/usrdemo"
if ./alltap tests/fixtures/usr-tree.tar.gz -n usrdemo -o "$OUT" -q 2>/dev/null \
   && bsdtar -tf "$OUT/usrdemo/"*.pkg.tar.zst 2>/dev/null | grep -qx 'usr/bin/usrdemo'; then
    echo "✓ tarball 顶层 usr/ 路径保留"; PASS=$((PASS+1))
else
    echo "✗ tarball 顶层 usr/ 路径被剥离"; FAIL=$((FAIL+1))
fi

# 2) 无系统树 + 自定义 prefix 不得出现 "move into itself"
rm -rf "$OUT/plaindemo"
if ./alltap tests/fixtures/plain-tree.tar.gz -n plaindemo \
      --prefix '/usr/local/{pkgname}' -o "$OUT" -q 2>/dev/null \
   && bsdtar -tf "$OUT/plaindemo/"*.pkg.tar.zst 2>/dev/null | grep -qx 'usr/local/plaindemo/readme.txt'; then
    echo "✓ tarball 自定义 prefix 安装路径正确"; PASS=$((PASS+1))
else
    echo "✗ tarball 自定义 prefix 失败"; FAIL=$((FAIL+1))
fi

# 3) 带 epoch 的包: PKGBUILD 必须用独立 epoch 变量, pkgver 不得含冒号
rm -rf "$OUT/epochpb"
if ./alltap tests/fixtures/epochdemo_2.0-3_amd64.deb -o "$OUT/epochpb" -p -q 2>/dev/null \
   && grep -qx "epoch='1'" "$OUT/epochpb/epochdemo/PKGBUILD" \
   && grep -qx "pkgver='2.0'" "$OUT/epochpb/epochdemo/PKGBUILD" \
   && grep -qx "options=('!strip' '!debug')" "$OUT/epochpb/epochdemo/PKGBUILD" \
   && mkpkg_srcinfo "$OUT/epochpb/epochdemo"; then
    echo "✓ PKGBUILD epoch/options 正确且通过 makepkg 校验"; PASS=$((PASS+1))
else
    echo "✗ PKGBUILD epoch 处理失败"; FAIL=$((FAIL+1))
fi

# 4) AppImage 的 PKGBUILD 安装路径跟随 --prefix
rm -rf "$OUT/appipb"
if ./alltap tests/fixtures/CoolApp-2.5.AppImage -n coolapp \
      --prefix '/opt/custom/{pkgname}' -o "$OUT/appipb" -p -q 2>/dev/null \
   && grep -q '/opt/custom/coolapp/coolapp.AppImage' "$OUT/appipb/coolapp/PKGBUILD"; then
    echo "✓ PKGBUILD AppImage 前缀生效"; PASS=$((PASS+1))
else
    echo "✗ PKGBUILD AppImage 前缀未生效"; FAIL=$((FAIL+1))
fi

# PKGBUILD 模式
# makepkg 拒绝以 root 运行; 在 CI 容器 (默认 root) 中降权到 nobody 执行
mkpkg() {
    local d="$1" rc
    if [ "$(id -u)" = "0" ]; then
        chown -R nobody: "$d" 2>/dev/null || chmod -R a+rwX "$d"
        ( cd "$d" && runuser -u nobody -- env HOME=/tmp makepkg -f -d > "$OUT/makepkg.log" 2>&1 )
        rc=$?
    else
        ( cd "$d" && makepkg -f -d > "$OUT/makepkg.log" 2>&1 )
        rc=$?
    fi
    if [ "$rc" != 0 ]; then
        echo "---- makepkg 失败日志 (uid=$(id -u)) ----"
        tail -30 "$OUT/makepkg.log"
        echo "------------------------------------------"
    fi
    return $rc
}
rm -rf "$OUT/pbmode"
if ./alltap tests/fixtures/alltapdemo_1.4-2ubuntu1_amd64.deb -o "$OUT/pbmode" -p -q 2>/dev/null \
   && [ -f "$OUT/pbmode/alltapdemo/PKGBUILD" ]; then
    mkpkg "$OUT/pbmode/alltapdemo" || true
    if ls "$OUT/pbmode/alltapmode"/*.pkg.tar.zst > /dev/null 2>&1; then :; fi
    if ls "$OUT/pbmode/alltapdemo"/*.pkg.tar.zst > /dev/null 2>&1 \
       && pacman -Qp "$OUT/pbmode/alltapdemo"/*.pkg.tar.zst > /dev/null 2>&1; then
        echo "✓ PKGBUILD 模式 (makepkg 可打包)"; PASS=$((PASS+1))
    else
        echo "✗ PKGBUILD 模式 makepkg 失败"; FAIL=$((FAIL+1))
    fi
    rm -f "$OUT/pbmode/alltapdemo"/*.pkg.tar.zst
else
    echo "✗ PKGBUILD 生成失败"; FAIL=$((FAIL+1))
fi

# Arch 包重打包
firstpkg=$(ls "$OUT/alltapdemo/"*.pkg.tar.zst | head -1)
if ./alltap "$firstpkg" -o "$OUT/repack" -q 2>/dev/null \
   && pacman -Qp "$OUT/repack/alltapdemo/"*.pkg.tar.zst > /dev/null 2>&1; then
    echo "✓ Arch 包重打包"; PASS=$((PASS+1))
else
    echo "✗ Arch 包重打包失败"; FAIL=$((FAIL+1))
fi

echo "-----------------------------------------"
echo "结果: $PASS 通过, $FAIL 失败"
rm -rf "$OUT"
[ "$FAIL" -eq 0 ]
