# alltap 本体安装 PKGBUILD
# 注: makepkg 查找本地 source 时只认 PKGBUILD 同级的文件名 (子目录会被拍平),
#     因此 dep-map.conf 与 LICENSE 直接按仓库内路径安装, 不放进 source 数组.
# note: makepkg resolves local sources by basename next to the PKGBUILD only
#       (subdirectories are flattened), so dep-map.conf and LICENSE are
#       installed straight from their repository paths instead of `source`.
pkgname=alltap
pkgver=1.2.1
pkgrel=1
pkgdesc="把 (几乎) 所有 Linux 软件包转换成 Arch Linux 软件包 — debtap 的全格式继任者"
arch=('any')
url="https://github.com/kane250/alltap"
license=('GPL')
depends=('python' 'libarchive' 'zstd')
optdepends=('pacman: 用于本地仓库包名匹配与安装')
source=('alltap'
        'README.md')
md5sums=('SKIP' 'SKIP')

package() {
  install -Dm755 "$srcdir/alltap" "$pkgdir/usr/bin/alltap"
  install -Dm644 "$startdir/data/dep-map.conf" "$pkgdir/usr/share/alltap/dep-map.conf"
  install -Dm644 "$srcdir/README.md" "$pkgdir/usr/share/doc/alltap/README.md"
  install -Dm644 "$startdir/LICENSE" "$pkgdir/usr/share/licenses/alltap/LICENSE"
}