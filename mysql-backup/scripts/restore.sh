#!/bin/bash

set -euo pipefail

# Конфигурация
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE:-}
BACKUP_DIR="/backups"
STORAGE_DIR="/backup-storage"
LOG_FILE="/var/log/backup/restore.log"

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
            -d text="🔄 MySQL Restore [${env_name}] ${status}: ${message}" \
            -d parse_mode="HTML" || true
    fi
}

# Показать доступные бэкапы
list_backups() {
    log "Доступные бэкапы:"
    echo
    echo "=== Локальные бэкапы ==="
    if ls -la "$BACKUP_DIR" | grep -E "(backup_|m2_|mysql_).*(\.sql\.gz|\.sql)$" >/dev/null 2>&1; then
        ls -la "$BACKUP_DIR" | grep -E "(backup_|m2_|mysql_).*(\.sql\.gz|\.sql)$" | while read -r line; do
            if echo "$line" | grep -q "\.sql\.gz$"; then
                echo "$line (сжатый)"
            elif echo "$line" | grep -q "\.sql$"; then
                echo "$line (несжатый)"
            else
                echo "$line"
            fi
        done
    else
        echo "Нет обычных бэкапов"
    fi
    echo
    echo "=== Pre-restore бэкапы ==="
    if ls -la "$BACKUP_DIR" | grep -E "pre-restore.*(\.sql\.gz|\.sql)$" >/dev/null 2>&1; then
        ls -la "$BACKUP_DIR" | grep -E "pre-restore.*(\.sql\.gz|\.sql)$" | while read -r line; do
            if echo "$line" | grep -q "\.sql\.gz$"; then
                echo "$line (сжатый)"
            elif echo "$line" | grep -q "\.sql$"; then
                echo "$line (несжатый)"
            else
                echo "$line"
            fi
        done
    else
        echo "Нет pre-restore бэкапов"
    fi
    echo
    
    if [[ -d "$STORAGE_DIR" ]]; then
        echo "=== Бэкапы в постоянном хранилище ==="
        if ls -la "$STORAGE_DIR" | grep -E "(backup_|m2_|mysql_|pre-restore).*(\.sql\.gz|\.sql)$" >/dev/null 2>&1; then
            ls -la "$STORAGE_DIR" | grep -E "(backup_|m2_|mysql_|pre-restore).*(\.sql\.gz|\.sql)$" | while read -r line; do
                if echo "$line" | grep -q "\.sql\.gz$"; then
                    echo "$line (сжатый)"
                elif echo "$line" | grep -q "\.sql$"; then
                    echo "$line (несжатый)"
                else
                    echo "$line"
                fi
            done
        else
            echo "Нет бэкапов в хранилище"
        fi
        echo
    fi
    
    if [[ "${GOOGLE_DRIVE_ENABLED:-false}" == "true" ]]; then
        echo "=== Облачные бэкапы (Google Drive) ==="
        if python3 /app/scripts/google_drive.py list 2>/dev/null; then
            echo
        else
            echo "Google Drive недоступен (библиотеки не установлены или не настроен)"
            echo
        fi
    fi
}

