# PRD — `codemux` (nama kerja)

Satu perintah untuk menjadikan Termux "siap pakai": OpenCode V1 + V2 + menu/banner
+ toolset + storage, baik dari Termux kosong maupun yang sudah terisi sebagian.
Repo baru, publik, idempotent (dijalankan berulang aman).

Status: **DRAF v2 — belum ada kode.** Nama & 3 keputusan utama sudah disetujui (lihat §18).

---

## 1. Masalah

Sekarang pemasangan tersebar di 3 tempat dan 3 ingatan:

| Hal | Sekarang | Akibat |
|---|---|---|
| OpenCode V1 | repo `opencode-termux` | install sendiri, upgrade sendiri |
| OpenCode V2 | repo `opencode-termux-v2` | idem + shim glibc/LD_PRELOAD |
| Toolset (chromium, gh, python, dll) | perintah manual di catatan | lupa, versi beda |
| Menu + banner + panduan | `~/.bashrc` lokal | hilang kalau Termux di-uninstall |
| Storage Android | `termux-setup-storage` manual | lupa, paths rusak |
| Cek kondisi | `doctor.sh` per repo | tidak ada cek menyeluruh |

Target: **satu baris copy-paste** → semua terpasang, terverifikasi, dan bisa
diperbarui dengan satu perintah.

---

## 2. Tujuan (Goals)

1. `curl … | bash` → Termux kosong jadi siap pakai (V1, V2, menu, toolset, storage).
2. Idempotent: dijalankan di Termux yang sudah terisi → hanya mengisi yang kurang,
   tidak menimpa config user.
3. `codemux check` memberi tahu status tiap komponen (terpasang / kurang / rusak).
4. `codemux upgrade` memperbarui paket apt, V1, V2, dan dotfiles sekaligus.
5. Semua langkah punya deteksi (precheck) + aksi + verifikasi + rollback.
6. Transparan: setiap aksi dicetak, ada `--dry-run`.
7. **Ingatan lintas sesi** untuk V1 *dan* V2: percakapan baru langsung tahu
   memori + ringkasan sesi sebelumnya (§12A).
8. **Cek update otomatis**: kalau repo hulu punya rilis baru, muncul pemberitahuan;
   setelah disetujui, terbaru diunduh & dipasang (§12B).

## 3. Non-tujuan (bukan lingkup versi 1)

- Tidak menggantikan package manager Termux; hanya orkestrasi `pkg`/`apt`.
- Tidak menyimpan token/secret apa pun (tidak ada login GitHub otomatis).
- Tidak build dari source (semua paket/prebuilt).
- Tidak mendukung arsitektur selain `aarch64` (arm64 Android) di v1.
- Tidak menghapus data user (tidak pernah `rm -rf` di HOME/config).

## 4. Pengguna & skenario

| Skenario | Kondisi awal | Yang diharapkan |
|---|---|---|
| S1 Termux baru | belum ada apa pun | semua terpasang, menu muncul, `doctor` hijau |
| S2 Termux separuh | V1 ada, V2 tidak | V2 + menu + toolset kurang dipasang, V1 di-skip |
| S3 Termux penuh | semua sudah ada | semua di-skip, selesai < 60 detik, tidak ada file berubah |
| S4 Update | sudah ada, versi lama | `upgrade` → apt + V1/V2 naik, config tetap |
| S5 Rusak | V2 error glibc/LD_PRELOAD | `doctor` menunjuk penyebab + `repair` memperbaiki |
| S6 Offline | tanpa internet | berhenti cepat, pesan jelas, bisa lanjut (`--resume`) |

---

## 5. Prinsip desain

1. **Deteksi dulu, aksi kemudian.** Setiap modul punya `probe()`; kalau sudah
   memenuhi syarat → `SKIP` dan dicatat.
2. **Non-destruktif.** File user (`.bashrc`, `MEMORY.md`, plugin) di-backup ke
   `~/.config/codemux/backup/<timestamp>/` sebelum diubah; merge, bukan timpa.
3. **Resumable.** State per-modul (`DONE/SKIP/FAIL`) sehingga bisa diulang tanpa
   mengunduh ulang.
