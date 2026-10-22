# codemux

Pemasang & pemelihara Termux: OpenCode **V1 + V2**, menu/banner startup, ingatan
lintas sesi, toolset, dan cek update — satu perintah, idempotent (aman dijalankan
berulang), non-destruktif.

> **Status: M5.** Yang sudah jalan: `check`, `install` (resume-safe, 10 modul),
> `status`, `repair`, `memory`, `update-check`, `doctor`, `upgrade`, `uninstall`,
> `version`, `help`. Tinggal M6 (rilis + installer satu perintah). Rancangan
> lengkap ada di [PRD.md](PRD.md).

## Pakai (versi repo)

```bash
git clone https://github.com/kusnuzon/codemux
bash codemux/bin/codemux check              # status tiap modul, tanpa mengubah apa pun
bash codemux/bin/codemux install --dry-run  # rencana pemasangan, tanpa mengubah apa pun
bash codemux/bin/codemux install            # pasang / lanjutkan yang terputus
bash codemux/bin/codemux status             # progres, lock, log terakhir
bash codemux/bin/codemux repair             # bereskan sisa proses yang mati di tengah
bash codemux/bin/codemux check --json       # untuk skrip
bash codemux/bin/codemux memory             # status ingatan lintas sesi (read-only)
bash codemux/bin/codemux update-check       # bandingkan versi lokal vs rilis hulu
bash codemux/bin/codemux doctor             # diagnosa lengkap + saran perbaikan
bash codemux/bin/codemux upgrade --dry-run  # rencana upgrade (apt + V1/V2 + launcher)
bash codemux/bin/codemux uninstall --dry-run  # rencana lepas payload (memori tetap)
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

`install` menjalankan modul berurutan: `deps -> mirror -> storage -> toolset ->
glibc -> v1 -> v2 -> launcher -> dotfiles -> memory`.

### Launcher & ingatan (M4)

- **launcher**: menulis blok bertanda `# codemux:launcher begin … end` di
  `~/.bashrc` (banner, menu panah V1/V2/shell, perintah `menu`, `version`,
  `doctor`, `codemux`, `keluar`). Blok lama tanpa penanda **diadopsi**: dipotong
  hanya kalau strukturnya dikenali (ada `_oc_launcher`, baris terakhir `fi`);
  isi lain `~/.bashrc` tidak disentuh. `.bashrc` di-backup, blok baru diuji
  `bash -n`, gagal → backup dipulihkan.
- **dotfiles**: `.bash_profile` (memuat `.bashrc`) dan `.hushlogin`.
- **memory**: `MEMORY.md`, `AGENTS.md`, `RECENT.md`, `plugins/memory.js`,
  `bin/session-digest.py`, dan entri `instructions` di `opencode.jsonc`.
  **File memori yang sudah ada tidak pernah ditimpa**; `instructions` hanya
  ditambah kalau belum ada; wrapper `_oc_refresh_digest` masuk blok
  `# codemux:memory begin … end` (hanya kalau belum ada). Mekanisme plugin/digest
  diunduh dari repo hulu, bukan disalin ke repo ini.

## Adapter OpenCode V1 & V2

codemux tidak menyalin kode OpenCode. Untuk `v1` dan `v2` ia:

1. mengunduh `install.sh` dari repo hulu lewat **API GitHub** (`Accept:
   application/vnd.github.raw`) - bukan `raw.githubusercontent.com` yang sering
   menyajikan cache basi di jaringan seluler;
2. menolak unduhan yang bukan skrip shell (mis. halaman error/rate-limit);
3. mencatat sha256 skrip, menjalankannya **terpisah dari shell** (`setsid`),
   lalu memverifikasi hasilnya: payload, launcher, `apt-mark hold` (V1), dan shim
   `lib/compat` (V2);
4. kalau gagal, langkah dicatat `FAILED` dan `codemux install` bisa diulang -
   tidak ada keadaan setengah jadi.

## Pemeliharaan (M5)

- **`update-check`** — membandingkan versi lokal (codemux, V1, V2, paket apt)
  dengan rilis hulu lewat redirect `/releases/latest` (tanpa kuota API). Hasil
  disimpan di `~/.config/codemux/update-cache.tsv` (24 jam); menu startup
  membacanya dan menjalankan cek di latar belakang kalau cache basi.