# Загрузка бэкапа из облака
download_from_cloud() {
    local backup_name=$1
    local local_path="${BACKUP_DIR}/${backup_name}"
    
    if [[ "${GOOGLE_DRIVE_ENABLED:-false}" == "true" ]]; then
        log "Поиск и загрузка бэкапа из Google Drive: ${backup_name}" >&2
        
        # Проверяем существует ли файл в Google Drive
        local file_info=$(python3 /app/scripts/google_drive.py find "$backup_name" 2>/dev/null)
        
        if [[ -n "$file_info" && "$file_info" != *"не найден"* ]]; then
            log "Найден файл в Google Drive" >&2
            
            # Создаем директорию если не существует
            mkdir -p "$(dirname "$local_path")"
            
            # Определяем правильное имя файла для загрузки
            local actual_filename="$backup_name"
            if [[ "$backup_name" != *.sql && "$backup_name" != *.sql.gz ]]; then
                # Пробуем добавить расширения
                if python3 /app/scripts/google_drive.py find "${backup_name}.sql.gz" 2>/dev/null | grep -q "Найден файл"; then
                    actual_filename="${backup_name}.sql.gz"
                elif python3 /app/scripts/google_drive.py find "${backup_name}.sql" 2>/dev/null | grep -q "Найден файл"; then
                    actual_filename="${backup_name}.sql"
                fi
            fi
            
            # Скачиваем файл с правильным именем
            log "Попытка загрузки файла: $actual_filename" >&2
            if python3 /app/scripts/google_drive.py download "$actual_filename" "$local_path" >/dev/null 2>&1; then
                # Проверяем размер загруженного файла
                if [[ -s "$local_path" ]]; then
                    local file_size=$(ls -lh "$local_path" | awk '{print $5}')
                    log "Файл успешно загружен из Google Drive: ${local_path} (размер: $file_size)" >&2
                    echo "$local_path"
                    return 0
                else
                    log "ERROR: Загруженный файл пустой или поврежден: ${local_path}" >&2
                    log "Проверяем что произошло при загрузке..." >&2
                    ls -la "$local_path" >&2 || log "Файл не существует" >&2
                    rm -f "$local_path"
                    return 1
                fi
            else
                log "ERROR: Ошибка загрузки файла из Google Drive" >&2
                log "Проверяем доступность файла в Google Drive..." >&2
                python3 /app/scripts/google_drive.py find "$actual_filename" >&2
                return 1
            fi
        else
            log "ERROR: Бэкап не найден в Google Drive: ${backup_name}" >&2
            log "Доступные бэкапы в Google Drive:" >&2
            python3 /app/scripts/google_drive.py list | head -10 >&2
            return 1
        fi
    else
        log "ERROR: Google Drive не настроен" >&2
        return 1
    fi
}