4. **Tidak butuh `jq`/python untuk orkestrasi.** State = TSV sederhana.
5. **Satu sumber kebenaran.** Logika V1/V2 tidak diduplikasi; `codemux`
   memanggil installer resmi repo `opencode-termux` dan `opencode-termux-v2`.
6. **Adapter, bukan salinan.** `lib/v1.sh` & `lib/v2.sh` memanggil installer resmi repo masing-masing;
   kalau repo tak terjangkau, pakai tarball release terakhir yang di-cache di `~/.cache/codemux/`.
7. **Aman di Termux yang ramai.** `apt-mark hold opencode` supaya `pkg upgrade`
   tidak menimpa payload V1 (bug yang pernah kejadian).

---

## 6. Perintah (CLI)

```
codemux [perintah] [opsi]

perintah:
  install            pasang semua yang belum ada (default)
  check              status tiap modul, tanpa mengubah apa pun
  upgrade            apt + V1 + V2 + dotfiles (+ prompt update kalau ada)
  update-check       cek rilis baru di hulu, tulis cache, keluar (tanpa install)
  repair             perbaiki modul yang gagal/rusak
  doctor             diagnosa lengkap (bisa dibagikan, tanpa data sensitif)
  uninstall          lepas komponen (butuh konfirmasi; config user tetap)
  self-update        perbarui codemux sendiri

opsi:
  --yes / -y         tanpa konfirmasi
  --dry-run          cetak rencana, tidak eksekusi
  --only a,b,c       batasi ke modul tertentu
  --skip a,b,c       lewati modul tertentu
  --latest           pakai versi terbaru (abaikan versions.env)
  --no-storage       jangan jalankan termux-setup-storage
  --no-memory        jangan pasang fitur ingatan (default: dipasang)
  --auto-update      langsung unduh+pasang kalau ada update (default: tanya)
  --no-update-check  lewati cek update saat install/upgrade
  --mirror auto|id|official
  --json             output mesin (untuk `check`/`doctor`)
  --verbose          tampilkan perintah yang dijalankan
```

Kode keluar: `0` sukses/terpenuhi, `1` gagal sebagian, `2` prasyarat tidak
terpenuhi (bukan Android/arch salah/disk kurang).

---

## 7. Arsitektur repo

```
codemux/
├── install.sh              # bootstrap kecil: unduh release → jalankan bin/codemux
├── bin/codemux        # entry point (bash), loader lib/*.sh
├── lib/
│   ├── common.sh           # log, warna, die, need, backup, confirm, state
│   ├── state.sh            # baca/tulis state TSV, resume
│   ├── modules/*.sh        # 1 file per modul (lihat §8)
│   ├── memory.sh           # pasang/merge ingatan V1+V2 (§12A)
│   ├── updater.sh          # cek rilis hulu + prompt (§12B)
│   ├── v1.sh               # adapter ke repo opencode-termux
│   └── v2.sh               # adapter ke repo opencode-termux-v2
├── assets/
│   ├── bashrc-snippet      # banner + menu panah + panduan (blok bertanda)
│   ├── bash_profile        # `. ~/.bashrc`
│   └── hushlogin           # sembunyikan MOTD bawaan
├── memory/                 # template: MEMORY.md, AGENTS.md, opencode.jsonc
├── plugins/                # memory.js + session-digest.py (mekanisme saja)
├── versions.env            # versi yang dipin (V1, V2, chromium, …)
├── tools/doctor.sh         # diagnosa
└── tests/
    ├── sandbox-home.sh     # uji install 2x di HOME palsu
    └── smoke.sh
```

`install.sh` sengaja kecil (< 60 baris): pastikan `curl`, unduh tarball release,
verifikasi sha256, ekstrak ke `~/.cache/codemux/src`, lalu eksekusi.

---

## 8. Modul & deteksi (inti mekanisme)

Urutan eksekusi = tabel di bawah. `probe` menentukan SKIP/APPLY.

