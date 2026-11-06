# alltap 本体安装 PKGBUILD
pkgname=alltap
pkgver=1.1.0
pkgrel=1
pkgdesc="把 (几乎) 所有 Linux 软件包转换成 Arch Linux 软件包 — debtap 的全格式继任者"
arch=('any')
url="https://github.com/kane250/alltap"
license=('GPL')
depends=('python' 'libarchive' 'zstd')
optdepends=('pacman: 用于本地仓库包名匹配与安装')
source=('alltap'
        'dep-map.conf'
        'README.md')
md5sums=('SKIP' 'SKIP' 'SKIP')

package() {
  install -Dm755 "$srcdir/alltap" "$pkgdir/usr/bin/alltap"
  install -Dm644 "$srcdir/dep-map.conf" "$pkgdir/usr/share/alltap/dep-map.conf"
  install -Dm644 "$srcdir/README.md" "$pkgdir/usr/share/doc/alltap/README.md"
}