- **`doctor`** — `check` + pemeriksaan tambahan: `bash -n ~/.bashrc`, wrapper
  digest, ukuran `MEMORY.md`, `LD_PRELOAD` bionic, sisa disk, lock, umur cache.
- **`upgrade`** — `apt-get update && apt-get upgrade` (opencode tetap di-hold),
  payload V1/V2 lewat `upgrade.sh` hulu (fallback: adapter), lalu sinkron ulang
  blok launcher + wrapper digest. `--only apt,v1,v2,launcher`, `--dry-run`,
  `--yes`; memakai lock yang sama dengan `install`.
- **`uninstall`** — memindahkan payload V1/V2 ke
  `~/.config/codemux/backup/<ts>-uninstall/`, melepas blok
  `# codemux:launcher` / `# codemux:memory` dari `~/.bashrc` (diuji `bash -n`,
  gagal → dibiarkan utuh). **Tidak** menghapus `MEMORY.md`, `AGENTS.md`,
  project, atau backup. `--purge` menghapus `~/.config/codemux`.

Kode keluar `check`: `0` semua siap · `1` ada yang kurang · `2` prasyarat gagal.
Kode keluar `install`: `0` selesai · `1` ada langkah gagal · `2` prasyarat gagal ·
`3` ada install lain berjalan.

## Tahan mati di tengah

`install` tidak pernah mengandalkan "sekali jalan":

- state `RUNNING` ditulis **sebelum** langkah; mati = kelihatan berhenti di mana;
- unduhan/penulisan file pakai file sementara + `mv` (atomik), plus sha256;
- proses panjang (apt, unduhan besar) jalan `setsid` + pidfile + log, jadi shell
  atau opencode yang mati **tidak** membunuhnya;
- lock berisi pid + boot-id: lock basi (proses mati / HP reboot) dibuang otomatis;
- `codemux install` tanpa argumen = **melanjutkan**, bukan mulai dari nol;
- `codemux repair` membereskan lock basi, dpkg setengah jadi, shim V2 hilang.

Diuji oleh `tests/resume.sh` (16 skenario: SIGKILL induk, SIGKILL induk+anak,
apt gagal, lock aktif, sisa file sementara).

## Struktur

```
bin/codemux        entry point
lib/common.sh      warna, log, util, deteksi
lib/state.sh       state TSV, run.tsv (progres), lock pid+boot-id, log
lib/exec.sh        spawn detached, wait, tulis atomik, backup
lib/adapter.sh     unduh + validasi install.sh hulu
lib/check.sh       runner check (read-only)
lib/install.sh     install (resume) + status
lib/repair.sh      repair (lock basi, dpkg, shim V2)
lib/update.sh      update-check + cache 24 jam
lib/maintenance.sh doctor, upgrade, uninstall
lib/modules/*.sh   probe + apply + verify per modul
tests/smoke.sh     uji cepat (syntax, help, json, shellcheck)
tests/resume.sh    16 skenario "matikan di tengah"
tests/adapter.sh   12 skenario adapter V1/V2 (hulu palsu)
tests/launcher-memory.sh  22 skenario launcher/dotfiles/ingatan (sandbox HOME)
tests/maintenance.sh      13 skenario update-check/doctor/upgrade/uninstall
templates/         blok bashrc + template ingatan + penyunting opencode.jsonc
versions.env       versi dipin + daftar paket
PRD.md             rancangan lengkap (tujuan, mekanisme, milestone)
```

## Roadmap

- **M1** kerangka + `check` ✅
- **M2** `install` (deps, mirror, storage, toolset, glibc) + resume ✅
- **M3** adapter OpenCode V1 + V2 [selesai]
- **M4** launcher + ingatan lintas sesi ✅
- **M5** `doctor`, `upgrade`, `repair`, `uninstall`, cek update ✅
- **M6** CI + rilis tarball + installer satu perintah

## Catatan

- Repo ini hanya berisi **mekanisme**; isi memori pribadi tidak pernah di-push.
- Butuh Termux aarch64 (Android), bukan root.
- Kalau repo di-clone ke `/storage/emulated/0` (FUSE), file di sana **tidak bisa
  dieksekusi langsung** (`Permission denied`) → jalankan `bash bin/codemux …`.
  Setelah di-install ke `$PREFIX/bin`, `codemux` jalan normal.
- `raw.githubusercontent.com` bisa menyajikan cache lama di jaringan seluler —
  unduhan rilis memakai tarball + verifikasi sha256.
