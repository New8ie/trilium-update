╰─❯ cat backup.sh                                                                                                   󰍸 192.168.49.18 eth0@if8 ─╯
#!/bin/bash

# =========================
# Konfigurasi
# =========================
SOURCE_DIR="/opt/trilium"
BACKUP_BASE="/opt/trilium-backup/backup"
DATE=$(TZ=Asia/Jakarta date +"%d-%m-%Y_%H-%M-%S_WIB")
BACKUP_FILE="trilium-${DATE}.tar.gz"
LOG_FILE="${BACKUP_BASE}/backup.log"

# =========================
# Persiapan
# =========================
mkdir -p "${BACKUP_BASE}"

echo "[$(TZ=Asia/Jakarta date)] Backup dimulai" >> "${LOG_FILE}"
echo "[$(TZ=Asia/Jakarta date)] Source : ${SOURCE_DIR}" >> "${LOG_FILE}"
echo "[$(TZ=Asia/Jakarta date)] Target : ${BACKUP_BASE}/${BACKUP_FILE}" >> "${LOG_FILE}"

# =========================
# Proses Backup
# =========================
tar -czf "${BACKUP_BASE}/${BACKUP_FILE}" -C /opt trilium >> "${LOG_FILE}" 2>&1

# =========================
# Validasi
# =========================
if [ $? -eq 0 ]; then
    echo "[$(TZ=Asia/Jakarta date)] Backup berhasil: ${BACKUP_FILE}" >> "${LOG_FILE}"
else
    echo "[$(TZ=Asia/Jakarta date)] Backup GAGAL" >> "${LOG_FILE}"
    exit 1
fi

echo "[$(TZ=Asia/Jakarta date)] Backup selesai" >> "${LOG_FILE}"
echo "----------------------------------------" >> "${LOG_FILE}"