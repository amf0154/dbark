#!/bin/bash

set -euo pipefail

# Конфигурация
REMOTE_HOST=${REMOTE_INFLUXDB_HOST:-api.m2m.by}
REMOTE_PORT=${REMOTE_INFLUXDB_PORT:-8086}
REMOTE_TOKEN=${REMOTE_INFLUXDB_TOKEN:-}
REMOTE_ORG=${REMOTE_INFLUXDB_ORG:-m2m}
REMOTE_BUCKET=${REMOTE_INFLUXDB_BUCKET:-m2hydro}

LOCAL_HOST=${INFLUXDB_HOST:-127.0.0.1}
LOCAL_PORT=${INFLUXDB_PORT:-8086}
LOCAL_TOKEN=${INFLUXDB_TOKEN:-}
LOCAL_ORG=${INFLUXDB_ORG:-m2m}
LOCAL_BUCKET=${INFLUXDB_BUCKET:-m2hydro}

SYNC_DIR="/backups/sync"
LOG_FILE="/var/log/backup/sync.log"

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
            -d text="🔄 InfluxDB Sync [${env_name}] ${status}: ${message}" \
            -d parse_mode="HTML" || true
    fi
}

# Проверка доступности удаленного сервера
check_remote_server() {
    log "Проверка доступности удаленного сервера ${REMOTE_HOST}:${REMOTE_PORT}..."
    
    local max_attempts=5
    local attempt=0
    
    while ! curl -s -I "http://${REMOTE_HOST}:${REMOTE_PORT}/health" > /dev/null; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            log "ERROR: Удаленный сервер недоступен после $max_attempts попыток"
            send_notification "FAILED" "Удаленный сервер ${REMOTE_HOST} недоступен"
            exit 1
        fi
        log "Удаленный сервер не готов, ожидание... (попытка $attempt/$max_attempts)"
        sleep 5
    done
    
    log "Удаленный сервер доступен"
}

# Проверка доступности локального сервера
check_local_server() {
    log "Проверка доступности локального сервера ${LOCAL_HOST}:${LOCAL_PORT}..."
    
    local max_attempts=5
    local attempt=0
    
    while ! curl -s -I "http://${LOCAL_HOST}:${LOCAL_PORT}/health" > /dev/null; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            log "ERROR: Локальный сервер недоступен после $max_attempts попыток"
            send_notification "FAILED" "Локальный сервер ${LOCAL_HOST} недоступен"
            exit 1
        fi
        log "Локальный сервер не готов, ожидание... (попытка $attempt/$max_attempts)"
        sleep 5
    done
    
    log "Локальный сервер доступен"
}

# Создание бэкапа с удаленного сервера
create_remote_backup() {
    local timestamp=$(date '+%m%d_%H%M')
    local backup_file="${SYNC_DIR}/remote_${timestamp}.tar.gz"
    
    log "Создание бэкапа с удаленного сервера..."
    
    # Проверка подключения к удаленному InfluxDB
    log "Проверка доступа к организации ${REMOTE_ORG} и bucket ${REMOTE_BUCKET}..."
    if ! influx bucket list --host "http://${REMOTE_HOST}:${REMOTE_PORT}" \
        --token "${REMOTE_TOKEN}" --org "${REMOTE_ORG}" | grep -q "${REMOTE_BUCKET}"; then
        log "ERROR: Нет доступа к bucket ${REMOTE_BUCKET} в организации ${REMOTE_ORG}"
        log "Попробуйте проверить:"
        log "  1. Правильность токена: REMOTE_INFLUXDB_TOKEN"
        log "  2. Права токена на сервере ${REMOTE_HOST}"
        log "  3. Существование организации ${REMOTE_ORG} и bucket ${REMOTE_BUCKET}"
        return 1
    fi
    log "Доступ к bucket подтвержден"
    
    # Создание директории для синхронизации
    mkdir -p "$SYNC_DIR"
    
    # Проверка ограничений файловой системы
    log "Проверка директории синхронизации: $SYNC_DIR"
    log "Доступное место: $(df -h "$SYNC_DIR" | awk 'NR==2 {print $4}')"
    
    # Создание бэкапа
    if influx backup --host "http://${REMOTE_HOST}:${REMOTE_PORT}" \
        --token "${REMOTE_TOKEN}" --org "${REMOTE_ORG}" \
        --bucket "${REMOTE_BUCKET}" "$backup_file"; then
        
        log "Бэкап успешно создан: $backup_file"
        
        # Проверка размера файла
        local file_size=$(wc -c < "$backup_file" 2>/dev/null || echo "0")
        local size_mb=$((file_size / 1024 / 1024))
        log "Размер бэкапа: ${size_mb} MB"
        
        if [[ $file_size -lt 1024 ]]; then
            log "WARNING: Размер бэкапа подозрительно мал: $file_size байт"
        fi
        
        echo "$backup_file"
    else
        log "ERROR: Ошибка при создании бэкапа"
        send_notification "FAILED" "Ошибка создания бэкапа с ${REMOTE_HOST}"
        exit 1
    fi
}

