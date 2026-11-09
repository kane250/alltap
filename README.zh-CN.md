# alltap

**把 (几乎) 所有 Linux 软件包转换成 Arch Linux 软件包** —— debtap 的全格式继任者。

[English](README.md) | [简体中文](README.zh-CN.md)

`debtap` 只能转 `.deb`；`alltap` 一个工具通吃：

| 输入格式 | 来源发行版 | 元数据提取 | 安装脚本移植 | 测试 |
|---|---|---|---|---|
| `.deb` | Debian / Ubuntu / Deepin / UOS 等 | control 字段全量 | preinst/postinst/prerm/postrm（含 deb 参数语义模拟） | ✓ |
| `.rpm` | Fedora / RHEL / openSUSE 等 | 纯 Python 解析 RPM header（gzip/xz/zstd payload） | %pre/%post/%preun/%postun + ldconfig | ✓（含 Fedora 官方真实包） |
| `.apk` | Alpine | `.PKGINFO` 全量 | 6 种 alpine 脚本一一对应 pacman | ✓ |
| `.tgz` / `.txz` | Slackware | slack-desc + 文件名 | doinst.sh | ✓ |
| `.AppImage` | 任意 | 文件名/ELF 架构探测 | — （重打包到 /opt） | ✓ |
| `.tar.gz` 等 | 任意归档 | 智能判定：含 `usr/` 等系统树→直接入包；否则装 `/opt` | — | ✓ |
| `.pkg.tar.zst` | Arch 自身 | `.PKGINFO` 全量 | 保留原 `.INSTALL` | ✓ |

## 安装

```bash
# 方式一: 直接安装 (脚本 + 映射数据库)
./install.sh                 # 默认装到 ~/.local/bin 与 ~/.local/share/alltap
sudo ./install.sh /usr/local # 装到系统路径

# 方式二: makepkg 安装 (Arch 系)
makepkg -f -d && sudo pacman -U alltap-*.pkg.tar.zst
```

依赖：`python3 ≥ 3.9`、`bsdtar`（libarchive，Arch 系自带）、`zstd`。
**RPM 解析不需要安装任何 rpm 工具**（内置纯 Python 解析器 + cpio(newc) 解包器）。

## 使用

```bash
alltap package.deb                    # 转出可直接 pacman -U 的 .pkg.tar.zst
alltap package.rpm                    # 同上 (Fedora/RHEL/openSUSE 包)
alltap tool.apk                       # Alpine 包
alltap foo-1.0-x86_64-1.txz           # Slackware 包
alltap CoolApp-2.5.AppImage -n coolapp # AppImage 重打包到 /opt/coolapp
alltap bundle-2.1.tar.xz              # 通用归档 (自动判定系统树/二进制归档)
alltap a.deb b.rpm c.apk              # 批量
alltap package.deb --no-prompt        # 只转换, 不询问安装
alltap package.deb -p                 # 仅生成 PKGBUILD (debtap 兼容模式)
alltap package.deb -o ~/pkgs          # 指定输出目录
alltap program.rpm -k                 # 保留无法翻译的依赖原名
alltap any.rpm -v 2.1-3               # 覆盖包版本 (全格式; 短选项 -v 与 debtap 兼容)
alltap app.tar.gz --prefix /usr/local # 无系统树的安装前缀 (默认 /opt/{pkgname}; -p 模式的 AppImage 亦生效)
alltap a.deb b.rpm -i                 # 转换后多包单事务安装 (依赖互相满足)
alltap a.deb b.rpm -i --dry-run       # 预演: 输出安装计划, 不实际执行
alltap a.deb -i --aur                 # 缺失依赖时查询 AUR, 确认后 yay/paru 补装
alltap --version                      # 显示 alltap 版本 (-V 等价)
alltap --refresh                      # 刷新 Arch 仓库包名缓存
```

输出直接平铺在 `-o` 目录（默认当前目录），不再为每个包建 `<pkgname>/` 子目录：

```
<pkgname>-<ver>-<rel>-<arch>.pkg.tar.zst   # 成品包
alltap-report-<pkgname>.txt                # 依赖翻译记录
alltap-plan.txt                            # (--dry-run 时) 安装计划
```

同包重复转换默认跳过（提示已存在），`-f` 覆盖。

成品包按 makepkg 等价流程构造（`.PKGINFO` + `.MTREE` + 可选 `.INSTALL`，GNU tar 格式 + zstd 压缩，文件归一化为 root 归属），`pacman -U` 直接安装。

## 安装自愈闭环（`-i`）

转换只是第一步——第三方包装不上，多半卡在依赖与文件冲突。缺省行为是：**先转换，完成后询问「是否安装？」**（仅在交互终端询问；管道、脚本、`-q` 自动跳过，回车即放弃）。`-i` 表示跳过询问直接安装，并按失败原因自动修复、循环重试。**多包时为单一事务**：一次 `pacman -U app1.pkg app2.pkg ...`，同批包之间的互相依赖由 pacman 同事务自动满足，避免逐包安装时"A 依赖 B 而 B 尚未装"的顺序性失败：

