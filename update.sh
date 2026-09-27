#!/bin/bash

# ============================================================
# Trilium Notes - Upgrade Script
# ============================================================

set -Eeuo pipefail

# ============================================================
# CONFIGURATION
# ============================================================

PRODUCTION_DIR="/opt/trilium"
BACKUP_BASE="/opt/trilium-backup/backup"
BACKUP_SCRIPT="/opt/trilium-backup/backup.sh"
UPGRADE_SOURCE="/opt/trilium-backup/upgrade-source"

SERVICE_NAME="trilium.service"
SERVICE_USER="trilium"
SERVICE_GROUP="trilium"

DATE="$(TZ=Asia/Jakarta date '+%d-%m-%Y_%H-%M-%S_WIB')-$$"

LOG_FILE="${UPGRADE_SOURCE}/upgrade.log"
ROLLBACK_DIR="/opt/trilium-backup/rollback-${DATE}"
TEMP_DIR="/opt/trilium-backup/.upgrade-${DATE}"
LOCK_DIR="/opt/trilium-backup/.upgrade.lock"

# Rollback hanya aktif setelah production lama berhasil dipindahkan.
ROLLBACK_REQUIRED=false
SERVICE_WAS_ACTIVE=false
LOCK_ACQUIRED=false

# ============================================================
# FUNCTIONS
# ============================================================

log() {
    echo "[$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S %Z')] $*" | tee -a "${LOG_FILE}"
}

die() {
    log "ERROR: $*"
    return 1
}

cleanup() {
    if [ "${ROLLBACK_REQUIRED}" != "true" ]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    fi

    if [ "${LOCK_ACQUIRED}" = "true" ]; then
        rmdir "${LOCK_DIR}" 2>/dev/null || true
    fi
}

# ============================================================
# ROLLBACK
# ============================================================

rollback() {
    local EXIT_CODE=$?

    # Matikan ERR trap agar proses rollback tidak memanggil
    # rollback lagi secara recursive.
    trap - ERR

    if [ "${ROLLBACK_REQUIRED}" != "true" ]; then
        exit "${EXIT_CODE}"
    fi

    log ""
    log "============================================================"
    log "UPGRADE GAGAL - MEMULAI ROLLBACK"
    log "============================================================"

    log "Stopping ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true

    # Hapus installation baru hanya jika production lama
    # sudah berhasil dipindahkan ke rollback directory.
    if [ -e "${PRODUCTION_DIR}" ]; then
        log "Menghapus installation baru..."
        rm -rf "${PRODUCTION_DIR}"
    fi

    if [ ! -d "${ROLLBACK_DIR}" ]; then
        log "ERROR: Rollback directory tidak ditemukan:"
        log "  ${ROLLBACK_DIR}"
        exit "${EXIT_CODE}"
    fi

    log "Mengembalikan production lama..."
    mv "${ROLLBACK_DIR}" "${PRODUCTION_DIR}"

    log "Production lama berhasil dikembalikan."

    log "Restoring ownership..."
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${PRODUCTION_DIR}"

    if [ -d "${PRODUCTION_DIR}/trilium-data" ]; then
        chmod 750 "${PRODUCTION_DIR}/trilium-data" || true
    fi

    if [ -f "${PRODUCTION_DIR}/trilium-data/document.db" ]; then
        chmod 640 "${PRODUCTION_DIR}/trilium-data/document.db" || true
    fi

    if [ -f "${PRODUCTION_DIR}/trilium-data/config.ini" ]; then
        chmod 640 "${PRODUCTION_DIR}/trilium-data/config.ini" || true
    fi

    systemctl daemon-reload

    if [ "${SERVICE_WAS_ACTIVE}" = "true" ]; then
        log "Starting original Trilium service..."
        systemctl start "${SERVICE_NAME}" 2>/dev/null || true

        sleep 5

        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            log "ROLLBACK BERHASIL."
            log "Trilium service kembali aktif."
        else
            log "WARNING: Trilium service gagal aktif setelah rollback."

            systemctl status "${SERVICE_NAME}" --no-pager >> "${LOG_FILE}" 2>&1 || true
            journalctl -u "${SERVICE_NAME}" -n 100 --no-pager >> "${LOG_FILE}" 2>&1 || true
        fi
    else
        log "ROLLBACK BERHASIL. Service sebelumnya memang tidak aktif."
    fi

    rm -rf "${TEMP_DIR}" 2>/dev/null || true

    log "============================================================"

    exit "${EXIT_CODE}"
}