# Создание резервной копии локального bucket
create_local_backup() {
    log "Создание резервной копии локального bucket..."
    
    local backup_file="${SYNC_DIR}/local_backup_$(date '+%m%d_%H%M').tar.gz"
    
    # Проверка существования локального bucket
    if influx bucket list --host "http://${LOCAL_HOST}:${LOCAL_PORT}" \
        --token "${LOCAL_TOKEN}" --org "${LOCAL_ORG}" | grep -q "${LOCAL_BUCKET}"; then
        
        log "Создание резервной копии существующего bucket ${LOCAL_BUCKET}..."
        
        if influx backup --host "http://${LOCAL_HOST}:${LOCAL_PORT}" \
            --token "${LOCAL_TOKEN}" --org "${LOCAL_ORG}" \
            --bucket "${LOCAL_BUCKET}" "$backup_file"; then
            
            log "Резервная копия создана: $backup_file"
            echo "$backup_file"
        else
            log "WARNING: Не удалось создать резервную копию"
            return 1
        fi
    else
        log "Локальный bucket ${LOCAL_BUCKET} не существует, резервная копия не нужна"
        return 0
    fi
}

# Восстановление бэкапа в локальный InfluxDB
restore_remote_backup() {
    local backup_file=$1
    
    log "Восстановление бэкапа в локальный InfluxDB..."
    
    # Проверка существования bucket и его удаление если нужно
    if influx bucket list --host "http://${LOCAL_HOST}:${LOCAL_PORT}" \
        --token "${LOCAL_TOKEN}" --org "${LOCAL_ORG}" | grep -q "${LOCAL_BUCKET}"; then
        
        log "Удаление существующего bucket ${LOCAL_BUCKET}..."
        influx bucket delete --host "http://${LOCAL_HOST}:${LOCAL_PORT}" \
            --token "${LOCAL_TOKEN}" --org "${LOCAL_ORG}" \
            --name "${LOCAL_BUCKET}" --yes || true
    fi
    
    # Создание нового bucket
    log "Создание нового bucket ${LOCAL_BUCKET}..."
    influx bucket create --host "http://${LOCAL_HOST}:${LOCAL_PORT}" \
        --token "${LOCAL_TOKEN}" --org "${LOCAL_ORG}" \
        --name "${LOCAL_BUCKET}" --retention 0
    
    # Восстановление данных
    log "Выполнение восстановления..."
    log "Команда: influx restore --host http://${LOCAL_HOST}:${LOCAL_PORT} --token [HIDDEN] --org ${LOCAL_ORG} --bucket ${LOCAL_BUCKET} $(basename "$backup_file")"
    
    if influx restore --host "http://${LOCAL_HOST}:${LOCAL_PORT}" \
        --token "${LOCAL_TOKEN}" --org "${LOCAL_ORG}" \
        --bucket "${LOCAL_BUCKET}" "$backup_file"; then
        
        log "Восстановление завершено успешно"
        
        # Проверка восстановления
        local measurement_count=$(influx query --host "http://${LOCAL_HOST}:${LOCAL_PORT}" \
            --token "${LOCAL_TOKEN}" --org "${LOCAL_ORG}" \
            'import "influxdata/influxdb/schema"
             schema.measurements(bucket: "'${LOCAL_BUCKET}'")' 2>/dev/null | wc -l || echo "0")
        
        log "Количество измерений в восстановленном bucket: $measurement_count"
        
        if [[ $measurement_count -gt 0 ]]; then
            log "✓ Восстановление прошло успешно"
            return 0
        else
            log "WARNING: В bucket нет данных"
            return 1
        fi
    else
        log "ERROR: Ошибка при восстановлении бэкапа"
        return 1
    fi
}

# Очистка временных файлов
cleanup_temp_files() {
    local keep_files=${1:-1}
    
    log "Очистка временных файлов (оставляем последние $keep_files)..."
    
    # Удаление старых удаленных бэкапов
    find "$SYNC_DIR" -name "remote_*.tar.gz" -type f | \
        sort -r | tail -n +$((keep_files + 1)) | xargs -r rm -f
    
    # Удаление старых локальных резервных копий
    find "$SYNC_DIR" -name "local_backup_*.tar.gz" -type f | \
        sort -r | tail -n +$((keep_files + 1)) | xargs -r rm -f
    
    log "Очистка завершена"
}

# Показать статистику синхронизации
show_sync_stats() {
    log "Статистика синхронизации:"
    
    # Информация о удаленном InfluxDB
    log "Удаленный InfluxDB (${REMOTE_HOST}):"
    local remote_buckets=$(influx bucket list --host "http://${REMOTE_HOST}:${REMOTE_PORT}" \
        --token "${REMOTE_TOKEN}" --org "${REMOTE_ORG}" 2>/dev/null | wc -l || echo "N/A")
    log "  Buckets: $remote_buckets"
    
    # Информация о локальном InfluxDB
    log "Локальный InfluxDB (${LOCAL_HOST}):"
    local local_buckets=$(influx bucket list --host "http://${LOCAL_HOST}:${LOCAL_PORT}" \
        --token "${LOCAL_TOKEN}" --org "${LOCAL_ORG}" 2>/dev/null | wc -l || echo "N/A")
    log "  Buckets: $local_buckets"
    
    # Размер файлов синхронизации
    if [[ -d "$SYNC_DIR" ]]; then
        local sync_size=$(du -sh "$SYNC_DIR" 2>/dev/null | cut -f1 || echo "N/A")
        log "Размер файлов синхронизации: $sync_size"
    fi
}

# Показать справку
show_help() {
    echo "Синхронизация InfluxDB bucket с удаленного сервера"
    echo
    echo "Использование: $0 [КОМАНДА] [ОПЦИИ]"
    echo
    echo "Команды:"
    echo "  sync                Полная синхронизация (бэкап + восстановление)"
    echo "  backup              Только создание бэкапа с удаленного сервера"
    echo "  restore <file>      Только восстановление из файла бэкапа"
    echo "  test                Тестирование подключения к удаленному серверу"
    echo "  cleanup [count]     Очистка старых файлов (оставить последние N)"
    echo "  stats               Показать статистику"
    echo "  help                Показать эту справку"
    echo
    echo "Переменные окружения:"
    echo "  REMOTE_INFLUXDB_HOST   - Хост удаленного сервера (по умолчанию: api.m2m.by)"
    echo "  REMOTE_INFLUXDB_PORT   - Порт удаленного сервера (по умолчанию: 8086)"
    echo "  REMOTE_INFLUXDB_TOKEN  - Токен удаленного сервера"
    echo "  REMOTE_INFLUXDB_ORG    - Организация на удаленном сервере (по умолчанию: m2m)"
    echo "  REMOTE_INFLUXDB_BUCKET - Bucket на удаленном сервере (по умолчанию: m2hydro)"
    echo
    echo "Примеры:"
    echo "  $0 sync"
    echo "  $0 backup"
    echo "  $0 restore /backups/sync/remote_0730_1445.tar.gz"
    echo "  $0 cleanup 3"
}

# Основная функция
main() {
    # Создание директорий
    mkdir -p "$SYNC_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    case "${1:-sync}" in
        "sync")
            log "=== Начало полной синхронизации ==="
            
            check_remote_server
            check_local_server
            
            # Создание резервной копии локального bucket
            local_backup=$(create_local_backup) || true
            
            # Создание бэкапа с удаленного сервера
            remote_backup=$(create_remote_backup)
            
            # Восстановление бэкапа
            if restore_remote_backup "$remote_backup"; then
                log "✓ Синхронизация завершена успешно"
                send_notification "SUCCESS" "Bucket синхронизирован с ${REMOTE_HOST}"
                
                # Показать статистику
                show_sync_stats
                
                # Очистка старых файлов
                cleanup_temp_files 3
            else
                log "✗ Ошибка при синхронизации"
                send_notification "FAILED" "Ошибка синхронизации с ${REMOTE_HOST}"
                exit 1
            fi
            
            log "=== Синхронизация завершена ==="
            ;;
        "backup")
            check_remote_server
            remote_backup=$(create_remote_backup)
            log "Бэкап создан: $remote_backup"
            ;;
        "restore")
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: Укажите файл бэкапа для восстановления"
                show_help
                exit 1
            fi
            check_local_server
            local_backup=$(create_local_backup) || true
            restore_remote_backup "$2"
            ;;
        "cleanup")
            cleanup_temp_files "${2:-1}"
            ;;
        "stats")
            show_sync_stats
            ;;
        "test")
            log "Тестирование подключения к удаленному серверу..."
            check_remote_server
            
            log "Проверка доступа к организации ${REMOTE_ORG} и bucket ${REMOTE_BUCKET}..."
            if influx bucket list --host "http://${REMOTE_HOST}:${REMOTE_PORT}" \
                --token "${REMOTE_TOKEN}" --org "${REMOTE_ORG}" | grep -q "${REMOTE_BUCKET}"; then
                log "✓ Подключение к удаленному InfluxDB успешно"
            else
                log "✗ Ошибка подключения к удаленному InfluxDB"
            fi
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            echo "ERROR: Неизвестная команда: $1"
            show_help
            exit 1
            ;;
    esac
}

# Запуск
main "$@"