#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/backup/health.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Проверка доступности InfluxDB
check_influxdb() {
    if curl -s -f "http://${INFLUXDB_HOST:-influxdb}:${INFLUXDB_PORT:-8086}/ping" > /dev/null; then
        log "✓ InfluxDB доступен"
        return 0
    else
        log "✗ InfluxDB недоступен"
        return 1
    fi
}

# Проверка наличия свежих бэкапов
check_recent_backups() {
    local backup_dir="/backups"
    local max_age_hours=${MAX_BACKUP_AGE_HOURS:-25}
    
    # Поиск последнего бэкапа (совместимо с BusyBox)
    local latest_backup=$(find "$backup_dir" -name "backup_*.tar.gz" -type f -exec ls -t {} + 2>/dev/null | head -1)
    
    if [[ -z "$latest_backup" ]]; then
        log "ℹ Нет бэкапов в директории $backup_dir (первый запуск — ожидается в 02:00)"
        return 0
    fi
    
    # Проверка возраста бэкапа
    local backup_age_seconds=$(( $(date +%s) - $(date -r "$latest_backup" +%s 2>/dev/null || echo "0") ))
    local backup_age_hours=$(( backup_age_seconds / 3600 ))
    
    if [[ $backup_age_hours -gt $max_age_hours ]]; then
        log "✗ Последний бэкап устарел: $backup_age_hours часов назад ($(basename "$latest_backup"))"
        return 1
    else
        log "✓ Свежий бэкап найден: $(basename "$latest_backup") ($backup_age_hours часов назад)"
        return 0
    fi
}

# Проверка свободного места
check_disk_space() {
    local backup_dir="/backups"
    local storage_dir="/backup-storage"
    local min_free_percent=10
    
    # Проверка места для бэкапов
    local backup_usage=$(df "$backup_dir" | awk 'NR==2 {print int($5)}' | sed 's/%//')
    if [[ $backup_usage -gt $((100 - min_free_percent)) ]]; then
        log "✗ Мало места для бэкапов: ${backup_usage}% использовано"
        return 1
    else
        log "✓ Достаточно места для бэкапов: ${backup_usage}% использовано"
    fi
    
    # Проверка места в хранилище
    if [[ -d "$storage_dir" ]]; then
        local storage_usage=$(df "$storage_dir" | awk 'NR==2 {print int($5)}' | sed 's/%//')
        if [[ $storage_usage -gt $((100 - min_free_percent)) ]]; then
            log "✗ Мало места в хранилище: ${storage_usage}% использовано"
            return 1
        else
            log "✓ Достаточно места в хранилище: ${storage_usage}% использовано"
        fi
    fi
    
    return 0
}

# Проверка процессов
check_processes() {
    # Проверка cron демона (может называться cron или crond)
    if pgrep -f "cron" > /dev/null || service cron status > /dev/null 2>&1; then
        log "✓ Cron демон работает"
    else
        log "✗ Cron демон не работает"
        return 1
    fi
    
    # Проверка мониторинга (опционально)
    if pgrep -f "monitor.py" > /dev/null; then
        log "✓ Мониторинг работает"
    else
        log "ℹ Мониторинг не запущен (это нормально)"
        # Не возвращаем ошибку, так как мониторинг опционален
    fi
    
    return 0
}

# Проверка целостности последнего бэкапа
check_backup_integrity() {
    local backup_dir="/backups"
    
    # Поиск последнего бэкапа (совместимо с BusyBox)
    local latest_backup=$(find "$backup_dir" -name "backup_*.tar.gz" -type f -exec ls -t {} + 2>/dev/null | head -1)
    
    if [[ -z "$latest_backup" ]]; then
        log "ℹ Нет бэкапов для проверки целостности (первый запуск)"
        return 0
    fi
    
    log "Проверка целостности бэкапа: $(basename "$latest_backup")"
    
    # Проверка размера файла
    local file_size=$(wc -c < "$latest_backup" 2>/dev/null || echo "0")
    if [[ $file_size -lt 1024 ]]; then
        log "✗ Размер бэкапа подозрительно мал: $file_size байт"
        return 1
    fi
    
    # Проверка сжатого файла
    if [[ "$latest_backup" == *.gz ]]; then
        if gzip -t "$latest_backup"; then
            log "✓ Сжатый бэкап прошел проверку целостности"
        else
            log "✗ Сжатый бэкап поврежден"
            return 1
        fi
        
        # Проверка содержимого InfluxDB бэкапа
        if zcat "$latest_backup" | head -20 | grep -q -E "(# DDL|# DML|influxdb|bucket)" 2>/dev/null; then
            log "✓ InfluxDB содержимое корректно"
        else
            log "⚠ InfluxDB содержимое не удалось проверить (возможно сжатый файл)"
            # Не возвращаем ошибку для сжатых файлов
        fi
    else
        # Проверка несжатого файла
        if head -20 "$latest_backup" | grep -q -E "(# DDL|# DML|influxdb|bucket)" 2>/dev/null; then
            log "✓ InfluxDB содержимое корректно"
        else
            log "⚠ InfluxDB содержимое не удалось проверить"
            # Не возвращаем ошибку, так как файл может быть валидным
        fi
    fi
    
    return 0
}