trap rollback ERR
trap cleanup EXIT

# ============================================================
# ROOT CHECK
# ============================================================

if [ "${EUID}" -ne 0 ]; then
    echo "ERROR: Script harus dijalankan sebagai root."
    echo
    echo "Gunakan:"
    echo
    echo "  sudo ${0}"
    exit 1
fi

# ============================================================
# PREPARATION
# ============================================================

mkdir -p "${BACKUP_BASE}"
mkdir -p "${UPGRADE_SOURCE}"

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    LOCK_PID=""
    if [ -f "${LOCK_DIR}/pid" ]; then
        read -r LOCK_PID < "${LOCK_DIR}/pid" || true
    fi

    if [[ "${LOCK_PID}" =~ ^[0-9]+$ ]] && kill -0 "${LOCK_PID}" 2>/dev/null; then
        die "Upgrade lain sedang berjalan (PID ${LOCK_PID})."
    fi

    log "Membersihkan lock lama yang tidak aktif."
    rm -rf "${LOCK_DIR}"
    mkdir "${LOCK_DIR}" || die "Tidak dapat membuat lock: ${LOCK_DIR}"
fi
LOCK_ACQUIRED=true
printf '%s\n' "$$" > "${LOCK_DIR}/pid"

touch "${LOG_FILE}"

log "============================================================"
log "TRILIUM NOTES UPGRADE"
log "============================================================"
log "Production : ${PRODUCTION_DIR}"
log "Backup     : ${BACKUP_BASE}"
log "Source     : ${UPGRADE_SOURCE}"
log "Service    : ${SERVICE_NAME}"
log "User       : ${SERVICE_USER}"
log "Rollback   : ${ROLLBACK_DIR}"

# ============================================================
# CHECK PRODUCTION
# ============================================================

if [ ! -d "${PRODUCTION_DIR}" ]; then
    die "Production directory tidak ditemukan: ${PRODUCTION_DIR}"
fi

if [ ! -d "${PRODUCTION_DIR}/trilium-data" ]; then
    die "Directory trilium-data tidak ditemukan."
fi

if [ ! -f "${PRODUCTION_DIR}/trilium-data/document.db" ]; then
    die "document.db tidak ditemukan."
fi

if [ ! -f "${PRODUCTION_DIR}/trilium-data/config.ini" ]; then
    die "config.ini tidak ditemukan."
fi

log "Production structure : OK"

# ============================================================
# CHECK SERVICE
# ============================================================

if ! systemctl cat "${SERVICE_NAME}" >/dev/null 2>&1; then
    die "Service ${SERVICE_NAME} tidak ditemukan."
fi

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "WARNING: ${SERVICE_NAME} saat ini tidak aktif."
else
    SERVICE_WAS_ACTIVE=true
fi

log "Service ${SERVICE_NAME} : FOUND"

# ============================================================
# FIND UPGRADE ARCHIVE
# ============================================================

mapfile -t ARCHIVES < <(
    find "${UPGRADE_SOURCE}" -maxdepth 1 -type f -name 'TriliumNotes-Server-*.tar.xz' -print
)

ARCHIVE_COUNT="${#ARCHIVES[@]}"

if [ "${ARCHIVE_COUNT}" -eq 0 ]; then
    die "Tidak ada archive upgrade ditemukan di:"
    die "  ${UPGRADE_SOURCE}"
fi

if [ "${ARCHIVE_COUNT}" -gt 1 ]; then
    log "Ditemukan beberapa archive:"

    for FILE in "${ARCHIVES[@]}"; do
        log "  $(basename "${FILE}")"
    done

    die "Harap hanya menyisakan SATU archive upgrade."
fi

ARCHIVE="${ARCHIVES[0]}"
ARCHIVE_NAME="$(basename "${ARCHIVE}")"

# ============================================================
# DETECT VERSION
# ============================================================

TARGET_VERSION="$(
    echo "${ARCHIVE_NAME}" |
        sed -nE 's/^TriliumNotes-Server-(v[0-9.]+)-.*\.tar\.xz$/\1/p'
)"

if [ -z "${TARGET_VERSION}" ]; then
    TARGET_VERSION="UNKNOWN"
fi

log "Upgrade archive : ${ARCHIVE_NAME}"
log "Target version  : ${TARGET_VERSION}"

# ============================================================
# VALIDATE UPGRADE ARCHIVE
# ============================================================

log "Validating upgrade archive..."

if ! tar -tJf "${ARCHIVE}" >/dev/null 2>&1; then
    die "Archive rusak atau bukan tar.xz valid."