```
解包+解析 ──▶ 依赖映射 ──▶ .pkg.tar.zst ────▶ pacman -U (多包单事务)
   ×N 批量                       │                        │
                                 │        失败: 缺依赖 ◀──┘
                                 │          ├─ 同批包提供 → 版本不符时放宽约束重打包
                                 │          ├─ 仓库有 → pacman -S --asdeps 补装
                                 │          ├─ 仓库无 → (--aur) 查 AUR → yay/paru 补装
                                 │          │            └─ 否则询问改名 / 移除 → 重打包受影响包
                                 │          └─ 文件冲突 → --overwrite 精确覆盖
                                 └──────(循环，直至成功或达上限)
```

```bash
alltap foo.deb -i                  # 转换后自动安装, 失败自动修复
alltap foo.deb foo.rpm -i          # 多包单事务安装, 依赖互相满足
alltap foo.deb -i -y               # 全自动 (补依赖/移除未知依赖/覆盖冲突都不再询问)
alltap foo.rpm -i --max-tries 8    # 提高重试上限 (默认 5)
alltap foo.deb -i --no-autodeps    # 不允许自动补装仓库依赖 (只报告)
alltap foo.deb -i --no-overwrite   # 不允许自动处理文件冲突
alltap foo.deb -i --aur            # 仓库缺失的依赖查询 AUR, 确认后 yay/paru 补装
alltap foo.deb -i --dry-run        # 只输出安装计划, 不实际执行
```

修复策略细节：

| 失败类型 | 判定 | 处理 | 保护 |
|---|---|---|---|
| 缺依赖 · 仓库有 | `pacman -Si` 命中 | `pacman -S --asdeps --noconfirm` 补装后重试 | `--no-autodeps` 可禁用 |
| 缺依赖 · 仓库无 | `pacman -Si` 未命中 | `--aur` 时先查 AUR（显示版本/维护者/票数），确认后 yay/paru 补装；否则交互询问：移除 / 改名 / 放弃，仅重打包受影响的包 | 非交互环境默认拒绝；AUR 从源码构建需显式确认；`-y` 自动移除 |
| 依赖指向同批包但版本不符 | 依赖名与本批包名/`provides` 重合 | 去掉版本约束重打包该包 | 同一依赖只放宽一次 |
| 依赖版本过严 | 同名依赖补装后仍报缺 | 自动去掉版本约束重新打包 | 日志明示放宽了哪一条 |
| 文件冲突 | `xxx exists in filesystem` | 收集精确路径，`--overwrite <path>` 逐路径覆盖后重试 | **绝不使用 `*` 通配**；`--no-overwrite` 可禁用 |
| 破坏其他包依赖 | `breaks dependency ... required by ...` | 报告冲突关系后停止 | 不自动卸载他人依赖 |

### AUR 依赖兜底（`--aur`）

