#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 alltap 的全套测试样例 (自制 deb / rpm / apk / slackware / AppImage / tarball)"""
import gzip
import io
import os
import struct
import tarfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
os.makedirs(FIX, exist_ok=True)


def add_to_tar(tf: tarfile.TarFile, arcname, content: bytes, mode=0o644):
    ti = tarfile.TarInfo(arcname)
    ti.size = len(content)
    ti.mtime = 1700000000
    ti.mode = mode
    tf.addfile(ti, io.BytesIO(content))


# =====================================================================
# 1. 自制 .deb
# =====================================================================
def make_deb():
    control = """Package: alltapdemo
Version: 1.4-2ubuntu1
Architecture: amd64
Maintainer: Test Maker <t@example.com>
Homepage: https://alltap.example.com
Depends: libc6 (>= 2.34), libssl3 (>= 3.0.8), libxml2, debconf (>= 1.5) | dialog, libtinfo6 (>= 6.3)
Pre-Depends: libgcc-s1
Recommends: curl
Suggests: htop
Conflicts: alltapdemo-old
Replaces: alltapdemo-old
Provides: alltap-demo-virtual
Description: 演示用 Debian 包 (alltap test)
 这是一个长描述, 验证多行
 Description 的解析能力。

""".encode("utf8")
    postinst = b"""#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  echo "alltapdemo postinst: configured OK, arg=$1"
fi
exit 0
"""
    # control.tar.gz
    cbuf = io.BytesIO()
    with tarfile.open(fileobj=cbuf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        add_to_tar(tf, "./control", control)
        add_to_tar(tf, "./postinst", postinst, mode=0o755)
    # data.tar.gz
    dbuf = io.BytesIO()
    with tarfile.open(fileobj=dbuf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        add_to_tar(tf, "./usr/bin/alltapdemo",
                   b"#!/bin/sh\necho 'I am alltapdeb'\n", mode=0o755)
        add_to_tar(tf, "./usr/share/doc/alltapdemo/README", b"demo deb package made by alltap test suite\n")
        add_to_tar(tf, "./usr/share/doc/alltapdemo/changelog.gz", b"\x1f\x8b" + b"0" * 32)

    def ar_member(name, blob):
        name = name.ljust(16).encode()[:16]
        hdr = name + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6) + b"100644".ljust(8)
        hdr += str(len(blob)).encode().ljust(10) + b"`\n"
        pad = b"\n" if len(blob) & 1 else b""
        return hdr + blob + pad

    deb = b"!<arch>\n"
    deb += ar_member("debian-binary", b"2.0\n")
    deb += ar_member("control.tar.gz", cbuf.getvalue())
    deb += ar_member("data.tar.gz", dbuf.getvalue())
    p = os.path.join(FIX, "alltapdemo_1.4-2ubuntu1_amd64.deb")
    open(p, "wb").write(deb)
    return p


# =====================================================================
# 2. 自制 .rpm (纯手工构造: lead + 签名 header + 主 header + gzip cpio)
# =====================================================================
RPM_TAG_TYPES = {"NAME": 6, "VERSION": 6, "RELEASE": 6, "EPOCH": 4, "SUMMARY": 9,
                 "DESCRIPTION": 9, "LICENSE": 6, "URL": 6, "ARCH": 6,
                 "PREIN": 6, "POSTIN": 6, "PREUN": 6, "POSTUN": 6,
                 "PROVIDENAME": 8, "PROVIDEFLAGS": 4, "PROVIDEVERSION": 8,
                 "REQUIRENAME": 8, "REQUIREFLAGS": 4, "REQUIREVERSION": 8,
                 "CONFLICTNAME": 8, "CONFLICTFLAGS": 4, "CONFLICTVERSION": 8,
                 "OBSOLETENAME": 8, "OBSOLETEFLAGS": 4, "OBSOLETEVERSION": 8,
                 "PAYLOADFORMAT": 6, "PAYLOADCOMPRESSOR": 6, "PAYLOADFLAGS": 6,
                 "PREINPROG": 8, "POSTINPROG": 8, "SOURCERPM": 6}
TAG = {"NAME": 1000, "VERSION": 1001, "RELEASE": 1002, "EPOCH": 1003, "SUMMARY": 1004,
       "DESCRIPTION": 1005, "LICENSE": 1014, "URL": 1020, "ARCH": 1022,
       "PREIN": 1023, "POSTIN": 1024, "PREUN": 1025, "POSTUN": 1026,
       "SOURCERPM": 1044, "PROVIDENAME": 1047, "REQUIREFLAGS": 1048,
       "REQUIRENAME": 1049, "REQUIREVERSION": 1050,
       "CONFLICTFLAGS": 1053, "CONFLICTNAME": 1054, "CONFLICTVERSION": 1055,
       "PREINPROG": 1085, "POSTINPROG": 1086,
       "OBSOLETENAME": 1090, "PROVIDEFLAGS": 1112, "PROVIDEVERSION": 1113,
       "OBSOLETEFLAGS": 1114, "OBSOLETEVERSION": 1115,
       "PAYLOADFORMAT": 1124, "PAYLOADCOMPRESSOR": 1125, "PAYLOADFLAGS": 1126}


def build_header(entry_list):
    """entry_list: [(name, value)] 按类型序列化"""
    index, store = [], b""
    for nm, val in entry_list:
        typ = RPM_TAG_TYPES[nm]
        if typ == 6:
            blob = val.encode() + b"\0"
            cnt = 1
        elif typ in (8, 9):
            blob = b"".join(v.encode() + b"\0" for v in val)
            cnt = len(val)
        elif typ == 4:
            align = (4 - len(store) % 4) % 4
            store += b"\0" * align
            blob = struct.pack(f">{len(val)}i", *val)
            cnt = len(val)
        elif typ == 7:
            blob = val
            cnt = len(val)
        else:
            raise ValueError(type)
        index.append(struct.pack(">IIII", TAG[nm], typ, len(store), cnt))
        store += blob
    # 计数 index 在 store 之前
    hdr = b"\x8e\xad\xe8\x01\x01\x00\x00\x00" + struct.pack(">II", len(index), len(store))
    hdr += b"".join(index) + store
    return hdr


def cpio_newc(entries):
    """entries: [(path, mode, data)]  其中 path 以 '/' 分隔; 目录条目 mode 传 0o40755,
    符号链接条目 mode 传 0o121077, 其 data 为链接目标"""
    out = io.BytesIO()
    ino = 1

    def w_entry(name, mode, data=b""):
        nonlocal ino
        isdir = (mode & 0o170000) == 0o040000
        islink = (mode & 0o170000) == 0o120000
        if islink:
            nlink, mode = 1, 0o120777
        elif isdir:
            nlink, mode = 2, 0o040755
        else:
            nlink, mode = 1, mode | 0o100000
        # newc 无符号 16 进制字段严格 13 个: ino mode uid gid nlink mtime
        # filesize devmajor devminor rdevmajor rdevminor namesize check
        fields = [ino, mode, 0, 0, nlink, 1700000000, len(data), 1, 3, 0, 0,
                  len(name) + 1, 0]
        hdr = b"070701" + b"".join(b"%08X" % f for f in fields)
        ns = name.encode()
        buf = hdr + ns + b"\0"
        buf += b"\0" * ((4 - len(buf) % 4) % 4)
        buf += data
        buf += b"\0" * ((4 - len(data) % 4) % 4)
        out.write(buf)
        ino += 1

    for path, mode, data in entries:
        w_entry(path, mode, data.encode() if isinstance(data, str) else data)
    w_entry("TRAILER!!!", 0)
    out.write(b"\0" * ((512 - out.tell() % 512) % 512))
    return out.getvalue()


def make_rpm():
    payload = cpio_newc([
        ("usr", 0o040755, b""),
        ("usr/bin", 0o040755, b""),
        ("usr/bin/rpmdemo", 0o100755, b"#!/bin/sh\necho rpm-demo-ok\n"),
        ("usr/share", 0o040755, b""),
        ("usr/share/doc", 0o040755, b""),
        ("usr/share/doc/rpmdemo", 0o040755, b""),
        ("usr/share/doc/rpmdemo/README", 0o100644, b"test rpm built for alltap\n"),
        ("usr/lib64", 0o040755, b""),
        ("usr/lib64/rpmdemo-so", 0o120777, "rpmdemo"),
    ])
    gz = gzip.compress(payload)
    # rpm 版依赖: zlib(>=1.2.3 精确 EQUAL), soname libz.so.1()(64bit), 虚拟 rpmlib, 普通名 bash, glibc
    req_names = ["rpmlib(CompressedFileNames)", "rtld(GNU_HASH)", "/bin/sh",
                 "libz.so.1()(64bit)", "libc.so.6(GLIBC_2.34)(64bit)",
                 "zlib", "bash", "coreutils-common", "openssl-libs", "ca-certificates"]
    # flags: LESS=2 GREATER=4 EQUAL=8
    req_flags = [0, 0, 0, 0, 0, 8, 0, 0, 4, 0]
    req_vers = ["", "", "", "", "", "1.2.12", "", "", "3.0.2", ""]

    entries = [
        ("NAME", "rpmdemo"),
        ("VERSION", "3.7.2"),
        ("RELEASE", "1.el9"),
        ("SUMMARY", ["Alltap 演示 RPM"]),
        ("DESCRIPTION", ["这是用于测试的 RPM 包\n包含中文描述与多行文本。"]),
        ("LICENSE", "GPLv3+"),
        ("URL", "https://rpm.demo.example.com"),
        ("ARCH", "x86_64"),
        ("REQUIRENAME", req_names),
        ("REQUIREFLAGS", req_flags),
        ("REQUIREVERSION", req_vers),
        ("PROVIDENAME", ["rpmdemo", "rpmdemo(x86-64)"]),
        ("PROVIDEFLAGS", [8, 8]),
        ("PROVIDEVERSION", ["3.7.2-1.el9", "3.7.2-1.el9"]),
        ("CONFLICTNAME", ["rpmdemo-old"]),
        ("CONFLICTFLAGS", [0]),
        ("CONFLICTVERSION", [""]),
        ("OBSOLETENAME", ["rpmdemo-legacy"]),
        ("OBSOLETEFLAGS", [0]),
        ("OBSOLETEVERSION", [""]),
        ("POSTIN", '/bin/sh -c "echo rpm-postinst $1"\n'),
        ("POSTINPROG", ["/bin/sh", "/sbin/ldconfig"]),
        ("PREUN", '/bin/sh -c "echo rpm-preun $1"\n'),
        ("SOURCERPM", "rpmdemo-3.7.2-1.el9.src.rpm"),
        ("PAYLOADFORMAT", "cpio"),
        ("PAYLOADCOMPRESSOR", "gzip"),
        ("PAYLOADFLAGS", "9"),
    ]
    main_hdr = build_header(entries)
    sig_hdr = b"\x8e\xad\xe8\x01\x01\x00\x00\x00" + struct.pack(">II", 0, 0)
    # 签名 header 后 pad 到 8 对齐 (相对文件绝对偏移)
    sig_end = 96 + len(sig_hdr)
    sig_hdr += b"\0" * ((8 - sig_end % 8) % 8)

    lead = struct.pack(">BBBBBBHH66sHH16s", 0xed, 0xab, 0xee, 0xdb, 3, 0, 0, 1,
                       b"rpmdemo-3.7.2-1.el9".ljust(66, b"\0"), 1, 5, b"\0" * 16)
    rpm = lead + sig_hdr + main_hdr + gz
    p = os.path.join(FIX, "rpmdemo-3.7.2-1.el9.x86_64.rpm")
    open(p, "wb").write(rpm)
    return p


# =====================================================================
# 3. 自制 Alpine .apk
# =====================================================================
def make_apk():
    pkginfo = """pkgname = alpinedemo
pkgver = 5.0.1-r2
pkgdesc = Alpine 演示包
 多行描述也应可以
url = https://alpine.demo.example.com
size = 20480
arch = x86_64
license = MIT
origin = alpinedemo
maintainer = Tester <t@example.com>
depends = so:libc.musl-x86_64.so.1 zlib>=1.2.13 libssl3~=3.1 ncurses
provides = alpinedemo-virtual=5.0.1
""".encode("utf8")
    post_install = b"""#!/bin/sh
echo "alpinedemo post_install ran"
"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        add_to_tar(tf, ".PKGINFO", pkginfo)
        add_to_tar(tf, ".post-install", post_install, mode=0o755)
        add_to_tar(tf, "usr/bin/alpinedemo", b"#!/bin/sh\necho alpine-demo\n", mode=0o755)
        add_to_tar(tf, "usr/share/alpinedemo/data.txt", b"alpine demo data\n")
    p = os.path.join(FIX, "alpinedemo-5.0.1-r2.apk")
    open(p, "wb").write(buf.getvalue())
    return p


# =====================================================================
# 4. 自制 Slackware .tgz
# =====================================================================
def make_slack():
    slack_desc = b"""|-----handy-ruler------------------------------------------------------|
slackdemo: slackdemo (Slackware demo package)
slackdemo:
slackdemo: This is a test package built for the alltap test suite.
slackdemo: It verifies Slackware -> Arch conversion.
slackdemo:
slackdemo:
slackdemo:
slackdemo:
slackdemo:
slackdemo:
"""
    doinst = b"""#!/bin/sh
echo "slackdemo doinst.sh executed"
"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        add_to_tar(tf, "install/slack-desc", slack_desc)
        add_to_tar(tf, "install/doinst.sh", doinst, mode=0o755)
        add_to_tar(tf, "usr/bin/slackdemo", b"#!/bin/sh\necho slack-demo\n", mode=0o755)
        add_to_tar(tf, "usr/share/slackdemo/foo.txt", b"slack demo\n")
    p = os.path.join(FIX, "slackdemo-2.2.0-x86_64-3.tgz")
    open(p, "wb").write(buf.getvalue())
    return p


# =====================================================================
# 5. 自制 AppImage (带 ELF 头即可, alltap 仅将其重打包)
# =====================================================================
def make_appimage():
    # type-2 AppImage 是 ELF 可执行; 我们构造一个含 ELF 头的假负载足够测试
    elf_header = bytes.fromhex("7f454c46020101000000000000000000" +
                               "02003e0001000000d000400000000000") + b"\0" * 32
    body = elf_header + b"\x00" * 512 + b"ALLTAP FAKE APPIMAGE PAYLOAD\n" * 64
    p = os.path.join(FIX, "CoolApp-2.5.AppImage")
    open(p, "wb").write(body)
    os.chmod(p, 0o755)
    return p


# =====================================================================
# 6. 通用 tarball ×2 (单顶层目录 / 系统树)
# =====================================================================
def make_tarballs():
    p1 = os.path.join(FIX, "helloworld-1.0.tar.gz")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        add_to_tar(tf, "helloworld-1.0/README", b"generic tarball demo\n")
        add_to_tar(tf, "helloworld-1.0/hello.sh", b"#!/bin/sh\necho helloworld\n", mode=0o755)
    open(p1, "wb").write(buf.getvalue())

    p2 = os.path.join(FIX, "topdir-usr-tree.tar.gz")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        add_to_tar(tf, "myapp-9/src", b"#!/bin/sh\necho from-rootfs-tarball\n", mode=0o755)
        add_to_tar(tf, "myapp-9/usr/bin/myapp", b"#!/bin/sh\necho myapp-runnable\n", mode=0o755)
        add_to_tar(tf, "myapp-9/etc/myapp/myapp.conf", b"option = on\n")
    open(p2, "wb").write(buf.getvalue())

    # 回归: 顶层目录本身就是系统目录, 不能再被当成"包装层"剥掉
    p3 = os.path.join(FIX, "usr-tree.tar.gz")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        add_to_tar(tf, "usr/bin/usrdemo", b"#!/bin/sh\necho usrdemo\n", mode=0o755)
        add_to_tar(tf, "usr/share/usrdemo/data", b"payload\n")
    open(p3, "wb").write(buf.getvalue())

    # 回归: 无系统树 + 自定义 prefix 时不得把目录搬进自身
    p4 = os.path.join(FIX, "plain-tree.tar.gz")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        add_to_tar(tf, "plaindemo-1.0/readme.txt", b"plain tarball\n")
    open(p4, "wb").write(buf.getvalue())
    return p1, p2, p3, p4


# =====================================================================
# 7. 安装闭环测试专用 deb (缺依赖/仓库依赖/文件冲突)
# =====================================================================
def make_deb_generic(pkgname, version, deps, files, filename=None):
    """files: [(归档路径, 内容, mode)]"""
    control = (f"Package: {pkgname}\nVersion: {version}\nArchitecture: amd64\n"
               f"Maintainer: Test <t@example.com>\nDepends: {deps}\n"
               f"Description: install-loop test package {pkgname}\n").encode("utf8")
    cbuf = io.BytesIO()
    with tarfile.open(fileobj=cbuf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        add_to_tar(tf, "./control", control)
    dbuf = io.BytesIO()
    with tarfile.open(fileobj=dbuf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        for path, content, mode in files:
            add_to_tar(tf, "./" + path, content, mode=mode)

    def ar_member(name, blob):
        name = name.ljust(16).encode()[:16]
        hdr = name + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6) + b"100644".ljust(8)
        hdr += str(len(blob)).encode().ljust(10) + b"`\n"
        pad = b"\n" if len(blob) & 1 else b""
        return hdr + blob + pad

    deb = b"!<arch>\n"
    deb += ar_member("debian-binary", b"2.0\n")
    deb += ar_member("control.tar.gz", cbuf.getvalue())
    deb += ar_member("data.tar.gz", dbuf.getvalue())
    p = os.path.join(FIX, filename or f"{pkgname}_{version}_amd64.deb")
    open(p, "wb").write(deb)
    return p


def make_epoch_deb():
    """回归: Version 带 epoch (1:2.0-3), 用于验证 PKGBUILD 的 epoch 变量."""
    return make_deb_generic(
        "epochdemo", "1:2.0-3", "",
        [("usr/bin/epochdemo", b"#!/bin/sh\necho epochdemo\n", 0o755)],
        filename="epochdemo_2.0-3_amd64.deb")


def make_install_fixtures():
    a = make_deb_generic("installtest", "1.0", "nonexistent-dep-xyz",
                         [("usr/bin/installtest-a", b"#!/bin/sh\necho installtest-a\n", 0o755)])
    b = make_deb_generic("repodep", "1.0", "fake-repo-dep (>= 1.0)",
                         [("usr/bin/repodep", b"#!/bin/sh\necho repodep\n", 0o755)])
    c = make_deb_generic("conflicttest", "1.0", "",
                         [("usr/bin/mockconflict", b"#!/bin/sh\necho conflict\n", 0o755)])
    # 多包事务: multia 依赖 multib, 同批一次 -U 互相满足
    d = make_deb_generic("multia", "1.0", "multib",
                         [("usr/bin/multa", b"#!/bin/sh\necho multi-a\n", 0o755)])
    e = make_deb_generic("multib", "2.1", "",
                         [("usr/bin/multib", b"#!/bin/sh\necho multi-b\n", 0o755)])
    # AUR 兜底: aur-only-dep 仓库无但 AUR mock 中存在
    f = make_deb_generic("aurapp", "1.0", "aur-only-dep",
                         [("usr/bin/aurapp", b"#!/bin/sh\necho aur-app\n", 0o755)])
    return [a, b, c, d, e, f]


if __name__ == "__main__":
    made = [make_deb(), make_rpm(), make_apk(), make_slack(), make_appimage()]
    made += list(make_tarballs())
    made.append(make_epoch_deb())
    made += make_install_fixtures()
    print("已生成测试样例:")
    for p in made:
        print(f"  {p}  ({os.path.getsize(p)} B)")
