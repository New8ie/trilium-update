# Trilium Notes Update Script

Skrip Bash untuk memperbarui instalasi Trilium Notes Server di Linux yang
menggunakan `systemd`. Skrip menyiapkan dan memeriksa versi baru sebelum
mengganti instalasi yang sedang berjalan, menyimpan backup dan salinan
rollback, serta mencoba memulihkan versi sebelumnya jika service gagal
dijalankan setelah upgrade.

> Skrip ini ditujukan untuk instalasi dengan direktori produksi
> `/opt/trilium` dan service `trilium.service`. Periksa konfigurasi di bagian
> atas `update.sh` sebelum menggunakannya pada server.

## Fitur

- Memerlukan konfirmasi sebelum mulai mengubah instalasi.
- Memastikan struktur instalasi saat ini dan archive upgrade tersedia.
- Mengekstrak dan memvalidasi kandidat versi baru sebelum menghentikan service.
- Menjalankan skrip backup sebelum upgrade.
- Mempertahankan direktori `trilium-data` (termasuk database dan konfigurasi)
  saat memasang versi baru.
- Mencegah dua proses upgrade berjalan bersamaan dengan lock.
- Menyimpan instalasi lama di direktori rollback yang unik.
- Mengembalikan instalasi lama jika instalasi baru gagal melewati pemeriksaan
  service atau pemeriksaan akhir.
- Menyimpan log proses di `upgrade-source/upgrade.log`.

## Persyaratan

- Linux dengan Bash dan `systemd`.
- Hak akses `root`/`sudo`.
- Perintah `tar`, `find`, `sort`, `head`, `cut`, `sed`, `systemctl`, dan
  `journalctl`.
- Service `trilium.service` yang sudah terpasang.
- Akun dan grup sistem `trilium`.
- Instalasi saat ini di `/opt/trilium`, berisi:
  - `trilium.sh`
  - `trilium-data/document.db`
  - `trilium-data/config.ini`
- Skrip backup di `/opt/trilium-backup/backup.sh`.

Skrip backup harus membuat archive bernama `trilium-*.tar.gz` di
`/opt/trilium-backup/backup`. Pastikan skrip backup tersebut sudah diuji
secara terpisah dan hasilnya dapat dibuka sebelum melakukan upgrade.

## Konfigurasi

Nilai berikut ditetapkan di bagian konfigurasi `update.sh`:

| Pengaturan | Nilai default |
| --- | --- |
| Direktori produksi | `/opt/trilium` |
| Direktori backup | `/opt/trilium-backup/backup` |
| Skrip backup | `/opt/trilium-backup/backup.sh` |
| Sumber archive dan log | `/opt/trilium-backup/upgrade-source` |
| Nama service | `trilium.service` |
| User dan grup service | `trilium:trilium` |

Jika susunan server berbeda, ubah nilai-nilai tersebut agar sesuai sebelum
menjalankan skrip. Pastikan `WorkingDirectory` dan `ExecStart` pada unit
systemd tetap sesuai dengan direktori produksi.

## Persiapan server

1. Pasang Trilium Notes Server dan pastikan berjalan normal dari
   `/opt/trilium`.
2. Pasang unit systemd yang disediakan di repository:

   ```bash
   sudo install -m 0644 trilium.service /etc/systemd/system/trilium.service
   sudo systemctl daemon-reload
   sudo systemctl enable trilium.service
   ```

   Unit ini berjalan sebagai user `trilium`, dengan working directory
   `/opt/trilium`.
3. Pasang dan uji `/opt/trilium-backup/backup.sh`. Pastikan ia membuat
   archive `trilium-*.tar.gz` di direktori backup yang dikonfigurasi.
4. Buat direktori sumber archive:

   ```bash
   sudo mkdir -p /opt/trilium-backup/upgrade-source
   ```

5. Letakkan **satu** archive resmi Trilium Notes Server bernama sesuai pola
   `TriliumNotes-Server-*.tar.xz` di direktori tersebut. Hapus atau pindahkan
   archive versi lain agar tidak ada lebih dari satu kandidat.

   Archive harus berisi tepat satu direktori teratas yang di dalamnya
   terdapat `trilium.sh` dan direktori `node/`.

## Menjalankan upgrade

Jalankan dari direktori repository:

```bash
sudo bash update.sh
```

Skrip akan memeriksa prasyarat dan archive, lalu meminta konfirmasi. Jawab `y`
untuk melanjutkan. Jawaban lain membatalkan proses tanpa mengganti instalasi.

Jangan menghentikan paksa proses saat ia sedang mengganti direktori produksi.
Tunggu hingga skrip melaporkan `UPGRADE SELESAI` atau selesai melakukan
rollback.

## Backup, rollback, dan log

- Backup rutin yang dibuat oleh `backup.sh` disimpan di
  `/opt/trilium-backup/backup`.
- Salinan instalasi sebelum upgrade disimpan di direktori unik seperti
  `/opt/trilium-backup/rollback-<tanggal>-<waktu>-<pid>`.
- Log upgrade disimpan di
  `/opt/trilium-backup/upgrade-source/upgrade.log`.
- Jika upgrade gagal setelah instalasi lama dipindahkan, skrip mencoba
  mengembalikannya dan menyalakan service hanya jika service sebelumnya aktif.
- Direktori rollback tidak dihapus otomatis. Periksa kondisi server dan
  pastikan backup lain tersedia sebelum menghapusnya secara manual.

Periksa status service dan log bila perlu:

```bash
sudo systemctl status trilium.service
sudo journalctl -u trilium.service -n 100 --no-pager
sudo less /opt/trilium-backup/upgrade-source/upgrade.log
```

## Catatan keselamatan

- Uji proses pemulihan backup sebelum menjalankan upgrade pada server penting.
- Simpan salinan database dan konfigurasi di lokasi terpisah sebelum
  memulai; skrip upgrade tidak menggantikan strategi backup berkala.
- Mekanisme rollback menangani kegagalan proses upgrade yang terdeteksi oleh
  skrip. Kegagalan daya atau penghentian paksa dapat memutus proses pada waktu
  yang tidak terduga, sehingga backup terpisah tetap diperlukan.
- Perubahan skema database oleh versi Trilium baru mungkin tidak dapat
  dibatalkan hanya dengan mengembalikan file instalasi lama. Ikuti panduan
  upgrade/backup resmi Trilium untuk versi yang digunakan.
- `update.log.example` merupakan contoh log, bukan file konfigurasi.

## Lisensi

Proyek ini menggunakan GNU General Public License v3.0. Lihat [LICENSE](LICENSE).