# Проверка подключения к InfluxDB и базовых операций
check_influxdb_operations() {
    log "Проверка базовых операций InfluxDB..."
    
    # Проверка подключения через API
    if curl -s -f "http://${INFLUXDB_HOST:-influxdb}:${INFLUXDB_PORT:-8086}/health" > /dev/null; then
        log "✓ InfluxDB API доступен"
    else
        log "✗ Ошибка доступа к InfluxDB API"
        return 1
    fi
    
    # Проверка доступности организации и bucket (если указаны токены)
    if [[ -n "${INFLUXDB_TOKEN:-}" && -n "${INFLUXDB_ORG_NAME:-}" ]]; then
        if curl -s -H "Authorization: Token ${INFLUXDB_TOKEN}" \
            "http://${INFLUXDB_HOST:-influxdb}:${INFLUXDB_PORT:-8086}/api/v2/orgs" | grep -q "${INFLUXDB_ORG_NAME}" 2>/dev/null; then
            log "✓ Организация ${INFLUXDB_ORG_NAME} доступна"
        else
            log "✗ Организация ${INFLUXDB_ORG_NAME} недоступна или неверный токен"
            return 1
        fi
        
        if [[ -n "${INFLUXDB_BUCKET_NAME:-}" ]]; then
            if curl -s -H "Authorization: Token ${INFLUXDB_TOKEN}" \
                "http://${INFLUXDB_HOST:-influxdb}:${INFLUXDB_PORT:-8086}/api/v2/buckets" | grep -q "${INFLUXDB_BUCKET_NAME}" 2>/dev/null; then
                log "✓ Bucket ${INFLUXDB_BUCKET_NAME} доступен"
            else
                log "✗ Bucket ${INFLUXDB_BUCKET_NAME} недоступен"
                return 1
            fi
        fi
    fi
    
    return 0
}

# Основная функция проверки
main() {
    log "=== Проверка здоровья системы бэкапов InfluxDB ==="
    
    local exit_code=0
    
    check_influxdb || exit_code=1
    check_influxdb_operations || exit_code=1
    check_recent_backups || exit_code=1
    check_backup_integrity || exit_code=1
    check_disk_space || exit_code=1
    check_processes || exit_code=1
    
    if [[ $exit_code -eq 0 ]]; then
        log "✓ Все проверки пройдены успешно"
    else
        log "✗ Обнаружены проблемы"

        # Антиспам: отправлять уведомление не чаще раза в 6 часов
        local alert_flag="/tmp/backup_alert_sent"
        local alert_interval=$((6 * 3600))
        local should_notify=true

        if [[ -f "$alert_flag" ]]; then
            local last_sent=$(cat "$alert_flag")
            local now=$(date +%s)
            if (( now - last_sent < alert_interval )); then
                should_notify=false
                log "ℹ Уведомление уже отправлялось (интервал 6ч), пропуск"
            fi
        fi

        if [[ "$should_notify" == true ]]; then
            local env_name="${ENVIRONMENT:-unknown}"
            local token="${TELEGRAM_BOT_TOKEN:-${TG_BOT_TOKEN:-}}"
            local chat="${TELEGRAM_CHAT_ID:-${TG_CHAT_ID:-}}"
            if [[ -n "$token" && -n "$chat" ]]; then
                curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
                    -d chat_id="${chat}" \
                    -d text="⚠️ Проблемы с системой бэкапов InfluxDB [${env_name}]. Проверьте логи." \
                    -d parse_mode="HTML" || true
                date +%s > "$alert_flag"
            fi
        fi
    fi
    
    log "=== Проверка завершена ==="
    return $exit_code
}

main "$@"