| # | Modul | Deteksi (probe) | Aksi kalau kurang |
|---|---|---|---|
| 0 | `preflight` | `uname -o`=Android, `uname -m`=aarch64, `id -u`≠0, disk ≥ 3 GB, DNS ok | tolak dengan pesan jelas |
| 1 | `bootstrap-deps` | `command -v curl tar sha256sum` | `pkg update -y && pkg install -y curl tar coreutils` |
| 2 | `mirror` | isi `$PREFIX/etc/apt/sources.list` + `apt-get update` < N detik | `termux-change-repo` non-interaktif / tulis sources.list |
| 3 | `storage` | `[ -d ~/storage ]` dan `/sdcard` tertulis | `termux-setup-storage` (interaktif! lihat §11) |
| 4 | `apt-toolset` | `dpkg-query -W` untuk tiap paket di `versions.env` | `pkg install -y <paket kurang>` (termasuk grup `browser`: chromium, playwright, agent-browser) |
| 5 | `glibc-runtime` | `$PREFIX/glibc/lib/ld-linux-aarch64.so.1` ada | `pkg install -y glibc-repo glibc termux-exec-glibc` |
| 6 | `opencode-v1` | `$PREFIX/share/opencode/opencode.real --version` | panggil `lib/v1.sh` (install/upgrade) + `apt-mark hold opencode` |
| 7 | `opencode-v2` | `$PREFIX/share/opencode-v2/VERSION` + `opencode-v2 --version` | panggil `lib/v2.sh` (tarball npm + shim `lib/compat` + sanitasi env) |
| 8 | `launcher` | `~/.bashrc` memuat penanda `# codemux:launcher v1` | backup lalu sisipkan blok dari `assets/bashrc-snippet` |
| 9 | `dotfiles` | `~/.bash_profile`, `~/.hushlogin` | tulis/merge (tidak menimpa isi lain) |
| 10 | `memory` | `memory.js` + `session-digest.py` ada, `instructions` memuat `MEMORY.md` & `RECENT.md` | pasang template + merge `opencode.jsonc`; file yang sudah ada **tidak** ditimpa; `--no-memory` melewati |
| 11 | `update-check` | cache `~/.config/codemux/update-cache.tsv` < 24 jam | cek rilis hulu (redirect `releases/latest`, tanpa kuota API), tulis cache; `--no-update-check` melewati |
| 12 | `verify` | jalankan `doctor` | laporan ringkas + kode keluar |

Aturan tiap modul (kontrak):

```bash
module_probe()   # 0 = sudah memenuhi, 1 = perlu aksi
module_apply()   # 0 = sukses, !=0 gagal
module_verify()  # 0 = benar-benar berfungsi
```

Output seragam: `[3/11] storage        SKIP  (sudah ada)`,
`[6/11] opencode-v1    APPLY (1.19.0 → 1.19.3)`, `… OK`, `… FAIL (sebab)`.

---

## 9. State & resume

`~/.config/codemux/state.tsv` (append-only, mudah dibaca manusia):

```
# ts             modul          status  versi   catatan
2026-10-22T19:40  preflight      DONE    -       android/aarch64, disk 3.3G
2026-10-22T19:41  apt-toolset    SKIP    -       145 paket sudah ada
2026-10-22T19:44  opencode-v2    APPLY   2.1.2   shim compat dipasang
```

Backup: `~/.config/codemux/backup/20261022-194000/.bashrc` dst.
Lock: `~/.config/codemux/lock` (cegah 2 proses paralel).

---

## 10. Alur installer (fase)

```
[bootstrap]  install.sh: cek bash+curl → unduh tarball release → sha256 → exec bin/codemux install
     │
[preflight]  OS/arch/uid/disk/DNS/versi bash → gagal = berhenti (exit 2)
     │
[rencana]    probe semua modul → cetak tabel rencana (APPLY/SKIP) → konfirmasi (kecuali -y / --dry-run)
     │
[eksekusi]   modul 1..10 berurutan; tiap modul: apply → verify → catat state
     │        gagal 1 modul ≠ gagal total: lanjut, kumpulkan daftar FAIL
     │
[verifikasi] doctor lengkap → ringkasan: OK/SKIP/FAIL + langkah lanjutan yang disarankan
     │
[selesai]    tampilkan: cara buka menu, cara upgrade, lokasi log
```

Log lengkap: `~/.config/codemux/logs/<timestamp>.log` (mode 600).

---

## 11. `termux-setup-storage` (khusus, interaktif)

Dialog izin Android tidak bisa di-otomatiskan penuh. Mekanisme:

1. `probe`: kalau `~/storage` ada dan `/sdcard/Android` bisa dibaca → SKIP.
2. Kalau tidak: jalankan `termux-setup-storage` dan **tunggu**; beri instruksi
   "ketuk Izinkan di layar". Timeout 90 detik.
3. Kalau gagal/timeout: catat `WARN`, lanjutkan modul lain (tidak fatal),
   tampilkan cara manual di akhir.
4. `--no-storage` melewati langkah ini sepenuhnya.

---

## 12. Upgrade & pemeliharaan

| Perintah | Isi |
|---|---|
| `codemux upgrade` | `pkg update && pkg upgrade -y` (opencode di-hold) → `lib/v1.sh upgrade` → `lib/v2.sh upgrade` → sinkron ulang blok launcher (versi) → `doctor` |
| `codemux self-update` | unduh rilis terbaru `codemux`, ganti `bin/`+`lib/` (assets tidak disentuh kalau user mengubahnya) |
| `codemux repair` | pilih modul berstatus FAIL/rusak → apply ulang (mis. pasang ulang shim compat V2, sanitasi `LD_PRELOAD`) |
| `codemux uninstall` | lepas payload V1/V2 + blok launcher; **tidak** menghapus `MEMORY.md`, project, atau backup |

Jadwal opsional: tidak ada cron di Termux secara default → cukup saran
"jalankan `codemux upgrade` sebulan sekali".

---

## 12A. Fitur ingatan lintas sesi (V1 + V2)

Masalah: tiap `/new` (V1) atau sesi baru (V2) mulai dari nol; fakta yang sudah
dibahas hilang. `codemux` memasang mekanisme yang **sama untuk kedua versi**:
isi memori tetap lokal, repo hanya berisi mekanisme (template).

### Yang dipasang (modul `memory`)

| File | Peran | Kalau sudah ada |
|---|---|---|
| `~/.config/opencode/opencode.jsonc` | `instructions: ["MEMORY.md","RECENT.md"]` | **merge**: tambahkan entri yang belum ada, jangan hapus key lain |
| `~/.config/opencode/MEMORY.md` | memori permanen (fakta, keputusan, path) | **tidak** ditimpa |
| `~/.config/opencode/AGENTS.md` | aturan permanen (bahasa, gaya, larangan) | tidak ditimpa |
| `~/.config/opencode/RECENT.md` | ringkasan 8 sesi terakhir (auto-generate) | dibuat/ditimpa setiap digest |
| `~/.config/opencode/bin/session-digest.py` | pembuat `RECENT.md` | tidak ditimpa (bandingkan versi skrip) |
| `~/.config/opencode/plugins/memory.js` | tool `memory_save` + hook compaction + refresh digest | tidak ditimpa; kalau versi lebih baru → tawarkan `--force` |
| `~/.bashrc` (blok launcher) | panggil digest sebelum opencode dibuka | sisip di dalam blok bertanda |

### Bagaimana satu plugin melayani dua versi

`memory.js` default-export ganda:

```js
export default {
  id: 'memory',
  setup(ctx) { … },   // V2: Plugin.define, tool lewat ctx.tool.transform
  server() { … },     // V1: plugin server klasik
}
```
Helper/tool V1 diimpor **dinamis** di dalam `server()` supaya V2 tidak pernah
memuat paket V1 (pernah bikin crash).

### Sumber data digest

| Versi | Database | Tabel |
|---|---|---|
| V1 | `~/.local/share/opencode/opencode.db` | `session`, `message`, `part` |
| V2 | `~/.opencode-v2/data/opencode/opencode.db` | `session_v2`, `session_message` |

Digest mengambil **8 sesi terakhir dari keduanya**, satu paragraf per sesi
(perintah user + hasil akhir, dipotong ±600 karakter), ditulis ke `RECENT.md`
yang dimuat otomatis lewat `instructions`.

### Aturan penting

1. **Batas keras `MEMORY.md` = 24.000 byte.** Plugin menolak menulis kalau lewat
   (sudah terbukti di produksi). `doctor` memeriksa ukuran; kalau > 90% batas →
   peringatan + saran pangkas (`codemux memory prune` hanya **menyarankan**,
   tidak menghapus).