fi

log "Upgrade archive : VALID"

# Ekstraksi dan validasi dilakukan sebelum service dihentikan atau
# production dipindahkan, sehingga kegagalan archive tidak merusak production.
mkdir -p "${TEMP_DIR}"
log "Extracting upgrade archive..."
tar -xJf "${ARCHIVE}" -C "${TEMP_DIR}"

mapfile -t EXTRACTED_DIRS < <(
    find "${TEMP_DIR}" -mindepth 1 -maxdepth 1 -type d -print
)

if [ "${#EXTRACTED_DIRS[@]}" -ne 1 ]; then
    find "${TEMP_DIR}" -maxdepth 2 -print | tee -a "${LOG_FILE}"
    die "Struktur archive tidak sesuai."
fi

NEW_SOURCE="${EXTRACTED_DIRS[0]}"

if [ ! -f "${NEW_SOURCE}/trilium.sh" ]; then
    die "trilium.sh tidak ditemukan di archive baru."
fi

if [ ! -d "${NEW_SOURCE}/node" ]; then
    die "node directory tidak ditemukan di archive baru."
fi

if [ ! -x "${NEW_SOURCE}/trilium.sh" ]; then
    chmod +x "${NEW_SOURCE}/trilium.sh"
fi

log "New version structure : OK"

# ============================================================
# CONFIRMATION
# ============================================================

echo
echo "============================================================"
echo "              TRILIUM NOTES UPGRADE"
echo "============================================================"
echo
echo "Production : ${PRODUCTION_DIR}"
echo "Target     : ${TARGET_VERSION}"
echo "Archive    : ${ARCHIVE_NAME}"
echo
echo "Backup     : ${BACKUP_BASE}"
echo "Rollback   : ${ROLLBACK_DIR}"
echo
echo "Database   : ${PRODUCTION_DIR}/trilium-data/document.db"
echo "Config     : ${PRODUCTION_DIR}/trilium-data/config.ini"
echo
echo "============================================================"
echo

read -r -p "Lanjutkan upgrade? [y/N]: " CONFIRM

if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    log "Upgrade dibatalkan oleh user."
    exit 0
fi

# ============================================================
# STEP 1/8 - BACKUP
# ============================================================

log ""
log "============================================================"
log "STEP 1/8 - BACKUP"
log "============================================================"

if [ ! -f "${BACKUP_SCRIPT}" ]; then
    die "Backup script tidak ditemukan:"
    die "  ${BACKUP_SCRIPT}"
fi

chmod +x "${BACKUP_SCRIPT}"

log "Menjalankan backup.sh..."

if ! "${BACKUP_SCRIPT}" >> "${LOG_FILE}" 2>&1; then
    die "Backup gagal. Upgrade dibatalkan."
fi

log "Backup berhasil."

# ============================================================
# FIND LATEST BACKUP
# ============================================================

LATEST_BACKUP="$(
    find "${BACKUP_BASE}" \
        -maxdepth 1 \
        -type f \
        -name 'trilium-*.tar.gz' \
        -printf '%T@ %p\n' |
        sort -nr |
        head -1 |
        cut -d' ' -f2-
)"

if [ -z "${LATEST_BACKUP}" ]; then
    die "Backup archive tidak ditemukan."
fi

if [ ! -f "${LATEST_BACKUP}" ]; then
    die "Backup archive tidak valid:"
    die "  ${LATEST_BACKUP}"
fi

log "Latest backup:"
log "  ${LATEST_BACKUP}"

# ============================================================
# VALIDATE BACKUP
# ============================================================

log "Validating backup archive..."

if ! tar -tzf "${LATEST_BACKUP}" >/dev/null 2>&1; then
    die "Backup archive rusak."
fi

log "Backup archive : VALID"

# ============================================================
# STEP 2/8 - STOP SERVICE
# ============================================================

log ""
log "============================================================"
log "STEP 2/8 - STOP SERVICE"
log "============================================================"

log "Stopping ${SERVICE_NAME}..."

systemctl stop "${SERVICE_NAME}"

log "Menunggu service berhenti..."

for i in {1..30}; do
    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
        break
    fi

    sleep 1
done

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    die "Service masih berjalan setelah 30 detik."
fi

log "Trilium service : STOPPED"

# ============================================================
# STEP 3/8 - CREATE ROLLBACK
# ============================================================

log ""
log "============================================================"
log "STEP 3/8 - CREATE ROLLBACK"
log "============================================================"

