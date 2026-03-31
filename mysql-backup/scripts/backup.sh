#!/bin/bash

set -euo pipefail

# Конфигурация
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-}
MYSQL_DATABASE=${MYSQL_DATABASE:-}
MYSQL_USER=${MYSQL_USER:-}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-}
BACKUP_DIR="/backups"
STORAGE_DIR="/backup-storage"
RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
COMPRESSION=${BACKUP_COMPRESSION:-true}
LOG_FILE="/var/log/backup/backup.log"

# Проверка обязательных переменных
if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: MYSQL_ROOT_PASSWORD не задан" | tee -a "$LOG_FILE"
    
    # Отправка уведомления о проблеме
    local env_name="${ENVIRONMENT:-unknown}"
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="⚠️ Проблемы с системой бэкапов MySQL [${env_name}]. Проверьте логи." \
            -d parse_mode="HTML" || true
    fi
    
    exit 1
fi

# Опции бэкапа
BACKUP_TYPE=${BACKUP_TYPE:-full}
BACKUP_SINGLE_TRANSACTION=${BACKUP_SINGLE_TRANSACTION:-true}
BACKUP_ROUTINES=${BACKUP_ROUTINES:-true}
BACKUP_TRIGGERS=${BACKUP_TRIGGERS:-true}
BACKUP_EVENTS=${BACKUP_EVENTS:-true}

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
            -d text="🗄️ MySQL Backup [${env_name}] ${status}: ${message}" \
            -d parse_mode="HTML" || true
    fi
    
    if [[ -n "${WEBHOOK_URL:-}" ]]; then
        curl -s -X POST "${WEBHOOK_URL}" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"${status}\",\"message\":\"${message}\",\"timestamp\":\"$(date -Iseconds)\"}" || true
    fi
}

# Проверка доступности MySQL
check_mysql() {
    log "Проверка доступности MySQL..."
    
    local max_attempts=5
    local attempt=0
    
    while ! mysqladmin ping -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" --silent; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            log "ERROR: MySQL недоступен после $max_attempts попыток"
            send_notification "FAILED" "MySQL недоступен на ${MYSQL_HOST}:${MYSQL_PORT}"
            exit 1
        fi
        log "MySQL не готов, ожидание... (попытка $attempt/$max_attempts)"
        sleep 5
    done
    
    log "MySQL доступен"
}

# Получение списка баз данных для бэкапа
get_databases() {
    if [[ -n "${MYSQL_DATABASE}" ]]; then
        echo "${MYSQL_DATABASE}"
    else
        # Получаем все пользовательские базы данных (исключаем системные)
        mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
            -e "SHOW DATABASES;" | grep -v -E '^(Database|information_schema|performance_schema|mysql|sys)$'
    fi
}

