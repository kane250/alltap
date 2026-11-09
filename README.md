# alltap

**Convert (almost) any Linux software package into an Arch Linux package** — the all-format successor to [debtap](https://github.com/helixarch/debtap).

`debtap` only handles `.deb`. `alltap` handles them all in one tool:

[English](README.md) | [简体中文](README.zh-CN.md)

| Input format | Origin distros | Metadata extraction | Install script porting | Tested |
|---|---|---|---|---|
| `.deb` | Debian / Ubuntu / Deepin / UOS … | Full control fields | preinst/postinst/prerm/postrm (with deb argument semantics emulation) | ✓ |
| `.rpm` | Fedora / RHEL / openSUSE … | Pure-Python RPM header parsing (gzip/xz/zstd payloads) | %pre/%post/%preun/%postun + ldconfig | ✓ (incl. real Fedora package) |
| `.apk` | Alpine | Full `.PKGINFO` | 6 alpine scripts mapped 1:1 to pacman hooks | ✓ |
| `.tgz` / `.txz` | Slackware | slack-desc + filename | doinst.sh | ✓ |
| `.AppImage` | Any | Filename / ELF arch detection | — (repacked into /opt) | ✓ |
| `.tar.gz` etc. | Any tarball | Smart detection: `usr/` system tree → packed as-is, otherwise → /opt | — | ✓ |
| `.pkg.tar.zst` | Arch itself | Full `.PKGINFO` | Original `.INSTALL` kept | ✓ |

## Installation

```bash
# Option 1: install directly (script + mapping database)
./install.sh                 # installs to ~/.local/bin and ~/.local/share/alltap
sudo ./install.sh /usr/local # system-wide install

# Option 2: install via makepkg (Arch-based systems)
makepkg -f -d && sudo pacman -U alltap-*.pkg.tar.zst
```

Runtime dependencies: `python ≥ 3.9`, `bsdtar` (libarchive, bundled with Arch), `zstd`.
**RPM parsing requires no RPM tools whatsoever** (built-in pure-Python parser + cpio(newc) unpacker).

## Usage

```bash
alltap package.deb                    # produce a pacman -U ready .pkg.tar.zst
alltap package.rpm                    # same (Fedora/RHEL/openSUSE packages)
alltap tool.apk                       # Alpine package
alltap foo-1.0-x86_64-1.txz           # Slackware package
alltap CoolApp-2.5.AppImage -n coolapp # AppImage repacked into /opt/coolapp
alltap bundle-2.1.tar.xz              # generic archive (auto-detects system tree vs. binary bundle)
alltap a.deb b.rpm c.apk              # batch conversion
alltap package.deb --no-prompt        # convert only, never ask to install
alltap package.deb -p                 # PKGBUILD only (debtap-compatible mode)
alltap package.deb -o ~/pkgs          # custom output directory
alltap program.rpm -k                 # keep untranslatable deps verbatim
alltap any.rpm -v 2.1-3               # override package version (all formats; -v kept for debtap compat)
alltap app.tar.gz --prefix /usr/local # prefix when there is no system tree (default /opt/{pkgname}; also honored by -p AppImage)
alltap a.deb b.rpm -i                 # install after conversion, multi-package single transaction
alltap a.deb b.rpm -i --dry-run       # rehearsal: print the install plan, install nothing
alltap a.deb -i --aur                 # fall back to AUR for missing deps, with confirmation
alltap --version                      # show alltap version (= -V)
alltap --refresh                      # refresh the Arch repo package-name cache
```

Output is written flat into the `-o` directory (current directory by default); there is no
per-package `<pkgname>/` subdirectory:

```
<pkgname>-<ver>-<rel>-<arch>.pkg.tar.zst   # the resulting package
alltap-report-<pkgname>.txt                # dependency translation report
alltap-plan.txt                            # install plan (with --dry-run)
```

Re-converting the same package is skipped with a notice unless `-f` is given.

Every package is built through a makepkg-equivalent pipeline (`.PKGINFO` + `.MTREE` + optional `.INSTALL`, GNU tar format + zstd compression, ownership normalized to root), directly installable via `pacman -U`.

## Install self-healing loop (`-i`)

Conversion is only half the story — third-party packages usually fail on missing dependencies or file conflicts. With `-i`, alltap installs right after conversion and, on failure, diagnoses the cause, repairs automatically, and retries. **Multiple packages go in a single transaction**: one `pacman -U app1.pkg app2.pkg ...` resolves cross-dependencies within the batch, avoiding the "A depends on B which is not installed yet" ordering failures of per-package installs:

```
unpack+parse ─▶ dep mapping ─▶ .pkg.tar.zst ───▶ pacman -U (single transaction)
  ×N batched                       │                        │
                                   │       failure: missing dep ◀─┘
                                   │         ├─ provided by batch → relax version constraint if needed
                                   │         ├─ in repos → pacman -S --asdeps
                                   │         ├─ not in repos → (--aur) query AUR → yay/paru
                                   │         │                └─ else ask rename / remove → repack affected
                                   │         └─ file conflict → exact --overwrite
                                   └──(loop until success or max tries)
```

```bash
alltap foo.deb -i                  # convert, install, self-heal on failure
alltap foo.deb foo.rpm -i          # multi-package single transaction
alltap foo.deb -i -y               # fully automatic (no confirmation prompts)
alltap foo.rpm -i --max-tries 8    # raise the retry limit (default 5)
alltap foo.deb -i --no-autodeps    # forbid installing missing repo deps
alltap foo.deb -i --no-overwrite   # forbid automatic file-conflict handling
alltap foo.deb -i --aur            # query AUR for repo-missing deps, install via yay/paru
alltap foo.deb -i --dry-run        # print the install plan only
```

Repair strategies:

| Failure | Detection | Action | Safety |
|---|---|---|---|
| Missing dep · in repos | `pacman -Si` hit | `pacman -S --asdeps --noconfirm`, then retry | disable via `--no-autodeps` |
| Missing dep · not in repos | `pacman -Si` miss | With `--aur`: query AUR (version/maintainer/votes), install via `paru`/`yay -S --asdeps` after explicit confirmation; otherwise interactive rename / remove / abort — only affected packages get repacked | non-interactive defaults to abort; AUR builds need explicit confirmation; `-y` auto-removes |
| Dep points into the batch, wrong version | dep name matches a batch package / `provides` | drop the version constraint and repack that package | each dep relaxed at most once |
| Over-strict version | same dep still missing after install | strip the constraint and repack | logged explicitly |
| File conflict | `xxx exists in filesystem` | collect exact paths, retry with `--overwrite <path>` per path | **never uses `*` wildcards**; disable via `--no-overwrite` |
| Breaks other packages' deps | `breaks dependency ... required by ...` | report and stop | never auto-removes others' deps |

### AUR dependency fallback (`--aur`)

When a dependency has no repo counterpart (typical for Ubuntu-specific library names), `--aur` queries the [AUR RPC](https://aur.archlinux.org/rpc) API:

- On hit, shows **version, maintainer, votes, out-of-date status**; after confirmation installs via `paru`/`yay -S --asdeps` (one of them must be installed) and retries the loop;
- On miss or network failure, falls back to the rename/remove flow;
- AUR packages build from source and run third-party code — confirmation is **always required** (`-y` plus `--aur` together counts as consent).

### Install plan rehearsal (`--dry-run`)

Review before install: after conversion, no install happens. The full plan is printed and written to `<output>/alltap-plan.txt`:

- **Dependency resolution**: `pacman -T` against the current system → satisfied / to-be-installed-from-repo / provided by the batch / not found anywhere (decision needed);
- **File-conflict pre-check**: compares each package's file list with the pacman local database, listing files that would be `--overwrite`-ed and their owning packages (orphan files owned by no package cannot be pre-checked and remain subject to the actual install);
- **Script warning**: which packages ship an `.INSTALL` that will run as root.

Notes:

- `-i` / `--dry-run` automatically **keep untranslatable dependencies verbatim** (plain conversion drops them), so that pacman can judge repository availability and drive the repair loop.
- Root required for installs: runs directly as root; normal users escalate via non-interactive `sudo -n`, then `pkexec`. Read-only queries (`-T`/`-Si`) never escalate.
- All pacman invocations run under `LC_ALL=C` for stable output parsing; after exhausting retries, generated packages and `alltap-report-<pkgname>.txt` are preserved.
- Test-only environment channels: `ALLTAP_PACMAN` (override pacman binary), `ALLTAP_PACMAN_ROOT` (`--root` isolated root), `ALLTAP_PACMAN_EXTRA` (extra args), `ALLTAP_NO_SUDO=1` (skip escalation), `ALLTAP_AUR_RPC` (AUR RPC URL template with `{name}` placeholder, supports `file://` for offline mocking), `ALLTAP_AUR_HELPER` (override yay/paru command).

## How dependency translation works

Three layers (`data/dep-map.conf`, ~750 rules + an embedded subset):

1. **Exact mapping**: `libc6 => glibc`, `openssl-libs => openssl`, `libssh2.so.1 => libssh2`, SPDX license aliases …;
2. **Local repo match**: candidate names (or variants after stripping soname digits, `-dev`/`-devel` suffixes, `lib` prefixes) compared against `pacman -Slq` names;
3. **Regex rules**: `libllvm14 → llvm-libs`, `libicu72 → icu`, `libboost_* → boost-libs` …

Untranslatable dependencies are dropped by default and summarized at the end (`-k` keeps them). Distro-infrastructure deps (`debconf`, `dpkg`, `rpmlib(...)`, `config(...)`, `/bin/sh`, GLIBC-versioned sonames …) are pruned automatically. deb `Recommends` becomes `optdepends`, `Breaks` merges into `conflicts`, rpm `Obsoletes` becomes `replaces`; version operators (`<<`/`>>`/`>=` …) are mapped to pacman syntax one by one.

**Install script porting**: deb scripts get `set -- configure/install/...` to emulate Debian argument semantics; rpm scripts emulate install/upgrade/erase via `$1 = 1/2/0`; `%post -p /sbin/ldconfig` becomes a plain `ldconfig` call; alpine's 6 script types map 1:1 onto pacman's.

## Known limitations

- Conversion is not 100% semantically equivalent: script argument semantics are emulated; `pre/posttrans` has no pacman equivalent (ignored with a warning);
- RPM range dependencies (`<>`) degrade to unversioned deps;
- Bleeding-edge or niche dep names may fail to translate — check `alltap-report-<pkgname>.txt` and add rules to `data/dep-map.conf`;
- Unaudited third-party packages are a security risk — inspect with `pacman -Qlp` before installing.

## Development & testing

```bash
bash tests/run-tests.sh          # conversion regression: 7 formats + PKGBUILD + repack + 6 regressions (16/16)
bash tests/test-install-mock.sh  # install-loop mock tests: 10 scenarios (multi-pkg/AUR/dry-run incl.)
bash tests/test-install-real.sh  # real-pacman isolated tests (unshare + throwaway root, 6/6)
python3 tests/build-fixtures.py  # rebuild all test fixtures (16)
```

All fixtures are generated programmatically (hand-crafted valid RPM/cpio streams, ar archives, `.PKGINFO`), plus a real hello RPM downloaded from the official Fedora repository.

CI runs all three suites on every push — see [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Differences vs. debtap

| | debtap | alltap |
|---|---|---|
| Formats | .deb only | deb/rpm/apk/tgz/AppImage/tarball/archpkg |
| RPM parsing | ✗ | pure Python (zero deps, zstd payload support) |
| Packaging | interactive + makepkg | one-shot build (makepkg-equivalent) + `-p` mode |
| Dep database | manual `-u` online update | local pacman repos + built-in mappings, offline |
| Interactivity | multiple prompts per package | none by default; `-k`/`--no-scripts` available |
| Install | ✗ | multi-package transaction `-i` + AUR fallback `--aur` + rehearsal `--dry-run` |

## License

GPL-3.0-or-later