# Подготовка бэкапа к восстановлению
prepare_backup() {
    local backup_path=$1
    
    if [[ "$backup_path" == *.gz ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Распаковка сжатого бэкапа..." >&2
        local uncompressed_path="${backup_path%.gz}"
        
        if [[ ! -f "$uncompressed_path" ]] || [[ "$backup_path" -nt "$uncompressed_path" ]]; then
            gunzip -c "$backup_path" > "$uncompressed_path"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Бэкап распакован: $uncompressed_path" >&2
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Используется существующий распакованный файл: $uncompressed_path" >&2
        fi
        
        echo "$uncompressed_path"
    else
        echo "$backup_path"
    fi
}

# Обработка SQL файла для совместимости
process_sql_for_compatibility() {
    local source_file=$1
    local output_file=$2
    
    log "Обработка SQL файла для совместимости..."
    
    # Создаем временный файл для обработки
    local temp_file="/tmp/mysql_compat_$$"
    
    # Обрабатываем файл построчно для более точной обработки
    while IFS= read -r line; do
        # Пропускаем проблемные строки с GTID
        if [[ "$line" =~ @@GLOBAL\.GTID_PURGED ]] || [[ "$line" =~ SET.*GTID_PURGED ]]; then
            echo "-- Removed GTID_PURGED command for compatibility" >> "$temp_file"
            continue
        fi
        
        # Исправляем проблемные SET команды
        if [[ "$line" =~ ^SET.*@OLD_SQL_MODE.*SQL_MODE= ]]; then
            # Разбиваем составную SET команду на отдельные
            echo "SET @OLD_SQL_MODE=@@SQL_MODE;" >> "$temp_file"
            echo "SET SQL_MODE='';" >> "$temp_file"
            continue
        fi
        
        # Исправляем NULL значения для sql_mode
        if [[ "$line" =~ SET.*sql_mode.*NULL ]]; then
            line=$(echo "$line" | sed "s/sql_mode='NULL'/sql_mode=''/g")
        fi
        
        # Копируем обычные строки как есть
        echo "$line" >> "$temp_file"
        
    done < "$source_file"
    
    mv "$temp_file" "$output_file"
    
    log "SQL файл обработан для совместимости"
}

# Фильтрация SQL файла для восстановления только существующих таблиц
filter_existing_tables_only() {
    local source_file=$1
    local database_name=$2
    local output_file=$3
    
    log "Фильтрация SQL файла для существующих таблиц в базе $database_name..."
    
    # Получаем список существующих таблиц
    local existing_tables=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
        -D "$database_name" -e "SHOW TABLES;" 2>/dev/null | tail -n +2 | tr '\n' '|' | sed 's/|$//')
    
    if [[ -z "$existing_tables" ]]; then
        log "WARNING: Не удалось получить список таблиц или база данных пуста"
        cp "$source_file" "$output_file"
        return
    fi
    
    log "Существующие таблицы: $(echo "$existing_tables" | tr '|' ' ')"
    
    # Создаем временный файл для фильтрации
    local temp_file="/tmp/mysql_filter_$$"
    
    # Копируем заголовок (комментарии и настройки)
    grep -E "^/\*|^#|^--|^SET " "$source_file" > "$temp_file"
    
    # Фильтруем INSERT команды только для существующих таблиц
    local filtered_inserts=0
    local total_inserts=0
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^INSERT\ INTO\ \`?([^\ \`]+)\`? ]]; then
            total_inserts=$((total_inserts + 1))
            local table_name="${BASH_REMATCH[1]}"
            
            if [[ "$existing_tables" =~ (^|[|])$table_name([|]|$) ]]; then
                echo "$line" >> "$temp_file"
                filtered_inserts=$((filtered_inserts + 1))
            fi
        elif [[ ! "$line" =~ ^INSERT\ INTO ]]; then
            # Копируем все не-INSERT строки (комментарии, настройки и т.д.)
            echo "$line" >> "$temp_file"
        fi
    done < "$source_file"
    
    mv "$temp_file" "$output_file"
    
    log "Фильтрация завершена:"
    log "  Всего INSERT команд: $total_inserts"
    log "  Отфильтровано для существующих таблиц: $filtered_inserts"
    log "  Пропущено (таблицы не существуют): $((total_inserts - filtered_inserts))"
}

# Проверка состояния MySQL перед восстановлением
check_mysql_before_restore() {
    local clean_before_restore=${1:-false}
    local filter_existing_tables=${2:-false}
    local prepared_backup=${3:-}
    
    log "Проверка состояния MySQL перед восстановлением..."
    
    if ! mysqladmin ping -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" --silent; then
        log "ERROR: MySQL недоступен"
        return 1
    fi
    
    # Проверка наличия данных
    log "Проверка текущего состояния MySQL..."
    
    # Дополнительная проверка для бэкапов только с данными (если prepared_backup доступен)
    local create_tables=0
    local insert_statements=0
    
    if [[ -n "${prepared_backup:-}" && -f "$prepared_backup" ]]; then
        create_tables=$(grep -E "^CREATE TABLE" "$prepared_backup" | wc -l)
        insert_statements=$(grep -E "^INSERT INTO" "$prepared_backup" | wc -l)
    fi
    
    if [[ $create_tables -eq 0 && $insert_statements -gt 0 && "$clean_before_restore" == "true" ]]; then
        echo "❌ ОШИБКА КОНФИГУРАЦИИ ❌"
        echo "Нельзя использовать очистку базы данных с бэкапом, содержащим только данные!"
        echo "Бэкап не содержит структуру таблиц (CREATE TABLE команды)."
        echo ""
        echo "Варианты решения:"
        echo "1. Используйте опции 1 или 2 (без очистки) - данные добавятся к существующим таблицам"
        echo "2. Используйте полный бэкап, содержащий и структуру, и данные"
        echo "3. Сначала создайте структуру таблиц, затем восстановите данные"
        log "Восстановление отменено: несовместимость бэкапа и опции очистки"
        return 1
    fi
    
    if [[ "$clean_before_restore" == "true" ]]; then
        echo "⚠️  КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ ⚠️"
        echo "Будет выполнена ПОЛНАЯ ОЧИСТКА базы данных!"
        echo "ВСЕ СУЩЕСТВУЮЩИЕ ДАННЫЕ БУДУТ БЕЗВОЗВРАТНО УДАЛЕНЫ!"
        echo ""
        echo "Продолжить с очисткой и восстановлением? (y/N)"
    else
        if [[ $create_tables -eq 0 && $insert_statements -gt 0 ]]; then
            if [[ "$filter_existing_tables" == "true" ]]; then
                echo "ℹ️  РЕЖИМ ФИЛЬТРАЦИИ: Восстановление только существующих таблиц"
                echo "Данные для отсутствующих таблиц будут пропущены."
                echo ""
            else
                echo "⚠️  ВНИМАНИЕ: Бэкап содержит только данные ⚠️"
                echo "Структура таблиц должна уже существовать в целевой базе данных."
                echo "Данные будут добавлены к существующим таблицам."
                echo "Если некоторые таблицы отсутствуют, используйте опцию 5."
                echo ""
            fi
        fi
        echo "ВНИМАНИЕ: Восстановление может перезаписать существующие данные!"
        echo "Продолжить восстановление? (y/N)"
    fi
    
    read -r confirmation
    if [[ "$confirmation" != "y" && "$confirmation" != "Y" ]]; then
        log "Восстановление отменено пользователем"
        return 1
    fi
}

# Создание резервной копии перед восстановлением
create_pre_restore_backup() {
    log "Создание резервной копии перед восстановлением..."
    
    local pre_restore_backup="/backups/pre-restore-$(date '+%Y-%m-%d_%H-%M-%S').sql"
    
    # Получаем список баз данных для бэкапа
    local databases
    if [[ -n "${MYSQL_DATABASE}" ]]; then
        databases="${MYSQL_DATABASE}"
    else
        databases=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
            -e "SHOW DATABASES;" | grep -v -E '^(Database|information_schema|performance_schema|mysql|sys)$' | tr '\n' ' ')
    fi
    
    if [[ -n "$databases" ]]; then
        log "Создание резервной копии баз данных: $databases"
        
        if mysqldump -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
            --single-transaction --routines --triggers --events --opt --lock-tables=false --set-gtid-purged=OFF \
            --databases $databases > "$pre_restore_backup"; then
            
            log "Резервная копия создана: ${pre_restore_backup}"
            
            # Сжимаем резервную копию
            gzip "$pre_restore_backup"
            echo "${pre_restore_backup}.gz"
        else
            log "WARNING: Не удалось создать резервную копию"
            return 1
        fi
    else
        log "WARNING: Нет баз данных для резервного копирования"
        return 1
    fi
}

# Анализ содержимого бэкапа
analyze_backup() {
    local backup_path=$1
    
    log "Анализ содержимого бэкапа..."
    
    local prepared_backup
    prepared_backup=$(prepare_backup "$backup_path")
    
    # Проверка заголовка MySQL dump
    if head -10 "$prepared_backup" | grep -q "MySQL dump"; then
        log "✓ Корректный MySQL dump файл"
    else
        log "WARNING: Файл может не быть корректным MySQL dump"
        log "Первые 10 строк файла:"
        head -10 "$prepared_backup" | tee -a "$LOG_FILE"
    fi
    
    # Поиск баз данных в бэкапе
    local databases=$(grep -E "^CREATE DATABASE|^USE " "$prepared_backup" | head -10)
    if [[ -n "$databases" ]]; then
        log "Найденные базы данных в бэкапе:"
        echo "$databases" | sed 's/^/  /' | tee -a "$LOG_FILE"
    else
        log "WARNING: В бэкапе не найдены команды CREATE DATABASE или USE"
        log "Возможно, нужно указать целевую базу данных при восстановлении"
    fi
    
    # Анализ структуры бэкапа
    local create_tables=$(grep -E "^CREATE TABLE" "$prepared_backup" | wc -l)
    local insert_statements=$(grep -E "^INSERT INTO" "$prepared_backup" | wc -l)
    local drop_tables=$(grep -E "^DROP TABLE" "$prepared_backup" | wc -l)
    
    log "Структура бэкапа:"
    log "  CREATE TABLE команд: $create_tables"
    log "  INSERT INTO команд: $insert_statements"
    log "  DROP TABLE команд: $drop_tables"
    
    if [[ $create_tables -eq 0 && $insert_statements -gt 0 ]]; then
        log "⚠️  ВНИМАНИЕ: Бэкап содержит только данные (INSERT), но не содержит структуру таблиц (CREATE TABLE)"
        log "Для успешного восстановления таблицы должны уже существовать в целевой базе данных"
        log "Или используйте полный бэкап, содержащий и структуру, и данные"
    elif [[ $create_tables -gt 0 ]]; then
        log "✓ Бэкап содержит структуру таблиц"
        
        # Показываем несколько примеров таблиц
        local sample_tables=$(grep -E "^CREATE TABLE" "$prepared_backup" | head -3 | sed 's/CREATE TABLE[^`]*`\([^`]*\)`.*/  - \1/')
        if [[ -n "$sample_tables" ]]; then
            log "Примеры таблиц:"
            echo "$sample_tables" | tee -a "$LOG_FILE"
        fi
    fi
    
    # Проверка размера
    local file_size=$(wc -c < "$prepared_backup" 2>/dev/null || echo "0")
    local size_mb=$((file_size / 1024 / 1024))
    log "Размер бэкапа: ${size_mb} MB"
    
    if [[ $file_size -lt 1024 ]]; then
        log "WARNING: Размер бэкапа подозрительно мал"
        log "Первые 20 строк файла:"
        head -20 "$prepared_backup" | tee -a "$LOG_FILE"
    fi
}

# Восстановление из бэкапа
restore_backup() {
    local backup_path=$1
    local target_database=${2:-}
    local clean_before_restore=${3:-false}
    local filter_existing_tables=${4:-false}
    
    log "Начало восстановления из: ${backup_path}"
    if [[ "$clean_before_restore" == "true" ]]; then
        log "ВНИМАНИЕ: Будет выполнена предварительная очистка базы данных!"
    fi
    if [[ "$filter_existing_tables" == "true" ]]; then
        log "РЕЖИМ: Восстановление только существующих таблиц"
    fi
    
    # Проверка существования файла бэкапа
    if [[ ! -f "$backup_path" ]]; then
        log "ERROR: Файл бэкапа не существует: ${backup_path}"
        return 1
    fi
    
    # Подготовка бэкапа
    local prepared_backup
    prepared_backup=$(prepare_backup "$backup_path")
    
    # Анализ бэкапа
    analyze_backup "$backup_path"
    
    # Предварительная обработка SQL файла для совместимости
    local processed_backup="${prepared_backup}.processed"
    process_sql_for_compatibility "$prepared_backup" "$processed_backup"
    prepared_backup="$processed_backup"
    
    # Фильтрация для существующих таблиц если требуется
    if [[ "$filter_existing_tables" == "true" ]]; then
        local filtered_backup="${prepared_backup}.filtered"
        filter_existing_tables_only "$prepared_backup" "$target_database" "$filtered_backup"
        prepared_backup="$filtered_backup"
    fi
    
    # Проверки перед восстановлением
    check_mysql_before_restore "$clean_before_restore" "$filter_existing_tables" "$prepared_backup"
    
    # Создание резервной копии
    local pre_restore_backup
    pre_restore_backup=$(create_pre_restore_backup) || true
    
    # Предварительная очистка если требуется
    if [[ "$clean_before_restore" == "true" ]]; then
        log "========================================="
        log "Предварительная очистка базы данных"
        log "========================================="
        
        if [[ -n "$target_database" ]]; then
            log "Очистка базы данных: $target_database"
            mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
                -e "DROP DATABASE IF EXISTS \`${target_database}\`; CREATE DATABASE \`${target_database}\`;" || {
                log "ERROR: Не удалось очистить базу данных $target_database"
                return 1
            }
            log "База данных $target_database успешно очищена и пересоздана"
        elif [[ -n "${MYSQL_DATABASE:-}" ]]; then
            log "Очистка базы данных по умолчанию: ${MYSQL_DATABASE}"
            mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
                -e "DROP DATABASE IF EXISTS \`${MYSQL_DATABASE}\`; CREATE DATABASE \`${MYSQL_DATABASE}\`;" || {
                log "ERROR: Не удалось очистить базу данных ${MYSQL_DATABASE}"
                return 1
            }
            log "База данных ${MYSQL_DATABASE} успешно очищена и пересоздана"
        else
            log "WARNING: Полная очистка всех баз данных не поддерживается из соображений безопасности"
            log "Укажите конкретную базу данных для очистки"
            return 1
        fi
    fi
    
    log "========================================="
    log "Начало процесса восстановления данных"
    log "========================================="
    
    # Выполнение восстановления
    local restore_success=false
    
    # Проверяем есть ли в бэкапе команды CREATE DATABASE или USE
    local has_database_commands=$(grep -E "^CREATE DATABASE|^USE " "$prepared_backup" | wc -l)
    
    if [[ -n "$target_database" ]]; then
        log "Восстановление в конкретную базу данных: $target_database"
        
        # Создание базы данных если не существует
        mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
            -e "CREATE DATABASE IF NOT EXISTS \`${target_database}\`;"
        
        # Восстановление в конкретную базу с дополнительными опциями совместимости
        if mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
            --init-command="SET SESSION sql_log_bin=0; SET SESSION sql_mode=''; SET SESSION foreign_key_checks=0;" \
            --force \
            "$target_database" < "$prepared_backup"; then
            restore_success=true
        fi
    elif [[ $has_database_commands -gt 0 ]]; then
        log "Полное восстановление из бэкапа (содержит команды баз данных)"
        
        # Полное восстановление с дополнительными опциями совместимости
        if mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
            --init-command="SET SESSION sql_log_bin=0; SET SESSION sql_mode=''; SET SESSION foreign_key_checks=0;" \
            --force \
            < "$prepared_backup"; then
            restore_success=true
        fi
    else
        log "WARNING: Бэкап не содержит команд CREATE DATABASE или USE"
        log "Попробуем восстановить в базу данных по умолчанию или укажите конкретную базу"
        
        # Если задана переменная MYSQL_DATABASE, используем её
        if [[ -n "${MYSQL_DATABASE:-}" ]]; then
            log "Восстанавливаем в базу данных из переменной MYSQL_DATABASE: ${MYSQL_DATABASE}"
            
            # Создание базы данных если не существует
            mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
                -e "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;"
            
            # Восстановление в базу по умолчанию с дополнительными опциями совместимости
            if mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
                --init-command="SET SESSION sql_log_bin=0; SET SESSION sql_mode=''; SET SESSION foreign_key_checks=0;" \
                --force \
                "${MYSQL_DATABASE}" < "$prepared_backup"; then
                restore_success=true
            fi
        else
            log "ERROR: Не удается определить целевую базу данных"
            log "Укажите базу данных через опцию '2) Восстановление в конкретную базу данных'"
            return 1
        fi
    fi
    
    if [[ "$restore_success" == "true" ]]; then
        log "Восстановление завершено успешно"
        send_notification "SUCCESS" "Данные восстановлены из бэкапа: $(basename "$backup_path")"
        
        # Очистка временных файлов
        if [[ "$prepared_backup" != "$backup_path" && -f "$prepared_backup" ]]; then
            rm -f "$prepared_backup"
        fi
        
    else
        log "ERROR: Ошибка при восстановлении"
        send_notification "FAILED" "Ошибка при восстановлении из бэкапа: $(basename "$backup_path")"
        
        # Попытка восстановить предыдущее состояние
        if [[ -n "${pre_restore_backup:-}" && -f "$pre_restore_backup" ]]; then
            log "Попытка восстановления предыдущего состояния..."
            local pre_restore_prepared
            pre_restore_prepared=$(prepare_backup "$pre_restore_backup")
            
            mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
                < "$pre_restore_prepared" || log "ERROR: Не удалось восстановить предыдущее состояние"
        fi
        
        return 1
    fi
}

# Интерактивное восстановление
interactive_restore() {
    echo "=== Интерактивное восстановление MySQL ==="
    echo
    
    list_backups
    
    echo "Введите имя файла бэкапа для восстановления (таблица ${MYSQL_DATABASE}):"
    read -r backup_name
    
    # Поиск бэкапа
    local backup_path=""
    
    # Проверка файлов в локальной директории - точное совпадение
    if [[ -f "${BACKUP_DIR}/${backup_name}" ]]; then
        # Проверяем, что файл не пустой
        if [[ -s "${BACKUP_DIR}/${backup_name}" ]]; then
            backup_path="${BACKUP_DIR}/${backup_name}"
        else
            log "Найден файл, но он пустой. Удаляем и попробуем загрузить заново..."
            rm -f "${BACKUP_DIR}/${backup_name}"
            backup_path=""
        fi
    # Проверка с добавлением .sql.gz если не указано
    elif [[ -f "${BACKUP_DIR}/${backup_name}.sql.gz" ]]; then
        backup_path="${BACKUP_DIR}/${backup_name}.sql.gz"
    # Проверка с добавлением .sql если не указано
    elif [[ -f "${BACKUP_DIR}/${backup_name}.sql" ]]; then
        backup_path="${BACKUP_DIR}/${backup_name}.sql"
    # Поиск по паттерну если точное имя не найдено
    elif [[ -f "${BACKUP_DIR}/"*"${backup_name#*_}" ]]; then
        backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name#*_}" -type f | head -1)
    # Поиск по началу имени файла
    elif [[ -f "${BACKUP_DIR}/"*"${backup_name}"* ]]; then
        backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name}*" -type f | head -1)
    # Проверка файлов в постоянном хранилище - точное совпадение
    elif [[ -f "${STORAGE_DIR}/${backup_name}" ]]; then
        if [[ -s "${STORAGE_DIR}/${backup_name}" ]]; then
            backup_path="${STORAGE_DIR}/${backup_name}"
        else
            log "Найден файл в хранилище, но он пустой. Удаляем и попробуем загрузить заново..."
            rm -f "${STORAGE_DIR}/${backup_name}"
            backup_path=""
        fi
    # Проверка в постоянном хранилище с .sql.gz
    elif [[ -f "${STORAGE_DIR}/${backup_name}.sql.gz" ]]; then
        backup_path="${STORAGE_DIR}/${backup_name}.sql.gz"
    # Проверка в постоянном хранилище с .sql
    elif [[ -f "${STORAGE_DIR}/${backup_name}.sql" ]]; then
        backup_path="${STORAGE_DIR}/${backup_name}.sql"
    # Поиск по паттерну в постоянном хранилище
    elif [[ -f "${STORAGE_DIR}/"*"${backup_name#*_}" ]]; then
        backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name#*_}" -type f | head -1)
    # Поиск по началу имени файла в постоянном хранилище
    elif [[ -f "${STORAGE_DIR}/"*"${backup_name}"* ]]; then
        backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name}*" -type f | head -1)
    fi
    
    # Если backup_path пустой (файл был удален как поврежденный или не найден), пробуем загрузить
    if [[ -z "$backup_path" ]]; then
        log "Файл не найден локально, попытка загрузки из Google Drive..."
        if backup_path=$(download_from_cloud "$backup_name"); then
            log "Файл успешно загружен из облака: $backup_path"
        else
            log "ERROR: Бэкап не найден: ${backup_name}"
            log "Попробуйте указать полное имя файла с расширением .sql или .sql.gz"
            log "Поддерживаются форматы: .sql (несжатый) и .sql.gz (сжатый)"
            return 1
        fi
    fi
    
    echo "Тип восстановления:"
    echo "1) Полное восстановление"
    echo "2) Восстановление в конкретную базу данных"
    echo "3) Полное восстановление с предварительной очисткой"
    echo "4) Восстановление в конкретную базу данных с предварительной очисткой"
    echo "5) Восстановление только существующих таблиц (игнорировать отсутствующие)"
    read -r restore_type
    
    local target_database=""
    local clean_before_restore=false
    local filter_existing_tables=false
    
    case "$restore_type" in
        "2")
            echo "Введите имя целевой базы данных:"
            read -r target_database
            ;;
        "3")
            clean_before_restore=true
            ;;
        "4")
            echo "Введите имя целевой базы данных:"
            read -r target_database
            clean_before_restore=true
            ;;
        "5")
            filter_existing_tables=true
            echo "Введите имя целевой базы данных (или оставьте пустым для использования MYSQL_DATABASE):"
            read -r target_database
            if [[ -z "$target_database" ]]; then
                target_database="${MYSQL_DATABASE:-}"
            fi
            if [[ -z "$target_database" ]]; then
                echo "ERROR: Не указана база данных"
                return 1
            fi
            ;;
    esac
    
    restore_backup "$backup_path" "$target_database" "$clean_before_restore" "$filter_existing_tables"
}

# Показать справку
show_help() {
    echo "Использование: $0 [КОМАНДА] [ОПЦИИ]"
    echo
    echo "Команды:"
    echo "  list                    Показать доступные бэкапы"
    echo "  restore <backup_name>   Восстановить из указанного бэкапа"
    echo "  interactive             Интерактивное восстановление"
    echo "  help                    Показать эту справку"
    echo
    echo "Примеры:"
    echo "  $0 list"
    echo "  $0 restore backup_2025-07-30_13-49.sql.gz"
    echo "  $0 interactive"
}

# Основная функция
main() {
    # Создание директории для логов
    mkdir -p "$(dirname "$LOG_FILE")"
    
    case "${1:-interactive}" in
        "list")
            list_backups
            ;;
        "restore")
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: Укажите имя бэкапа для восстановления"
                show_help
                exit 1
            fi
            
            # Поиск бэкапа
            local backup_name="$2"
            local backup_path=""
            
            # Проверка файлов в локальной директории
            if [[ -f "${BACKUP_DIR}/${backup_name}" ]]; then
                backup_path="${BACKUP_DIR}/${backup_name}"
                log "Найден файл бэкапа в локальной директории: ${backup_path}"
            # Поиск файлов по паттерну если точное имя не найдено
            elif [[ -f "${BACKUP_DIR}/"*"${backup_name#*_}" ]]; then
                backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name#*_}" -type f | head -1)
                log "Найден файл бэкапа по паттерну в локальной директории: ${backup_path}"
            # Проверка файлов в постоянном хранилище
            elif [[ -f "${STORAGE_DIR}/${backup_name}" ]]; then
                backup_path="${STORAGE_DIR}/${backup_name}"
                log "Найден файл бэкапа в постоянном хранилище: ${backup_path}"
            # Поиск файлов по паттерну в постоянном хранилище
            elif [[ -f "${STORAGE_DIR}/"*"${backup_name#*_}" ]]; then
                backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name#*_}" -type f | head -1)
                log "Найден файл бэкапа по паттерну в постоянном хранилище: ${backup_path}"
            else
                log "ERROR: Бэкап не найден: ${backup_name}"
                log "Доступные бэкапы:"
                list_backups
                exit 1
            fi
            
            restore_backup "$backup_path" "${3:-}" false false
            ;;
        "interactive")
            interactive_restore
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