2. **Tidak menimpa ingatan user.** Install ulang tidak boleh mengosongkan
   `MEMORY.md`/`AGENTS.md` — ini kesalahan yang paling mahal.
3. **Tanpa data pribadi di repo.** Repo hanya template; isi memori tidak pernah
   di-push.
4. **Isolasi V1/V2.** Keduanya berbagi folder config (ingatan sama), tetapi DB
   sesi terpisah; digest membaca keduanya.
5. **Verifikasi**: `codemux memory check` → file ada, `instructions` memuat dua
   entri, `memory.js` lolos `node --check`, digest menghasilkan `RECENT.md` tidak kosong.
6. **`--no-memory`** melewati seluruh modul (untuk yang ingin config bersih).

### Perintah terkait

```
codemux memory check        # status + ukuran MEMORY.md/RECENT.md
codemux memory digest       # paksa regenerate RECENT.md sekarang
codemux memory prune --dry-run  # saran entri usang (tidak menghapus)
```

---

## 12B. Cek update otomatis + unduh setelah disetujui

Masalah: Termux tidak punya cron; versi V1/V2/codemux cepat basi dan tidak ada
yang memberi tahu. Solusi: cek ringan saat menu dibuka, notifikasi, lalu unduh
hanya setelah disetujui.

### Sumber yang dicek

| Komponen | Cara ambil versi terbaru | Biaya kuota |
|---|---|---|
| `codemux` | redirect `https://github.com/kusnuzon/codemux/releases/latest` → tag | 0 (tanpa API) |
| `opencode-termux` (V1) | redirect `…/opencode-termux/releases/latest` | 0 |
| `opencode-termux-v2` (V2) | redirect `…/opencode-termux-v2/releases/latest` | 0 |
| paket apt | `apt list --upgradable` (pakai cache) | 0 |
| versi lokal | `dpkg-query`, `$PREFIX/share/opencode-v2/VERSION`, `codemux --version` | 0 |

API GitHub hanya dipakai sebagai **fallback** (kuota 60/jam tanpa token).

### Alur

```
menu dibuka
   └─ cache update < 24 jam? ── ya ──> tampilkan baris notifikasi (instan)
                │ tidak
                └─ jalankan `codemux update-check --quiet` di latar belakang
                   (timeout 6 detik, output ke cache, tidak menahan prompt)
                        └─ selesai → cache diperbarui → notifikasi muncul
                           pada menu berikutnya / saat kembali dari opencode

ada versi lebih baru:
   ⬆ update tersedia: V2 2.1.2 → 2.1.3 · codemux 1.0.0 → 1.1.0
     tekan [u] untuk update sekarang (nanti bisa: codemux upgrade)
   └─ [u] → ringkasan perubahan → konfirmasi [y/N]
             └─ y → unduh rilis → sha256 → backup → pasang → verify
                    ├─ sukses → versi baru tampil, cache dibersihkan
                    └─ gagal  → rollback otomatis + laporan
```

### Konfigurasi (`~/.config/codemux/config`)

```ini
auto_update_check=on        # on|off
auto_update_mode=ask        # ask (default) | notify | auto
check_interval=24h
include_apt=yes
```

- `ask` → notifikasi + tanya sebelum unduh (**default**).
- `notify` → hanya memberi tahu, tidak pernah bertanya.
- `auto` → langsung unduh+pasang (`--auto-update`), tetap backup + verify.

### Keamanan & perilaku

- Tidak pernah update saat sesi opencode/TUI sedang jalan — hanya di menu/CLI.
- Setiap unduhan diverifikasi sha256; payload lama di-backup
  (`~/.config/codemux/backup/<ts>/`) dan dipulihkan kalau `verify` gagal.
- Offline/timeout → gagal **senyap**, cache tidak diubah, startup tidak terganggu.
- `opencode` tetap `apt-mark hold` supaya apt tidak menimpa payload V1.
- Riwayat cek/unduh dicatat di `~/.config/codemux/logs/update.log` (mode 600).

### Perintah terkait

```
codemux update-check            # cek sekarang, cetak tabel versi
codemux update-check --json     # untuk skrip
codemux upgrade                 # tampilkan ringkasan → konfirmasi → pasang
codemux upgrade --yes           # tanpa tanya
codemux upgrade --only opencode-v2
```

