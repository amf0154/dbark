#!/bin/bash

set -euo pipefail

# Конфигурация
REMOTE_HOST=${REMOTE_MYSQL_HOST:-api.m2m.by}
REMOTE_PORT=${REMOTE_MYSQL_PORT:-3306}
REMOTE_USER=${REMOTE_MYSQL_USER:-root}
REMOTE_PASSWORD=${REMOTE_MYSQL_PASSWORD:-}
REMOTE_DATABASE=${REMOTE_MYSQL_DATABASE:-m2hydro}

LOCAL_HOST=${MYSQL_HOST:-127.0.0.1}
LOCAL_PORT=${MYSQL_PORT:-3306}
LOCAL_USER=${MYSQL_USER:-m2user}
LOCAL_PASSWORD=${MYSQL_PASSWORD:-}
LOCAL_DATABASE=${MYSQL_DATABASE:-m2hydro}

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
            -d text="🔄 MySQL Sync [${env_name}] ${status}: ${message}" \
            -d parse_mode="HTML" || true
    fi
}

# Проверка доступности удаленного сервера
check_remote_server() {
    log "Проверка доступности удаленного сервера ${REMOTE_HOST}:${REMOTE_PORT}..."
    
    local max_attempts=5
    local attempt=0
    
    while ! mysqladmin ping -h"${REMOTE_HOST}" -P"${REMOTE_PORT}" -u"${REMOTE_USER}" -p"${REMOTE_PASSWORD}" --silent; do
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
    
    while ! mysqladmin ping -h"${LOCAL_HOST}" -P"${LOCAL_PORT}" -u"${LOCAL_USER}" -p"${LOCAL_PASSWORD}" --silent; do
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

# Создание дампа с удаленного сервера
create_remote_dump() {
    local timestamp=$(date '+%m%d_%H%M')
    local dump_file="${SYNC_DIR}/d_${timestamp}.sql"
    
    log "Создание дампа с удаленного сервера..."
    log "Команда: mysqldump -h${REMOTE_HOST} -P${REMOTE_PORT} -u${REMOTE_USER} -p[HIDDEN] ${REMOTE_DATABASE}"
    
    # Проверка подключения к базе данных
    log "Проверка доступа к базе данных ${REMOTE_DATABASE}..."
    if ! mysql -h"${REMOTE_HOST}" -P"${REMOTE_PORT}" -u"${REMOTE_USER}" -p"${REMOTE_PASSWORD}" \
        -e "USE \`${REMOTE_DATABASE}\`; SELECT 1;" > /dev/null 2>&1; then
        log "ERROR: Нет доступа к базе данных ${REMOTE_DATABASE}"
        log "Попробуйте проверить:"
        log "  1. Правильность пароля: REMOTE_MYSQL_PASSWORD"
        log "  2. Права пользователя ${REMOTE_USER} на сервере ${REMOTE_HOST}"
        log "  3. Существование базы данных ${REMOTE_DATABASE}"
        return 1
    fi
    log "Доступ к базе данных подтвержден"
    
    # Создание директории для синхронизации
    mkdir -p "$SYNC_DIR"
    
    # Проверка ограничений файловой системы
    log "Проверка директории синхронизации: $SYNC_DIR"
    log "Доступное место: $(df -h "$SYNC_DIR" | awk 'NR==2 {print $4}')"
    
    # Тест создания файла с длинным именем
    local test_file="${SYNC_DIR}/test_long_filename_$(date '+%Y%m%d_%H%M%S').tmp"
    if touch "$test_file" 2>/dev/null; then
        rm -f "$test_file"
        log "Тест длинных имен файлов: OK"
    else
        log "WARNING: Проблемы с длинными именами файлов в $SYNC_DIR"
    fi
    
    # Создание дампа (убираем проблемные опции для MariaDB)
    if mysqldump -h"${REMOTE_HOST}" -P"${REMOTE_PORT}" -u"${REMOTE_USER}" -p"${REMOTE_PASSWORD}" \
        --single-transaction --routines --triggers --lock-tables=false --no-tablespaces --set-gtid-purged=OFF \
        "${REMOTE_DATABASE}" > "$dump_file"; then
        
        log "Дамп успешно создан: $dump_file"
        
        # Проверка размера файла
        local file_size=$(wc -c < "$dump_file" 2>/dev/null || echo "0")
        local size_mb=$((file_size / 1024 / 1024))
        log "Размер дампа: ${size_mb} MB"
        
        if [[ $file_size -lt 1024 ]]; then
            log "WARNING: Размер дампа подозрительно мал: $file_size байт"
            log "Первые 20 строк файла:"
            head -20 "$dump_file" | tee -a "$LOG_FILE"
        fi
        
        echo "$dump_file"
    else
        log "ERROR: Ошибка при создании дампа"
        send_notification "FAILED" "Ошибка создания дампа с ${REMOTE_HOST}"
        exit 1
    fi
}

# Обработка дампа для совместимости с MySQL
process_dump_for_mysql() {
    local source_dump=$1
    local processed_dump="/tmp/processed_$(basename "${source_dump%.sql}").sql"
    
    log "Обработка дампа для совместимости с MySQL..."
    log "Исходный файл: $(basename "$source_dump")"
    log "Обработанный файл: $(basename "$processed_dump")"
    log "Полный путь обработанного файла: $processed_dump"
    
    # Проверка возможности создания файла
    if ! touch "$processed_dump" 2>/dev/null; then
        log "ERROR: Не удается создать файл $processed_dump"
        return 1
    fi
    rm -f "$processed_dump"
    
    # Применение трансформаций для совместимости MariaDB -> MySQL
    sed -e 's/uuid()/(UUID())/g' \
        -e 's/CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP/CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP/g' \
        -e '/^\/\*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT \*\/;$/d' \
        -e '/^\/\*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS \*\/;$/d' \
        -e '/^\/\*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION \*\/;$/d' \
        -e '/^\/\*!40101 SET NAMES utf8mb4 \*\/;$/d' \
        -e '/^\/\*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE \*\/;$/d' \
        -e '/^\/\*!40103 SET TIME_ZONE=.+00:00. \*\/;$/d' \
        -e '/^\/\*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 \*\/;$/d' \
        -e '/^\/\*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 \*\/;$/d' \
        -e '/^\/\*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE=.NO_AUTO_VALUE_ON_ZERO. \*\/;$/d' \
        -e '/^\/\*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 \*\/;$/d' \
        "$source_dump" > "$processed_dump"
    
    # Проверка успешности обработки
    if [[ -f "$processed_dump" ]]; then
        local original_size=$(wc -c < "$source_dump" 2>/dev/null || echo "0")
        local processed_size=$(wc -c < "$processed_dump" 2>/dev/null || echo "0")
        
        log "Обработка завершена:"
        log "  Исходный размер: $((original_size / 1024)) KB"
        log "  Обработанный размер: $((processed_size / 1024)) KB"
        
        # Проверка что файл не пустой
        if [[ $processed_size -lt 100 ]]; then
            log "ERROR: Обработанный файл слишком мал"
            return 1
        fi
        
        # Показать примеры изменений
        log "Примеры применённых изменений:"
        if grep -n "UUID()" "$processed_dump" | head -3; then
            log "  ✓ uuid() заменено на (UUID())"
        fi
        
        # Копируем обработанный файл в sync директорию с коротким именем
        local final_dump="${SYNC_DIR}/proc_$(date '+%H%M').sql"
        cp "$processed_dump" "$final_dump"
        log "Обработанный файл скопирован: $(basename "$final_dump")"
        
        echo "$final_dump"
    else
        log "ERROR: Ошибка при обработке дампа"
        return 1
    fi
}

# Создание резервной копии локальной базы
create_local_backup() {
    log "Создание резервной копии локальной базы данных..."
    
    local backup_file="${SYNC_DIR}/l_$(date '+%m%d_%H%M').sql"
    
    # Проверка существования локальной базы данных
    if mysql -h"${LOCAL_HOST}" -P"${LOCAL_PORT}" -u"${LOCAL_USER}" -p"${LOCAL_PASSWORD}" \
        -e "USE \`${LOCAL_DATABASE}\`;" 2>/dev/null; then
        
        log "Создание резервной копии существующей базы данных ${LOCAL_DATABASE}..."
        
        if mysqldump -h"${LOCAL_HOST}" -P"${LOCAL_PORT}" -u"${LOCAL_USER}" -p"${LOCAL_PASSWORD}" \
            --single-transaction --routines --triggers --events --opt --lock-tables=false \
            "${LOCAL_DATABASE}" > "$backup_file"; then
            
            log "Резервная копия создана: $backup_file"
            
            # Сжимаем резервную копию
            gzip "$backup_file"
            echo "${backup_file}.gz"
        else
            log "WARNING: Не удалось создать резервную копию"
            return 1
        fi
    else
        log "Локальная база данных ${LOCAL_DATABASE} не существует, резервная копия не нужна"
        return 0
    fi
}

# Импорт обработанного дампа
import_processed_dump() {
    local processed_dump=$1
    
    log "Импорт обработанного дампа в локальную базу данных..."
    
    # Создание базы данных если не существует
    log "Создание базы данных ${LOCAL_DATABASE} если не существует..."
    mysql -h"${LOCAL_HOST}" -P"${LOCAL_PORT}" -u"${LOCAL_USER}" -p"${LOCAL_PASSWORD}" \
        -e "CREATE DATABASE IF NOT EXISTS \`${LOCAL_DATABASE}\`;"
    
    # Импорт дампа
    log "Выполнение импорта..."
    log "Команда: mysql -h${LOCAL_HOST} -P${LOCAL_PORT} -u${LOCAL_USER} -p[HIDDEN] ${LOCAL_DATABASE} < $(basename "$processed_dump")"
    
    if mysql -h"${LOCAL_HOST}" -P"${LOCAL_PORT}" -u"${LOCAL_USER}" -p"${LOCAL_PASSWORD}" \
        --init-command="SET SESSION sql_log_bin=0;" \
        "${LOCAL_DATABASE}" < "$processed_dump"; then
        
        log "Импорт завершен успешно"
        
        # Проверка импорта
        local table_count=$(mysql -h"${LOCAL_HOST}" -P"${LOCAL_PORT}" -u"${LOCAL_USER}" -p"${LOCAL_PASSWORD}" \
            -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${LOCAL_DATABASE}';" -s -N)
        
        log "Количество таблиц в импортированной базе: $table_count"
        
        if [[ $table_count -gt 0 ]]; then
            log "✓ Импорт прошел успешно"
            return 0
        else
            log "WARNING: В базе данных нет таблиц"
            return 1
        fi
    else
        log "ERROR: Ошибка при импорте дампа"
        return 1
    fi
}

# Очистка временных файлов
cleanup_temp_files() {
    local keep_files=${1:-1}
    
    log "Очистка временных файлов (оставляем последние $keep_files)..."
    
    # Удаление старых дампов (оставляем последние N файлов)
    find "$SYNC_DIR" -name "d_*.sql" -type f | \
        sort -r | tail -n +$((keep_files + 1)) | xargs -r rm -f
    
    # Удаление старых обработанных файлов
    find "$SYNC_DIR" -name "proc_*.sql" -type f | \
        sort -r | tail -n +$((keep_files + 1)) | xargs -r rm -f
    
    # Удаление старых резервных копий (оставляем последние N файлов)
    find "$SYNC_DIR" -name "l_*.sql.gz" -type f | \
        sort -r | tail -n +$((keep_files + 1)) | xargs -r rm -f
    
    log "Очистка завершена"
}

# Показать статистику синхронизации
show_sync_stats() {
    log "Статистика синхронизации:"
    
    # Информация о удаленной базе
    log "Удаленная база данных (${REMOTE_HOST}):"
    local remote_tables=$(mysql -h"${REMOTE_HOST}" -P"${REMOTE_PORT}" -u"${REMOTE_USER}" -p"${REMOTE_PASSWORD}" \
        -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${REMOTE_DATABASE}';" -s -N 2>/dev/null || echo "N/A")
    log "  Таблиц: $remote_tables"
    
    # Информация о локальной базе
    log "Локальная база данных (${LOCAL_HOST}):"
    local local_tables=$(mysql -h"${LOCAL_HOST}" -P"${LOCAL_PORT}" -u"${LOCAL_USER}" -p"${LOCAL_PASSWORD}" \
        -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${LOCAL_DATABASE}';" -s -N 2>/dev/null || echo "N/A")
    log "  Таблиц: $local_tables"
    
    # Размер файлов синхронизации
    if [[ -d "$SYNC_DIR" ]]; then
        local sync_size=$(du -sh "$SYNC_DIR" 2>/dev/null | cut -f1 || echo "N/A")
        log "Размер файлов синхронизации: $sync_size"
    fi
}

# Показать справку
show_help() {
    echo "Синхронизация MySQL базы данных с удаленного MariaDB сервера"
    echo
    echo "Использование: $0 [КОМАНДА] [ОПЦИИ]"
    echo
    echo "Команды:"
    echo "  sync                Полная синхронизация (дамп + обработка + импорт)"
    echo "  dump                Только создание дампа с удаленного сервера"
    echo "  process <file>      Только обработка существующего дампа"
    echo "  import <file>       Только импорт обработанного дампа"
    echo "  test                Тестирование подключения к удаленному серверу"
    echo "  cleanup [count]     Очистка старых файлов (оставить последние N)"
    echo "  stats               Показать статистику"
    echo "  help                Показать эту справку"
    echo
    echo "Переменные окружения:"
    echo "  REMOTE_MYSQL_HOST     - Хост удаленного сервера (по умолчанию: api.m2m.by)"
    echo "  REMOTE_MYSQL_PORT     - Порт удаленного сервера (по умолчанию: 3306)"
    echo "  REMOTE_MYSQL_USER     - Пользователь удаленного сервера (по умолчанию: root)"
    echo "  REMOTE_MYSQL_PASSWORD - Пароль удаленного сервера"
    echo "  REMOTE_MYSQL_DATABASE - База данных на удаленном сервере (по умолчанию: m2hydro)"
    echo
    echo "Примеры:"
    echo "  $0 sync"
    echo "  $0 dump"
    echo "  $0 process /backups/sync/m2hydro_20250730_144455.sql"
    echo "  $0 import /backups/sync/m2hydro_20250730_144455_processed.sql"
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
            
            # Создание резервной копии локальной базы
            local_backup=$(create_local_backup) || true
            
            # Создание дампа с удаленного сервера
            remote_dump=$(create_remote_dump)
            
            # Обработка дампа для совместимости
            processed_dump=$(process_dump_for_mysql "$remote_dump")
            
            # Импорт обработанного дампа
            if import_processed_dump "$processed_dump"; then
                log "✓ Синхронизация завершена успешно"
                send_notification "SUCCESS" "База данных синхронизирована с ${REMOTE_HOST}"
                
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
        "dump")
            check_remote_server
            remote_dump=$(create_remote_dump)
            log "Дамп создан: $remote_dump"
            ;;
        "process")
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: Укажите файл дампа для обработки"
                show_help
                exit 1
            fi
            processed_dump=$(process_dump_for_mysql "$2")
            log "Обработанный дамп: $processed_dump"
            ;;
        "import")
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: Укажите файл дампа для импорта"
                show_help
                exit 1
            fi
            check_local_server
            local_backup=$(create_local_backup) || true
            import_processed_dump "$2"
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
            
            log "Проверка доступа к базе данных ${REMOTE_DATABASE}... ${REMOTE_USER}:${REMOTE_PASSWORD}"
            if mysql -h"${REMOTE_HOST}" -P"${REMOTE_PORT}" -u"${REMOTE_USER}" -p"${REMOTE_PASSWORD}" \
                -e "USE \`${REMOTE_DATABASE}\`; SELECT COUNT(*) as tables FROM information_schema.tables WHERE table_schema='${REMOTE_DATABASE}';" 2>/dev/null; then
                log "✓ Подключение к удаленной базе данных успешно"
            else
                log "✗ Ошибка подключения к удаленной базе данных"
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