仓库翻译不出对应包时（典型如 Ubuntu 专用小库名），`--aur` 会查询 [AUR RPC](https://aur.archlinux.org/rpc) 接口：

- 找到则显示**版本、维护者、票数、是否过期**，确认后用 `paru`/`yay -S --asdeps` 补装（本机需已装其一），再循环重试安装；
- 找不到或网络不可达时自动回落到改名/移除询问流程；
- AUR 包需从源码构建、耗时且属第三方代码，因此**必须显式确认**（`-y` 且 `--aur` 同时给出才视为同意）。

### 安装计划预演（`--dry-run`）

先审后装：转换后不执行任何安装，输出完整计划并写入 `<输出目录>/alltap-plan.txt`：

- **依赖求解**：`pacman -T` 检查当前系统 → 哪些已满足 / 将从仓库补装 / 由同批包互相提供 / 仓库无（需决断）；
- **文件冲突预检**：将各包文件清单与 pacman 本地数据库已登记文件比对，列出将被 `--overwrite` 覆盖的文件及其归属包（不属于任何包的散落文件无法静态预检，以实际安装为准）；
- **维护脚本提醒**：哪些包携带 `.INSTALL` 将以 root 执行。

补充说明：

- `-i` / `--dry-run` 模式会自动**保留未识别依赖的原名**（普通转换模式才默认剔除），否则安装闭环无从判定；翻译失败的依赖会原样送交 pacman 判定。
- 需要 root：以 root 运行时直接执行；普通用户优先 `sudo -n`（免密），否则用 `pkexec` 图形认证弹窗；`-T`/`-Si` 等只读查询不提权。
- 所有 pacman 调用强制 `LC_ALL=C` 解析英文输出；重试上限后停止，已生成的包文件与 `alltap-report-<pkgname>.txt` 完整保留。
- 测试用隔离通道（不影响正常使用）：`ALLTAP_PACMAN`（替换 pacman 可执行）、`ALLTAP_PACMAN_ROOT`（`--root` 隔离根）、`ALLTAP_PACMAN_EXTRA`（附加参数）、`ALLTAP_NO_SUDO=1`（跳过提权）、`ALLTAP_AUR_RPC`（AUR RPC URL 模板，`{name}` 占位，`file://` 可离线 mock）、`ALLTAP_AUR_HELPER`（替换 yay/paru 命令）。

## 依赖翻译原理

三层策略（`data/dep-map.conf` 约 750 条规则 + 内嵌兜底子集）：

1. **精确映射**：`libc6 => glibc`、`openssl-libs => openssl`、`libssh2.so.1 => libssh2` 等手写规则，覆盖 deb 包名 / rpm soname / SPDX 许可证别名；
2. **本地仓库匹配**：解析名（或剥去 soname 数字、`-dev`/`-devel` 后缀、`lib` 前缀后的变体）与 `pacman -Slq` 的官方包名比对；
3. **正则规则**：`libllvm14 → llvm-libs`、`libicu72 → icu`、`libboost_* → boost-libs` 等。

无法翻译的依赖默认剔除并在末尾汇总提示（`-k` 保留原名）；发行版基础设施依赖（`debconf`、`dpkg`、`rpmlib(...)`、`config(...)`、`/bin/sh`、含 GLIBC 版本标记的 soname 等）自动丢弃。deb 的 `Recommends` 转 `optdepends`，`Breaks` 并入 `conflicts`，rpm 的 `Obsoletes` 转 `replaces`，版本约束符号（`<<`/`>>`/`>=` 等）逐一映射为 pacman 语法。

**维护脚本移植**：deb 脚本会注入 `set -- configure/install/...` 模拟 Debian 参数语义；rpm 脚本按 `$1 = 1/2/0` 模拟安装/升级/卸载；`%post -p /sbin/ldconfig` 自动转成 `ldconfig` 调用；alpine 的 6 种脚本与 pacman 语义一一对应。

## 已知局限

- 转换不保证语义 100% 等价：维护脚本参数语义为近似模拟，`pre/posttrans` 无 pacman 等价物（自动忽略并告警）；
- RPM 的范围依赖（`<>`）在 pacman 中降级为无版本依赖；
- 极新/冷门依赖名可能翻译失败，请查 `alltap-report-<pkgname>.txt` 并按需手工补包或向 `data/dep-map.conf` 提交规则；
- 未经审计的第三方包存在安全风险，安装前建议 `pacman -Qlp` 检查内容。

## 开发与测试

```bash
bash tests/run-tests.sh          # 转换回归: 7 种格式 + PKGBUILD + 重打包 + 6 项回归 (16/16)
bash tests/test-install-mock.sh  # 安装闭环 mock 测试: 10 个场景 (含多包事务/AUR/dry-run)
bash tests/test-install-real.sh  # 真实 pacman 隔离测试 (unshare + 临时 root, 6/6)
python3 tests/build-fixtures.py  # 单独重建全部测试样例 (16 个)
```

测试样例均为程序化构造（含手工构造的合法 RPM/cpio 流、ar 归档、.PKGINFO），外加 Fedora 官方仓库下载的真实 hello RPM。

CI 在每次 push 时自动运行全部三套测试——见 [`.github/workflows/ci.yml`](.github/workflows/ci.yml)。

mock 测试覆盖场景：未知依赖自动移除（A）、仓库依赖补装（B）、文件冲突精确覆盖（C）、`--no-autodeps`（D）、`--no-overwrite`（E）、重试上限（F）、**多包事务同批依赖互满足（G）**、**AUR 兜底补装（H）**、**`--dry-run` 计划输出且不安装（I）**、**`--dry-run` 文件冲突预检（J）**；真实 pacman 测试另含**多包互赖单事务安装**与 **dry-run 不落地**验证；AUR 依赖在 AUR 与 yay/paru 均有的条件下才会真正安装。

## 与 debtap 的差异

| | debtap | alltap |
|---|---|---|
| 支持格式 | 仅 .deb | deb/rpm/apk/tgz/AppImage/tarball/archpkg |
| RPM 解析 | ✗ | 纯 Python（零外部依赖，支持 zstd payload） |
| 打包 | 交互式 + makepkg | 一键直出（makepkg 等价构造）+ `-p` 模式 |
| 依赖数据库 | 手动 `-u` 联网更新 | 本地 pacman 仓库 + 内置映射，免联网 |
| 交互性 | 每个包多次问答 | 默认无交互，`-k`/`--no-scripts` 可控 |
| 安装体验 | 无 | 多包单事务 `-i` + AUR 兜底 `--aur` + 预演 `--dry-run` |

## 许可

GPL-3.0-or-later