---

## 13. Keamanan & keandalan

- Semua unduhan diverifikasi `sha256` (dicatat di `versions.env` / release notes).
- Tidak ada `curl | bash` berlapis: bootstrap mengunduh tarball, bukan pipe script kedua.
- Tidak pernah menulis token; `gh` tidak diotentikasi otomatis.
- `set -Eeuo pipefail`, `shellcheck -S warning` wajib lolos di CI.
- Tidak menjalankan `rm -rf` pada path yang mengandung `$HOME`, kecuali path
  internal `~/.cache/codemux/src`.
- Mode file config baru: `600` untuk state/log.

---

## 14. Target non-fungsional

| Metrik | Target |
|---|---|
| Waktu S3 (semua sudah ada) | < 60 detik |
| Waktu S1 (kosong → siap) | 10–25 menit di 4G (unduhan ±1,2–1,5 GB) |
| Ruang disk minimum dicek | 3 GB bebas |
| Ukuran repo (tanpa binary) | < 300 KB |
| Idempotensi | jalankan 2x → run kedua 0 perubahan file (dicek `find -newer`) |
| Kegagalan jaringan | pesan jelas + `--resume` tidak mengunduh ulang yang sudah ada |
| Digest sesi (8 sesi, V1+V2) | < 2 detik, tidak menahan prompt |
| Cek update (latar belakang) | < 6 detik, tidak pernah memblokir menu |
| Cache cek update | 1× per 24 jam per komponen |

---

## 15. Kriteria penerimaan (Given/When/Then)

1. **S1** Given Termux baru tanpa config, When `install -y`, Then `opencode`, `opencode-v2`,
   `menu`, `version`, `doctor` tersedia; `doctor` keluar 0; menu muncul di sesi baru.
2. **S2** Given V1 ada & V2 tidak, When `install -y`, Then modul V1 tercatat `SKIP`
   dan file V1 tidak berubah (hash sama).
3. **S3** Given semua terpasang, When `install -y` dua kali, Then run kedua semua `SKIP`
   dan tidak ada file di `$HOME` yang berubah (kecuali state/log).
4. **S4** Given `.bashrc` user punya isi sendiri, When `install`, Then blok launcher
   disisipkan dan isi lama tetap ada; backup tersedia.
5. **S5** Given `LD_PRELOAD` bionic aktif, When menjalankan `opencode-v2`, Then tetap jalan
   (sanitasi env) — diverifikasi `doctor`.
6. **S6** Given tanpa internet, When `install`, Then berhenti di preflight dengan exit 2
   dan pesan actionable.
7. **S7 (ingatan)** Given install selesai, When buka sesi baru V1 *dan* V2, Then
   `MEMORY.md` + `RECENT.md` termuat otomatis; `memory_save` menulis fakta; sesi
   lain membacanya. Given `MEMORY.md` sudah berisi milik user, Then hash-nya tidak
   berubah setelah install.
8. **S8 (update)** Given versi lokal lebih lama dari rilis hulu, When buka menu,
   Then muncul baris `⬆ update tersedia`; When jawab `y`, Then diunduh + sha256
   cocok + versi naik; When jawab `n`, Then tidak ada unduhan. Given offline,
   Then cek update gagal senyap (tidak mengganggu startup).

---

## 16. Risiko & mitigasi

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Mirror apt lambat/mati | install menggantung | probe kecepatan, fallback mirror resmi, timeout per apt |
| `raw.githubusercontent.com` cache basi (pernah kejadian) | script lama terpakai | unduh lewat API `Accept: vnd.github.raw` + tarball release + cek `VERSION` |
| `apt-mark hold` terlewat | `pkg upgrade` menimpa payload V1 | modul V1 wajib set hold + doctor memeriksa |
| `LD_PRELOAD` bionic | V2 gagal start | sanitasi env di launcher & service; doctor cek |
| Izin storage ditolak | path project rusak | WARN non-fatal + instruksi manual |
| Disk 3 GB | unduhan gagal di tengah | preflight cek disk, `--only` untuk hemat |
| Menimpa `.bashrc` user | kehilangan config | penanda blok + backup + merge |
| Dua proses bersamaan | state korup | lockfile |
| `MEMORY.md` > 24.000 byte (batas keras plugin, pernah kejadian) | `memory_save` gagal | `doctor` memberi peringatan + `codemux memory prune --dry-run` untuk saran pangkas (tidak menghapus otomatis) |
| `RECENT.md` membengkak | context boros | digest dibatasi 8 sesi, tiap sesi dipotong ±600 karakter |
| Notifikasi update palsu / versi lokal lebih baru | unduhan sia-sia | bandingkan semver; `update-check --json` menampilkan sumber versi |
| Batas API GitHub (60/jam) | cek gagal | pakai redirect `releases/latest` (tanpa kuota), API hanya fallback |
| Update ditawarkan saat sesi opencode jalan | mengganggu | hanya ditawarkan di menu/CLI, tidak saat TUI aktif |

