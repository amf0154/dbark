#!/bin/bash

set -euo pipefail

# Конфигурация
INFLUXDB_HOST=${INFLUXDB_HOST:-localhost}
INFLUXDB_PORT=${INFLUXDB_PORT:-8086}
INFLUXDB_TOKEN=${INFLUXDB_TOKEN}
INFLUXDB_ORG=${INFLUXDB_ORG}
BACKUP_DIR="/backups"
STORAGE_DIR="/backup-storage"
RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
COMPRESSION=${BACKUP_COMPRESSION:-true}
LOG_FILE="/var/log/backup/backup.log"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Функция отправки уведомлений
send_notification() {
    local status=$1
    local message=$2
    local env_name="${ENVIRONMENT:-unknown}"
    
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="🔄 InfluxDB Backup [${env_name}] ${status}: ${message}" \
            -d parse_mode="HTML" || true
    fi
    
    if [[ -n "${WEBHOOK_URL:-}" ]]; then
        curl -s -X POST "${WEBHOOK_URL}" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"${status}\",\"message\":\"${message}\",\"environment\":\"${env_name}\",\"timestamp\":\"$(date -Iseconds)\"}" || true
    fi
}

# Проверка доступности InfluxDB
check_influxdb() {
    log "Проверка доступности InfluxDB..."
    if ! curl -s -f "http://${INFLUXDB_HOST}:${INFLUXDB_PORT}/ping" > /dev/null; then
        log "ERROR: InfluxDB недоступен"
        send_notification "FAILED" "InfluxDB недоступен на ${INFLUXDB_HOST}:${INFLUXDB_PORT}"
        exit 1
    fi
    log "InfluxDB доступен"
}

# Создание бэкапа
create_backup() {
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local environment=${ENVIRONMENT:-staging}
    local prefix=${BACKUP_PREFIX:-backup}
    local backup_name="${prefix}_${environment}_${timestamp}"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    log "Начало создания бэкапа: ${backup_name}"
    
    # Создание директории для бэкапа
    mkdir -p "$backup_path"
    
    # Выполнение бэкапа ВСЕХ организаций (как вы делали раньше)
    log "Выполнение команды: influx backup $backup_path --host http://${INFLUXDB_HOST}:${INFLUXDB_PORT} --token [HIDDEN] --compression gzip"
    
    if influx backup "$backup_path" \
        --host "http://${INFLUXDB_HOST}:${INFLUXDB_PORT}" \
        --token "$INFLUXDB_TOKEN" \
        --compression gzip; then
        
        log "Бэкап успешно создан: ${backup_path}"
        
        # Сжатие бэкапа
        if [[ "$COMPRESSION" == "true" ]]; then
            log "Сжатие бэкапа..."
            cd "$BACKUP_DIR"
            tar -czf "${backup_name}.tar.gz" "$backup_name"
            rm -rf "$backup_name"
            backup_path="${backup_path}.tar.gz"
            log "Бэкап сжат: ${backup_path}"
        fi
        
        # Копирование в постоянное хранилище
        if [[ -d "$STORAGE_DIR" ]]; then
            cp "$backup_path" "$STORAGE_DIR/"
            log "Бэкап скопирован в постоянное хранилище"
        fi
        
        # Получение размера бэкапа
        local backup_size=$(du -h "$backup_path" | cut -f1)
        
        # Загрузка в облако (если настроено)
        upload_to_cloud "$backup_path" "$backup_name"
        
        send_notification "SUCCESS" "Бэкап создан успешно. Размер: ${backup_size}"
        
    else
        log "ERROR: Ошибка при создании бэкапа"
        send_notification "FAILED" "Ошибка при создании бэкапа"
        exit 1
    fi
}

# Загрузка в облачное хранилище
upload_to_cloud() {
    local backup_path=$1
    local backup_name=$2
    
    # Google Drive
    if [[ "${GOOGLE_DRIVE_ENABLED:-false}" == "true" ]]; then
        log "Загрузка бэкапа в Google Drive..."
        
        if python3 /app/scripts/google_drive.py upload "$backup_path"; then
            log "Бэкап успешно загружен в Google Drive"
        else
            log "WARNING: Ошибка загрузки в Google Drive"
        fi
    fi
}

# Очистка старых бэкапов
cleanup_old_backups() {
    log "Очистка бэкапов старше ${RETENTION_DAYS} дней..."
    
    # Локальные бэкапы (поиск по паттерну с любым префиксом)
    find "$BACKUP_DIR" -name "*_*_*.tar.gz" -type f -mtime +${RETENTION_DAYS} -delete
    
    # Бэкапы в постоянном хранилище
    if [[ -d "$STORAGE_DIR" ]]; then
        find "$STORAGE_DIR" -name "*_*_*.tar.gz" -type f -mtime +${RETENTION_DAYS} -delete
    fi
    
    # Облачные бэкапы (если настроено)
    if [[ "${GOOGLE_DRIVE_ENABLED:-false}" == "true" ]]; then
        log "Очистка старых бэкапов в Google Drive..."
        python3 /app/scripts/google_drive.py cleanup "${RETENTION_DAYS}" || log "WARNING: Ошибка очистки Google Drive"
    fi
    
    log "Очистка завершена"
}

# Проверка свободного места
check_disk_space() {
    local available_space=$(df "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    local required_space=1048576  # 1GB в KB
    
    if [[ $available_space -lt $required_space ]]; then
        log "WARNING: Мало свободного места для бэкапов"
        send_notification "WARNING" "Мало свободного места для бэкапов: $(df -h "$BACKUP_DIR" | awk 'NR==2 {print $5}') использовано"
    fi
}

# Основная функция
main() {
    log "=== Начало процедуры бэкапа ==="
    
    # Создание директории для логов
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Проверки
    check_influxdb
    check_disk_space
    
    # Создание бэкапа
    create_backup
    
    # Очистка старых бэкапов
    cleanup_old_backups
    
    log "=== Процедура бэкапа завершена ==="
}

# Запуск
main "$@"