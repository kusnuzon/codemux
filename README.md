# codemux

Pemasang & pemelihara Termux: OpenCode **V1 + V2**, menu/banner startup, ingatan
lintas sesi, toolset, dan cek update — satu perintah, idempotent (aman dijalankan
berulang), non-destruktif.

> **Status: M1 (kerangka).** Yang sudah jalan: `codemux check`, `version`, `help`.
> `install`, `upgrade`, `repair`, `doctor`, `memory` menyusul di milestone
> berikutnya. Rancangan lengkap ada di [PRD.md](PRD.md).

## Pakai (versi repo)

```bash
git clone https://github.com/kusnuzon/codemux
bash codemux/bin/codemux check        # status tiap modul, tanpa mengubah apa pun
bash codemux/bin/codemux check --json # untuk skrip
```

Setelah terpasang (M2+), perintahnya menjadi `codemux` di `$PREFIX/bin`.

## Yang dicek `codemux check`

| Modul | Isi |
|---|---|
| `preflight` | Android, aarch64, bukan root, disk ≥ 3 GB |
| `deps` | curl, tar, sha256sum, gzip, unzip, awk, sed |
| `mirror` | repo apt aktif (peringatan kalau mirror lambat) |
| `storage` | `termux-setup-storage` sudah jalan |
| `toolset` | 20 paket apt wajib (git, gh, python, chromium, …) |
| `glibc` | loader + libc.so.6 untuk payload OpenCode |
| `opencode-v1` | payload V1 + `apt-mark hold` |
| `opencode-v2` | payload V2 + shim `lib/compat` |
| `launcher` | blok banner/menu di `~/.bashrc` (mendeteksi blok lama) |
| `dotfiles` | `.bash_profile`, `.hushlogin` |
| `memory` | `MEMORY.md` (+ batas 24.000 byte), `RECENT.md`, plugin, instructions |
| `update-cache` | umur cache cek update hulu |

Kode keluar: `0` semua siap · `1` ada yang kurang · `2` prasyarat gagal.

## Struktur

```
bin/codemux        entry point
lib/common.sh      warna, log, util, deteksi
lib/state.sh       state TSV, lock, log per-run
lib/check.sh       runner check (read-only)
lib/modules/*.sh   satu probe per modul
tests/smoke.sh     uji cepat (syntax, help, json, shellcheck)
versions.env       versi dipin + daftar paket
PRD.md             rancangan lengkap (tujuan, mekanisme, milestone)
```

## Roadmap

- **M1** kerangka + `check` ✅
- **M2** `install` (deps, mirror, storage, toolset, glibc)
- **M3** adapter OpenCode V1 + V2
- **M4** launcher + ingatan lintas sesi
- **M5** `doctor`, `upgrade`, `repair`, `uninstall`, cek update
- **M6** CI + rilis tarball + installer satu perintah

## Catatan

- Repo ini hanya berisi **mekanisme**; isi memori pribadi tidak pernah di-push.
- Butuh Termux aarch64 (Android), bukan root.
- Kalau repo di-clone ke `/storage/emulated/0` (FUSE), file di sana **tidak bisa
  dieksekusi langsung** (`Permission denied`) → jalankan `bash bin/codemux …`.
  Setelah di-install ke `$PREFIX/bin`, `codemux` jalan normal.
- `raw.githubusercontent.com` bisa menyajikan cache lama di jaringan seluler —
  unduhan rilis memakai tarball + verifikasi sha256.