---

## 17. Milestone

| # | Isi | Keluaran |
|---|---|---|
| M1 | kerangka: `bin`, `lib/common`, `state`, `preflight`, `check` | `codemux check` jalan |
| M2 | modul env: deps, mirror, storage, apt-toolset, glibc | Termux "siap alat" |
| M3 | adapter V1 & V2 (panggil repo yang ada) | `opencode`, `opencode-v2` jalan |
| M4 | launcher: banner+menu panduan, dotfiles, **ingatan V1+V2** (§12A) | tampilan awal + ingatan jadi |
| M5 | `doctor`, `upgrade`, `repair`, `uninstall`, **`update-check` + prompt update** (§12B) | pemeliharaan |
| M6 | CI: shellcheck, uji sandbox HOME, release tarball | rilis 1.0 |

---

## 18. Keputusan yang perlu persetujuan Master

| # | Pertanyaan | Rekomendasi |
|---|---|---|
| D1 | Nama repo | **`codemux`** (dipilih) |
| D2 | Duplikasi logika V1/V2? | **Adapter** — memanggil repo `opencode-termux` & `opencode-termux-v2` (dipilih) |
| D3 | Memori pribadi ikut? | Template saja, hanya dengan `--with-memory`, tidak menimpa (**disetujui**) |
| D4 | Mirror apt default | `auto` (uji cepat, fallback resmi) (**disetujui**) |
| D5 | Termux "dari 0" termasuk Chromium/Playwright? | **Ya, default terpasang** (dipilih); bisa dilewati `--skip browser` (hemat ±400 MB) |
| D6 | Bahasa output | Indonesia (default), `--lang en` menyusul (**disetujui**) |
| D7 | Fitur ingatan dipasang default? | **Ya, default ON** (`--no-memory` untuk melewati) — diminta Master |
| D8 | Perilaku cek update | **Notifikasi dulu, unduh setelah disetujui**; `--auto-update` untuk tanpa tanya |
| D9 | Interval cek update | **24 jam**, dijalankan di latar belakang (timeout 6 detik) saat menu dibuka |
| D10 | Notifikasi update di dalam sesi opencode | Fase lanjut (M7), lewat plugin yang membaca cache |

---

## 19. Satu perintah (rencana)

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/kusnuzon/codemux/contents/install.sh | bash -s -- --yes
```

Varian hemat (tanpa browser/python berat):

```bash
curl -fsSL -H 'Accept: application/vnd.github.raw' \
  https://api.github.com/repos/kusnuzon/codemux/contents/install.sh \
  | bash -s -- --yes --skip browser,python
