#!/usr/bin/env bash
# mock pacman: 用于无 root 环境下测试 alltap 安装自愈闭环
# 通过 MOCK_STATE 目录记状态; 通过 pkg 内 .PKGINFO 判断依赖与冲突文件
# 支持: -Si / -S / -U (单包或多包事务) / -T (依赖检查)
set -u
STATE="${MOCK_STATE:?需要 MOCK_STATE}"
mkdir -p "$STATE"
mkdir -p "$STATE/db"

ARGS=("$@")
SUB=""
PKG=""
PKGS=()          # -U 的全部包文件
HAS_OVERWRITE=0
LAST=""
SKIP_NEXT=0
for a in "${ARGS[@]}"; do
    if [[ "$SKIP_NEXT" == 1 ]]; then SKIP_NEXT=0; continue; fi
    case "$a" in
        -U|-S|-Si|-T) SUB="$a" ;;
        --overwrite) HAS_OVERWRITE=1 ;;
        --root|--dbpath|--config) SKIP_NEXT=1 ;;
        -*) ;;
        *) LAST="$a"; PKG="$a" ;;
    esac
    if [[ "$SUB" == "-U" && -f "$a" ]]; then
        PKGS+=("$a")
    fi
done

log() { echo "$*" >> "$STATE/calls.log"; }

# AUR helper (mock-yay) 已"装"过的依赖, 视为已满足
aur_installed() {
    grep -qx "$1" "$STATE/aur-install.log" 2>/dev/null
}

case "$SUB" in
    -Si)
        log "Si $LAST"
        case "$LAST" in
            fake-repo-dep*) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    -T)
        # mock 环境默认无已装包; 参数为依赖串, 原样报缺失 (去版本约束)
        MISSING=0
        for a in "${ARGS[@]}"; do
            case "$a" in
                -*|--*) ;;
                *) base="${a%%[<>=]*}"
                   if ! aur_installed "$base"; then echo "$base"; MISSING=1; fi ;;
            esac
        done
        [[ "$MISSING" == 1 ]] && exit 127 || exit 0
        ;;
    -S)
        log "S $*"
        for a in "${ARGS[@]}"; do
            case "$a" in fake-repo-dep*) echo "$a" >> "$STATE/asdeps.log" ;; esac
        done
        echo "==> mock: 已补装依赖"
        exit 0
        ;;
    -U)
        log "U ${PKGS[*]-$PKG} overwrite=$HAS_OVERWRITE"
        # 合并全部包的依赖/包名/文件
        ALL_DEPS=""
        ALL_NAMES=""
        ALL_FILES=""
        ORIG_DEPS=""
        for PKGF in ${PKGS[@]+"${PKGS[@]}"}; do
            INFO=$(zstd -dc "$PKGF" 2>/dev/null | bsdtar -xOf - .PKGINFO 2>/dev/null)
            ONE_DEPS=$(sed -n 's/^depend = //p' <<<"$INFO")
            ALL_DEPS+="$ONE_DEPS"$'\n'
            ORIG_DEPS+="$ONE_DEPS"$'\n'
            ALL_NAMES+=$(sed -n 's/^pkgname = //p' <<<"$INFO")$'\n'
            ALL_FILES+=$(zstd -dc "$PKGF" 2>/dev/null | bsdtar -tf - 2>/dev/null)$'\n'
        done
        # 依赖检查: 剔除同批包名可满足的 与 AUR 已装的
        MISSING_LIST=""
        for dep in $ALL_DEPS; do
            base="${dep%%[<>=]*}"
            if grep -qx "$base" <<<"$ALL_NAMES"; then continue; fi
            if aur_installed "$base"; then continue; fi
            if [[ "$base" == "nonexistent-dep-xyz" ]] || [[ "$base" == "aur-only-dep" ]]; then
                MISSING_LIST+="$dep "
            fi
            if [[ "$base" == "fake-repo-dep" ]] \
               && ! grep -qx "fake-repo-dep" "$STATE/asdeps.log" 2>/dev/null; then
                MISSING_LIST+="$dep "
            fi
        done
        if [[ -n "$MISSING_LIST" ]]; then
            echo "error: failed to prepare transaction (could not satisfy dependencies)"
            for dep in $MISSING_LIST; do
                echo ":: $(basename "${PKGS[0]:-$PKG}"): requires $dep"
            done
            exit 1
        fi
        # 文件冲突: 任一包含冲突文件且未 --overwrite
        if grep -qx "usr/bin/mockconflict" <<<"$ALL_FILES" && [[ "$HAS_OVERWRITE" == 0 ]]; then
            echo "error: failed to commit transaction (conflicting files)"
            echo "conflicttest: usr/bin/mockconflict exists in filesystem"
            exit 1
        fi
        echo "==> mock: 安装成功 ${PKGS[*]-$PKG}" | tee -a "$STATE/success.log"
        exit 0
        ;;
esac
echo "mock pacman: 未支持的命令 $SUB ${ARGS[*]}" >&2
exit 99