if [ -e "${ROLLBACK_DIR}" ]; then
    die "Rollback directory sudah ada:"
    die "  ${ROLLBACK_DIR}"
fi

log "Memindahkan production lama..."

mv "${PRODUCTION_DIR}" "${ROLLBACK_DIR}"

# PENTING:
# Rollback baru diaktifkan SETELAH mv berhasil.
ROLLBACK_REQUIRED=true

log "Rollback copy:"
log "  ${ROLLBACK_DIR}"

# ============================================================
# STEP 5/8 - PRESERVE TRILIUM DATA
# ============================================================

log ""
log "============================================================"
log "STEP 5/8 - PRESERVE TRILIUM DATA"
log "============================================================"

if [ ! -d "${ROLLBACK_DIR}/trilium-data" ]; then
    die "trilium-data lama tidak ditemukan di rollback."
fi

if [ ! -f "${ROLLBACK_DIR}/trilium-data/document.db" ]; then
    die "document.db lama tidak ditemukan di rollback."
fi

if [ ! -f "${ROLLBACK_DIR}/trilium-data/config.ini" ]; then
    die "config.ini lama tidak ditemukan di rollback."
fi

log "Copying production trilium-data..."

# Gunakan cp, bukan mv.
# Dengan demikian rollback directory tetap memiliki
# document.db dan config.ini untuk recovery.

rm -rf "${NEW_SOURCE}/trilium-data"
cp -a "${ROLLBACK_DIR}/trilium-data" "${NEW_SOURCE}/trilium-data"

log "trilium-data berhasil dipertahankan."

# ============================================================
# STEP 6/8 - INSTALL NEW VERSION
# ============================================================

log ""
log "============================================================"
log "STEP 6/8 - INSTALL NEW VERSION"
log "============================================================"

mv "${NEW_SOURCE}" "${PRODUCTION_DIR}"

rm -rf "${TEMP_DIR}"

log "New version installed:"
log "  ${PRODUCTION_DIR}"

# ============================================================
# SET OWNERSHIP
# ============================================================

log "Setting ownership..."

chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${PRODUCTION_DIR}"

# ============================================================
# SET DATA PERMISSIONS
# ============================================================

chmod 750 "${PRODUCTION_DIR}/trilium-data"

if [ -f "${PRODUCTION_DIR}/trilium-data/document.db" ]; then
    chmod 640 "${PRODUCTION_DIR}/trilium-data/document.db"
fi

if [ -f "${PRODUCTION_DIR}/trilium-data/config.ini" ]; then
    chmod 640 "${PRODUCTION_DIR}/trilium-data/config.ini"
fi

log "Ownership and permissions : OK"

# ============================================================
# STEP 7/8 - START SERVICE
# ============================================================

log ""
log "============================================================"
log "STEP 7/8 - START SERVICE"
log "============================================================"

systemctl daemon-reload

systemctl enable "${SERVICE_NAME}"

log "Starting ${SERVICE_NAME}..."

systemctl start "${SERVICE_NAME}"

log "Waiting for Trilium startup..."

sleep 10

# ============================================================
# SERVICE VALIDATION
# ============================================================

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then

    log "Service failed to start."

    log "Collecting service status..."

    systemctl status "${SERVICE_NAME}" --no-pager >> "${LOG_FILE}" 2>&1 || true

    log "Collecting journal..."

    journalctl -u "${SERVICE_NAME}" -n 100 --no-pager >> "${LOG_FILE}" 2>&1 || true

    die "Trilium gagal startup."
fi

log "Trilium service : ACTIVE"

# ============================================================
# STEP 8/8 - FINAL VALIDATION
# ============================================================

log ""
log "============================================================"
log "STEP 8/8 - FINAL VALIDATION"
log "============================================================"

if [ ! -f "${PRODUCTION_DIR}/trilium-data/document.db" ]; then
    die "document.db tidak ditemukan setelah upgrade."
fi

if [ ! -f "${PRODUCTION_DIR}/trilium-data/config.ini" ]; then
    die "config.ini tidak ditemukan setelah upgrade."
fi

if [ ! -x "${PRODUCTION_DIR}/trilium.sh" ]; then
    die "trilium.sh tidak executable."
fi

log "Final validation : OK"
log "Upgrade berhasil."
log "Rollback copy dipertahankan di:"
log "  ${ROLLBACK_DIR}"
ROLLBACK_REQUIRED=false
rm -rf "${TEMP_DIR}"

log "============================================================"
log "UPGRADE SELESAI"
log "============================================================"