# Создание бэкапа
create_backup() {
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local environment=${ENVIRONMENT:-staging}
    local prefix=${BACKUP_PREFIX:-backup}
    local backup_name="${prefix}_${environment}_${timestamp}"
    local backup_path="${BACKUP_DIR}/${backup_name}.sql"
    
    log "Начало создания бэкапа: ${backup_name}"
    
    # Построение команды mysqldump
    local mysqldump_cmd="mysqldump -h${MYSQL_HOST} -P${MYSQL_PORT} -u root -p${MYSQL_ROOT_PASSWORD}"
    
    # Добавление опций
    if [[ "${BACKUP_SINGLE_TRANSACTION}" == "true" ]]; then
        mysqldump_cmd+=" --single-transaction"
    fi
    
    if [[ "${BACKUP_ROUTINES}" == "true" ]]; then
        mysqldump_cmd+=" --routines"
    fi
    
    if [[ "${BACKUP_TRIGGERS}" == "true" ]]; then
        mysqldump_cmd+=" --triggers"
    fi
    
    if [[ "${BACKUP_EVENTS}" == "true" ]]; then
        mysqldump_cmd+=" --events"
    fi
    
    # Добавляем стандартные опции
    mysqldump_cmd+=" --opt --lock-tables=false --flush-logs --set-gtid-purged=OFF"
    
    # Определение типа бэкапа
    case "${BACKUP_TYPE}" in
        "full")
            # Полный бэкап всех указанных баз данных
            local databases
            databases=$(get_databases)
            
            if [[ -z "$databases" ]]; then
                log "ERROR: Не найдены базы данных для бэкапа"
                send_notification "FAILED" "Не найдены базы данных для бэкапа"
                exit 1
            fi
            
            log "Создание полного бэкапа баз данных: $databases"
            mysqldump_cmd+=" --databases $databases"
            ;;
        "schema")
            # Только структура
            local databases
            databases=$(get_databases)
            log "Создание бэкапа структуры баз данных: $databases"
            mysqldump_cmd+=" --no-data --databases $databases"
            ;;
        "data")
            # Только данные
            local databases
            databases=$(get_databases)
            log "Создание бэкапа данных баз данных: $databases"
            mysqldump_cmd+=" --no-create-info --databases $databases"
            ;;
        *)
            log "ERROR: Неизвестный тип бэкапа: ${BACKUP_TYPE}"
            exit 1
            ;;
    esac
    
    log "Выполнение команды: ${mysqldump_cmd} > ${backup_path}"
    
    # Выполнение бэкапа
    if eval "${mysqldump_cmd}" > "$backup_path"; then
        log "Бэкап успешно создан: ${backup_path}"
        
        # Проверка размера файла
        local file_size=$(wc -c < "$backup_path" 2>/dev/null || echo "0")
        if [[ $file_size -lt 1024 ]]; then
            log "WARNING: Размер бэкапа подозрительно мал: $file_size байт"
            log "Содержимое файла:"
            head -20 "$backup_path" | tee -a "$LOG_FILE"
        fi
        
        # Сжатие бэкапа
        if [[ "$COMPRESSION" == "true" ]]; then
            log "Сжатие бэкапа..."
            gzip "$backup_path"
            backup_path="${backup_path}.gz"
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
        
        send_notification "SUCCESS" "Бэкап создан успешно. Размер: ${backup_size}, Тип: ${BACKUP_TYPE}"
        
    else
        log "ERROR: Ошибка при создании бэкапа"
        send_notification "FAILED" "Ошибка при создании бэкапа MySQL"
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
    find "$BACKUP_DIR" -name "*_*_*.sql*" -type f -mtime +${RETENTION_DAYS} -delete
    
    # Бэкапы в постоянном хранилище
    if [[ -d "$STORAGE_DIR" ]]; then
        find "$STORAGE_DIR" -name "*_*_*.sql*" -type f -mtime +${RETENTION_DAYS} -delete
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

# Проверка целостности бэкапа
verify_backup() {
    local backup_path=$1
    
    log "Проверка целостности бэкапа..."
    
    if [[ "$backup_path" == *.gz ]]; then
        # Проверка сжатого файла
        if gzip -t "$backup_path"; then
            log "Сжатый бэкап прошел проверку целостности"
        else
            log "ERROR: Сжатый бэкап поврежден"
            return 1
        fi
        
        # Проверка SQL содержимого
        if zcat "$backup_path" | head -20 | grep -q "MySQL dump"; then
            log "SQL содержимое корректно"
        else
            log "WARNING: SQL содержимое может быть некорректным"
        fi
    else
        # Проверка несжатого файла
        if head -20 "$backup_path" | grep -q "MySQL dump"; then
            log "SQL содержимое корректно"
        else
            log "WARNING: SQL содержимое может быть некорректным"
        fi
    fi
}

# Основная функция
main() {
    log "=== Начало процедуры бэкапа MySQL ==="
    
    # Создание директории для логов
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Проверки
    check_mysql
    check_disk_space
    
    # Создание бэкапа
    create_backup
    
    # Проверка целостности
    local latest_backup=$(find "$BACKUP_DIR" -name "*_*_*.sql*" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
    if [[ -n "$latest_backup" ]]; then
        verify_backup "$latest_backup"
    fi
    
    # Очистка старых бэкапов
    cleanup_old_backups
    
    log "=== Процедура бэкапа завершена ==="
}

# Запуск
main "$@"