```

---

## 20. Anti-mati di tengah proses (resume & rollback)

Pertanyaan yang harus dijawab sebelum M2: **kalau proses mati di tengah, siapa yang
membereskan?** Jawabannya: codemux sendiri, tanpa langkah manual.

Prinsipnya: setiap langkah harus **idempoten atau atomik**, dan state ditulis
**sebelum** langkah mulai (`RUNNING`) lalu `DONE`/`FAILED` setelah verifikasi.
Maka proses yang mati kapan pun selalu ketahuan sedang di mana.

### 20.1 Tiga lapis pertahanan

| Lapis | Untuk langkah | Cara |
|---|---|---|
| Idempoten | apt install, mkdir, tulis blok config | cek dulu; kalau sudah benar → `SKIP`, tidak diulang |
| Atomik | unduh payload, ganti file config | `.part` → sha256 → `mv` (rename atomik), file lama jadi `.old` |
| Terpisah dari shell | apt, unduh ±200 MB | `setsid nohup` + pidfile + log; shell/opencode mati ≠ proses mati |

### 20.2 State yang bisa dibaca manusia

`state.tsv` + penanda `install.run`:

```
# langkah       status     mulai  selesai  catatan
1 preflight     DONE       19:40  19:40    android/aarch64
2 deps          DONE       19:40  19:41    7 alat ada
3 toolset       RUNNING    19:41  -        apt pid 12345
```

`codemux status` menampilkan: langkah ke berapa dari berapa, pid aktif, 10 baris log
terakhir. Kalau proses mati, status tetap `RUNNING` tapi pid sudah tidak hidup →
codemux tahu itu **terputus**, bukan selesai.

### 20.3 Deteksi proses mati

- Lock berisi `pid` + `boot-id`; kalau pid mati atau boot-id beda (HP reboot) →
  lock basi dibuang otomatis. Master tidak perlu `rm` apa pun.
- Langkah `RUNNING` tanpa proses hidup → ditandai `INTERRUPTED` → dijalankan ulang
  **dari langkah itu**, bukan dari awal.

### 20.4 Langkah yang tidak boleh diulang sembarangan

- **apt**: `DEBIAN_FRONTEND=noninteractive`, `-o Dpkg::Options::=--force-confold`,
  `--no-install-recommends`. Sebelum mulai: `dpkg --audit` + `apt-get check`; kalau
  ada sisa proses sebelumnya → `dpkg --configure -a` + `apt-get -f install` dulu.
- **payload OpenCode**: unduh → sha256 → extract ke `opencode.new` → uji
  `--version` lewat loader → **baru** tukar (`mv` lama → `.old`, `mv` baru → final).
  Kalau uji gagal, yang lama tetap utuh; `codemux repair` mengembalikan `.old`.
- **`.bashrc`/config**: backup ke `backup/<ts>/`, tulis blok bertanda
  `# codemux:launcher begin` … `# codemux:launcher end`. Blok tak lengkap dibuang
  dan backup dipulihkan oleh `codemux repair`.

### 20.5 Tidak pernah merusak yang sudah jalan

- Modul yang sudah `OK` tidak disentuh sama sekali.
- Tidak ada `rm -rf` pada path pengguna; yang dihapus hanya file sementara codemux.
- Langkah kritis (preflight, glibc, payload) pakai `--stop-on-error`: gagal = berhenti,
  tidak melanjutkan ke langkah yang bergantung padanya.

### 20.6 Bisa dilanjutkan tanpa Master

1. Buka Termux lagi → menu membaca `install.run` dan menampilkan baris paling atas:
   `! instalasi terputus di langkah 3/9 — Enter untuk melanjutkan`.
2. `codemux install` tanpa argumen = **resume otomatis**; `--fresh` untuk mulai nol.
3. Perbaikan darurat satu perintah: `codemux repair` (dpkg configure, lock basi,
   shim hilang, blok config rusak).

### 20.7 Uji "matikan di tengah"

`tests/resume.sh` — sandbox dengan `apt`/`curl` palsu, tidak menyentuh sistem:

| Skenario | Harapan |
|---|---|
| SIGKILL di tengah langkah apt | run berikutnya melanjutkan, tidak ada duplikat |
| jaringan putus saat unduh | `.part` dibuang, run berikutnya unduh ulang |
| lock basi (pid mati) | otomatis dibuang, bukan error |
| payload sha256 salah | `.new` dibuang, payload lama tetap jalan |
| SIGKILL saat tulis `.bashrc` | blok tak lengkap dibersihkan, backup dipulihkan |

Kriteria lulus: **tidak ada satu pun skenario yang butuh langkah manual** selain
menjalankan `codemux install` atau `codemux repair` satu kali.

### 20.8 Yang jujur tidak bisa dijamin

Kalau Android mematikan Termux tepat saat dpkg menulis database, DB dpkg bisa
setengah jadi. Itu **terdeteksi** di run berikutnya (`dpkg --audit`) dan diperbaiki
otomatis (`dpkg --configure -a`, `apt-get -f install`) — tetap tanpa intervensi
manual, hanya butuh jaringan lagi.
