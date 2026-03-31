#!/bin/bash

set -euo pipefail

# Конфигурация
INFLUXDB_HOST=${INFLUXDB_HOST:-localhost}
INFLUXDB_PORT=${INFLUXDB_PORT:-8086}
INFLUXDB_TOKEN=${INFLUXDB_TOKEN}
INFLUXDB_ORG=${INFLUXDB_ORG}
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
            -d text="🔄 InfluxDB Restore [${env_name}] ${status}: ${message}" \
            -d parse_mode="HTML" || true
    fi
}

# Показать доступные бэкапы
list_backups() {
    log "Доступные бэкапы:"
    echo
    echo "=== Локальные бэкапы ==="
    ls -la "$BACKUP_DIR" | grep -E "(backup_|m2_|influxdb_).*\.tar\.gz" || echo "Нет обычных бэкапов"
    echo
    echo "=== Pre-restore бэкапы (директории) ==="
    ls -la "$BACKUP_DIR" | grep -E "^d.*pre-restore" || echo "Нет pre-restore бэкапов"
    echo
    
    if [[ -d "$STORAGE_DIR" ]]; then
        echo "=== Бэкапы в постоянном хранилище ==="
        ls -la "$STORAGE_DIR" | grep -E "(backup_|m2_|influxdb_|pre-restore).*\.tar\.gz" || echo "Нет бэкапов в хранилище"
        echo
    fi
    
    if [[ "${GOOGLE_DRIVE_ENABLED:-false}" == "true" ]]; then
        echo "=== Облачные бэкапы (Google Drive) ==="
        python3 /app/scripts/google_drive.py list || echo "Нет облачных бэкапов"
        echo
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
            if [[ "$backup_name" != *.tar.gz ]]; then
                actual_filename="${backup_name}.tar.gz"
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
    local work_dir="/tmp/restore_work"
    
    # Очистка рабочей директории
    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    
    if [[ "$backup_path" == *.tar.gz ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Распаковка сжатого бэкапа..." >&2
        cd "$work_dir"
        
        # Проверяем, что файл не пустой
        if [[ ! -s "$backup_path" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Файл бэкапа пустой или поврежден: $backup_path" >&2
            return 1
        fi
        
        # Пробуем распаковать архив
        if ! tar -xzf "$backup_path" 2>/dev/null; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Не удалось распаковать архив. Возможно файл поврежден." >&2
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Проверяем содержимое файла..." >&2
            file "$backup_path" >&2
            return 1
        fi
        
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Архив успешно распакован" >&2
        
        # Сначала проверяем есть ли файлы бэкапа прямо в work_dir (формат без папки)
        local manifest_files=$(find "$work_dir" -maxdepth 1 -name "*.manifest" | wc -l)
        local data_files=$(find "$work_dir" -maxdepth 1 -name "*.tar.gz" -o -name "*.bolt.gz" -o -name "*.sqlite.gz" | wc -l)
        
        if [[ $manifest_files -gt 0 && $data_files -gt 0 ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Файлы бэкапа найдены в корне архива (формат без папки)" >&2
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Найдено файлов манифеста: $manifest_files" >&2
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Найдено файлов данных: $data_files" >&2
            backup_dir="$work_dir"
        else
            # Если файлов в корне нет, ищем директорию с бэкапом (формат с папкой)
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Файлы в корне не найдены, ищем директорию с бэкапом..." >&2
            
            # Поиск директории с бэкапом (любой префикс)
            local backup_dir=$(find "$work_dir" -type d -name "*_*_*" | head -1)
            if [[ -z "$backup_dir" ]]; then
                # Если не найдена директория с паттерном, ищем любую директорию
                backup_dir=$(find "$work_dir" -type d -mindepth 1 | head -1)
            fi
            
            if [[ -z "$backup_dir" ]]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Не найдена директория с бэкапом и нет файлов в корне" >&2
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Содержимое архива:" >&2
                ls -la "$work_dir" >&2
                return 1
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Найдена директория с бэкапом: $(basename "$backup_dir")" >&2
            fi
        fi
        
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Найдена директория бэкапа: $(basename "$backup_dir")" >&2
        
        # Проверим содержимое директории бэкапа
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Содержимое директории бэкапа:" >&2
        ls -la "$backup_dir" >&2
        
        # Проверим есть ли вложенная директория с тем же именем (двойная вложенность)
        local nested_dir="$backup_dir/$(basename "$backup_dir")"
        if [[ -d "$nested_dir" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Обнаружена двойная вложенность, проверяем где больше файлов..." >&2
            
            local files_in_main=$(find "$backup_dir" -maxdepth 1 -name "*.tar.gz" -o -name "*.manifest" -o -name "*.bolt.gz" -o -name "*.sqlite.gz" | wc -l)
            local files_in_nested=$(find "$nested_dir" -maxdepth 1 -name "*.tar.gz" -o -name "*.manifest" -o -name "*.bolt.gz" -o -name "*.sqlite.gz" | wc -l)
            
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Файлов в основной директории: $files_in_main" >&2
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Файлов во вложенной директории: $files_in_nested" >&2
            
            if [[ $files_in_nested -gt $files_in_main ]]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Используем вложенную директорию (больше файлов)" >&2
                backup_dir="$nested_dir"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Используем основную директорию" >&2
            fi
            
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Итоговое содержимое выбранной директории:" >&2
            ls -la "$backup_dir" >&2
        fi
        
        # Проверим наличие ключевых файлов InfluxDB бэкапа
        local has_manifest=false
        local has_data_files=false
        local manifest_count=0
        local data_files_count=0
        
        # Поиск файлов манифеста
        manifest_count=$(find "$backup_dir" -maxdepth 1 -name "*.manifest" | wc -l)
        if [[ $manifest_count -gt 0 ]]; then
            has_manifest=true
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Найдено файлов манифеста: $manifest_count" >&2
        fi
        
        # Поиск файлов данных
        data_files_count=$(find "$backup_dir" -maxdepth 1 \( -name "*.tar.gz" -o -name "*.bolt.gz" -o -name "*.sqlite.gz" \) | wc -l)
        if [[ $data_files_count -gt 0 ]]; then
            has_data_files=true
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Найдено файлов данных: $data_files_count" >&2
        fi
        
        if [[ "$has_manifest" == "true" && "$has_data_files" == "true" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Структура бэкапа InfluxDB корректна" >&2
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Возможно некорректная структура бэкапа" >&2
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Манифест: $has_manifest ($manifest_count файлов)" >&2
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Файлы данных: $has_data_files ($data_files_count файлов)" >&2
            
            # Покажем что именно найдено
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Все файлы в директории бэкапа:" >&2
            find "$backup_dir" -maxdepth 1 -type f | sort >&2
        fi
        
        echo "$backup_dir"
    elif [[ -d "$backup_path" ]]; then
        # Если это уже директория (например, pre-restore), используем её напрямую
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Используем директорию бэкапа напрямую: $backup_path" >&2
        echo "$backup_path"
    else
        echo "$backup_path"
    fi
}

# Проверка состояния InfluxDB перед восстановлением
check_influxdb_before_restore() {
    log "Проверка состояния InfluxDB перед восстановлением..."
    
    if ! curl -s -f "http://${INFLUXDB_HOST}:${INFLUXDB_PORT}/ping" > /dev/null; then
        log "ERROR: InfluxDB недоступен"
        return 1
    fi
    
    # Проверка наличия данных (пропускаем проверку организации для полного restore)
    log "Проверка текущего состояния InfluxDB..."
    
    echo "========================================="
    echo "ВНИМАНИЕ: Восстановление перезапишет все существующие данные!"
    echo "========================================="
    echo "Продолжить восстановление? (y/N)"
    echo -n "Ваш ответ: "
    
    # Добавляем таймаут для интерактивного ввода
    if read -r -t 30 confirmation; then
        if [[ "$confirmation" != "y" && "$confirmation" != "Y" ]]; then
            log "Восстановление отменено пользователем"
            return 1
        fi
    else
        echo
        log "Таймаут ожидания ответа (30 сек). Восстановление отменено."
        return 1
    fi
}

# Создание резервной копии перед восстановлением
create_pre_restore_backup() {
    log "Создание резервной копии перед восстановлением..."
    
    local pre_restore_backup="/backups/pre-restore-$(date '+%Y-%m-%d_%H-%M-%S')"
    
    log "Выполнение команды backup для создания резервной копии..."
    if influx backup "$pre_restore_backup" \
        --host "http://${INFLUXDB_HOST}:${INFLUXDB_PORT}" \
        --token "$INFLUXDB_TOKEN" \
        --compression gzip; then
        
        log "Резервная копия создана: ${pre_restore_backup}"
        echo "$pre_restore_backup"
    else
        log "WARNING: Не удалось создать резервную копию"
        return 1
    fi
}

# Восстановление из бэкапа
restore_backup() {
    local backup_path=$1
    local full_restore=${2:-true}
    
    log "Начало восстановления из: ${backup_path}"
    
    # Проверка существования файла бэкапа
    if [[ ! -f "$backup_path" && ! -d "$backup_path" ]]; then
        log "ERROR: Файл или директория бэкапа не существует: ${backup_path}"
        return 1
    fi
    
    # Показываем информацию о файле
    if [[ -f "$backup_path" ]]; then
        log "Размер файла бэкапа: $(ls -lh "$backup_path" | awk '{print $5}')"
    fi
    
    # Подготовка бэкапа
    log "Подготовка бэкапа к восстановлению..."
    local prepared_backup
    prepared_backup=$(prepare_backup "$backup_path" | tail -1)
    
    # Проверки перед восстановлением
    check_influxdb_before_restore
    
    # Создание резервной копии
    local pre_restore_backup
    pre_restore_backup=$(create_pre_restore_backup) || true
    
    log "========================================="
    log "Начало процесса восстановления данных"
    log "========================================="
    log "Выполнение команды восстановления..."
    log "Команда: influx restore \"$prepared_backup\" --host http://${INFLUXDB_HOST}:${INFLUXDB_PORT} --token [HIDDEN]$(if [[ "$full_restore" == "true" ]]; then echo " --full"; fi)"
    
    # Выполнение восстановления
    local restore_success=false
    
    # InfluxDB restore работает только с распакованными директориями
    if [[ "$full_restore" == "true" ]]; then
        if influx restore "$prepared_backup" \
            --host "http://${INFLUXDB_HOST}:${INFLUXDB_PORT}" \
            --token "$INFLUXDB_TOKEN" \
            --full; then
            restore_success=true
        fi
    else
        if influx restore "$prepared_backup" \
            --host "http://${INFLUXDB_HOST}:${INFLUXDB_PORT}" \
            --token "$INFLUXDB_TOKEN"; then
            restore_success=true
        fi
    fi
    
    if [[ "$restore_success" == "true" ]]; then
        log "Команда восстановления выполнена успешно"
    else
        log "ERROR: Ошибка при выполнении команды восстановления"
        log "Проверим структуру бэкапа..."
        
        # Дополнительная диагностика
        if [[ -d "$prepared_backup" ]]; then
            log "Содержимое директории бэкапа:"
            ls -la "$prepared_backup"
            
            # Проверим наличие обязательных файлов
            local manifest_file=$(find "$prepared_backup" -name "*.manifest" | head -1)
            if [[ -n "$manifest_file" ]]; then
                log "Найден файл манифеста: $(basename "$manifest_file")"
            else
                log "ERROR: Файл манифеста не найден"
            fi
            
            # Проверим файлы данных
            local data_files=$(find "$prepared_backup" -name "*.tar.gz" -o -name "*.bolt.gz" -o -name "*.sqlite.gz" | wc -l)
            log "Найдено файлов данных: $data_files"
        else
            log "ERROR: Директория бэкапа не существует: $prepared_backup"
        fi
    fi
    
    if [[ "$restore_success" == "true" ]]; then
        log "Восстановление завершено успешно"
        send_notification "SUCCESS" "Данные восстановлены из бэкапа: $(basename "$backup_path")"
        
        # Очистка временных файлов
        if [[ "$prepared_backup" == /tmp/* ]]; then
            rm -rf "$(dirname "$prepared_backup")"
        fi
        
    else
        log "ERROR: Ошибка при восстановлении"
        send_notification "FAILED" "Ошибка при восстановлении из бэкапа: $(basename "$backup_path")"
        
        # Попытка восстановить предыдущее состояние
        if [[ -n "${pre_restore_backup:-}" ]]; then
            log "Попытка восстановления предыдущего состояния..."
            influx restore "$pre_restore_backup" \
                --host "http://${INFLUXDB_HOST}:${INFLUXDB_PORT}" \
                --token "$INFLUXDB_TOKEN" \
                --full || log "ERROR: Не удалось восстановить предыдущее состояние"
        fi
        
        return 1
    fi
}

# Интерактивное восстановление
interactive_restore() {
    echo "=== Интерактивное восстановление InfluxDB ==="
    echo
    
    list_backups
    
    echo "Введите имя файла бэкапа для восстановления:"
    read -r backup_name
    
    # Поиск бэкапа
    local backup_path=""
    
    # Поиск бэкапа с любым префиксом (backup_, m2_, influxdb_, pre-restore, etc.)
    # Проверка файлов в локальной директории - точное совпадение
    if [[ -f "${BACKUP_DIR}/${backup_name}" ]]; then
        # Проверяем, что файл не пустой
        if [[ -s "${BACKUP_DIR}/${backup_name}" ]]; then
            backup_path="${BACKUP_DIR}/${backup_name}"
        else
            log "Найден файл, но он пустой. Удаляем и попробуем загрузить заново..."
            rm -f "${BACKUP_DIR}/${backup_name}"
            # Переходим к загрузке из облака
            backup_path=""
        fi
    # Проверка директорий в локальной директории (для pre-restore)
    elif [[ -d "${BACKUP_DIR}/${backup_name}" ]]; then
        backup_path="${BACKUP_DIR}/${backup_name}"
        log "Найдена директория pre-restore бэкапа: ${backup_path}"
    # Проверка с добавлением .tar.gz если не указано
    elif [[ -f "${BACKUP_DIR}/${backup_name}.tar.gz" ]]; then
        backup_path="${BACKUP_DIR}/${backup_name}.tar.gz"
    # Поиск по паттерну если точное имя не найдено
    elif [[ -f "${BACKUP_DIR}/"*"${backup_name#*_}" ]]; then
        backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name#*_}" -type f | head -1)
    # Поиск директорий по паттерну (для pre-restore)
    elif [[ -d "${BACKUP_DIR}/"*"${backup_name#*_}" ]]; then
        backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name#*_}" -type d | head -1)
        log "Найдена директория pre-restore бэкапа по паттерну: ${backup_path}"
    # Поиск по паттерну с .tar.gz
    elif [[ -f "${BACKUP_DIR}/"*"${backup_name#*_}.tar.gz" ]]; then
        backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name#*_}.tar.gz" -type f | head -1)
    # Поиск по началу имени файла
    elif [[ -f "${BACKUP_DIR}/"*"${backup_name}"* ]]; then
        backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name}*" -type f | head -1)
    # Поиск по началу имени директории
    elif [[ -d "${BACKUP_DIR}/"*"${backup_name}"* ]]; then
        backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name}*" -type d | head -1)
        log "Найдена директория pre-restore бэкапа по частичному совпадению: ${backup_path}"
    # Проверка файлов в постоянном хранилище - точное совпадение
    elif [[ -f "${STORAGE_DIR}/${backup_name}" ]]; then
        backup_path="${STORAGE_DIR}/${backup_name}"
    # Проверка директорий в постоянном хранилище
    elif [[ -d "${STORAGE_DIR}/${backup_name}" ]]; then
        backup_path="${STORAGE_DIR}/${backup_name}"
        log "Найдена директория pre-restore бэкапа в постоянном хранилище: ${backup_path}"
    # Проверка в постоянном хранилище с .tar.gz
    elif [[ -f "${STORAGE_DIR}/${backup_name}.tar.gz" ]]; then
        backup_path="${STORAGE_DIR}/${backup_name}.tar.gz"
    # Поиск по паттерну в постоянном хранилище
    elif [[ -f "${STORAGE_DIR}/"*"${backup_name#*_}" ]]; then
        backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name#*_}" -type f | head -1)
    # Поиск директорий по паттерну в постоянном хранилище
    elif [[ -d "${STORAGE_DIR}/"*"${backup_name#*_}" ]]; then
        backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name#*_}" -type d | head -1)
        log "Найдена директория pre-restore бэкапа по паттерну в постоянном хранилище: ${backup_path}"
    # Поиск по паттерну с .tar.gz в постоянном хранилище
    elif [[ -f "${STORAGE_DIR}/"*"${backup_name#*_}.tar.gz" ]]; then
        backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name#*_}.tar.gz" -type f | head -1)
    # Поиск по началу имени файла в постоянном хранилище
    elif [[ -f "${STORAGE_DIR}/"*"${backup_name}"* ]]; then
        backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name}*" -type f | head -1)
    # Поиск по началу имени директории в постоянном хранилище
    elif [[ -d "${STORAGE_DIR}/"*"${backup_name}"* ]]; then
        backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name}*" -type d | head -1)
        log "Найдена директория pre-restore бэкапа по частичному совпадению в постоянном хранилище: ${backup_path}"
    # Попытка загрузки из облака
    else
        log "Файл не найден локально, попытка загрузки из Google Drive..."
        if backup_path=$(download_from_cloud "$backup_name"); then
            log "Файл успешно загружен из облака: $backup_path"
        else
            log "ERROR: Бэкап не найден: ${backup_name}"
            log "Попробуйте указать полное имя файла с расширением .tar.gz"
            log "Для pre-restore бэкапов используйте точное имя директории"
            return 1
        fi
    fi
    
    # Если backup_path пустой (файл был удален как поврежденный), пробуем загрузить
    if [[ -z "$backup_path" ]]; then
        log "Попытка загрузки из Google Drive..."
        if backup_path=$(download_from_cloud "$backup_name"); then
            log "Файл успешно загружен из облака: $backup_path"
        else
            log "ERROR: Не удалось загрузить бэкап: ${backup_name}"
            return 1
        fi
    fi
    
    echo "Тип восстановления:"
    echo "1) Полное восстановление (--full)"
    echo "2) Частичное восстановление"
    read -r restore_type
    
    local full_restore="true"
    if [[ "$restore_type" == "2" ]]; then
        full_restore="false"
    fi
    
    restore_backup "$backup_path" "$full_restore"
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
    echo "  $0 restore backup_2025-07-30_13-49.tar.gz"
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
            
            # Поиск бэкапа с любым префиксом (backup_, m2_, influxdb_, pre-restore, etc.)
            # Проверка файлов в локальной директории - точное совпадение
            if [[ -f "${BACKUP_DIR}/${backup_name}" ]]; then
                backup_path="${BACKUP_DIR}/${backup_name}"
                log "Найден файл бэкапа в локальной директории: ${backup_path}"
            # Проверка с добавлением .tar.gz если не указано
            elif [[ -f "${BACKUP_DIR}/${backup_name}.tar.gz" ]]; then
                backup_path="${BACKUP_DIR}/${backup_name}.tar.gz"
                log "Найден файл бэкапа с расширением в локальной директории: ${backup_path}"
            # Проверка директорий в локальной директории (для pre-restore)
            elif [[ -d "${BACKUP_DIR}/${backup_name}" ]]; then
                backup_path="${BACKUP_DIR}/${backup_name}"
                log "Найдена директория бэкапа в локальной директории: ${backup_path}"
            # Поиск файлов по паттерну если точное имя не найдено
            elif [[ -f "${BACKUP_DIR}/"*"${backup_name#*_}" ]]; then
                backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name#*_}" -type f | head -1)
                log "Найден файл бэкапа по паттерну в локальной директории: ${backup_path}"
            # Поиск файлов по паттерну с .tar.gz
            elif [[ -f "${BACKUP_DIR}/"*"${backup_name#*_}.tar.gz" ]]; then
                backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name#*_}.tar.gz" -type f | head -1)
                log "Найден файл бэкапа по паттерну с расширением в локальной директории: ${backup_path}"
            # Поиск по началу имени файла
            elif [[ -f "${BACKUP_DIR}/"*"${backup_name}"* ]]; then
                backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name}*" -type f | head -1)
                log "Найден файл бэкапа по частичному совпадению в локальной директории: ${backup_path}"
            # Поиск директорий по паттерну
            elif [[ -d "${BACKUP_DIR}/"*"${backup_name#*_}" ]]; then
                backup_path=$(find "${BACKUP_DIR}" -name "*${backup_name#*_}" -type d | head -1)
                log "Найдена директория бэкапа по паттерну в локальной директории: ${backup_path}"
            # Проверка файлов в постоянном хранилище - точное совпадение
            elif [[ -f "${STORAGE_DIR}/${backup_name}" ]]; then
                backup_path="${STORAGE_DIR}/${backup_name}"
                log "Найден файл бэкапа в постоянном хранилище: ${backup_path}"
            # Проверка в постоянном хранилище с .tar.gz
            elif [[ -f "${STORAGE_DIR}/${backup_name}.tar.gz" ]]; then
                backup_path="${STORAGE_DIR}/${backup_name}.tar.gz"
                log "Найден файл бэкапа с расширением в постоянном хранилище: ${backup_path}"
            # Проверка директорий в постоянном хранилище
            elif [[ -d "${STORAGE_DIR}/${backup_name}" ]]; then
                backup_path="${STORAGE_DIR}/${backup_name}"
                log "Найдена директория бэкапа в постоянном хранилище: ${backup_path}"
            # Поиск файлов по паттерну в постоянном хранилище
            elif [[ -f "${STORAGE_DIR}/"*"${backup_name#*_}" ]]; then
                backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name#*_}" -type f | head -1)
                log "Найден файл бэкапа по паттерну в постоянном хранилище: ${backup_path}"
            # Поиск файлов по паттерну с .tar.gz в постоянном хранилище
            elif [[ -f "${STORAGE_DIR}/"*"${backup_name#*_}.tar.gz" ]]; then
                backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name#*_}.tar.gz" -type f | head -1)
                log "Найден файл бэкапа по паттерну с расширением в постоянном хранилище: ${backup_path}"
            # Поиск по началу имени файла в постоянном хранилище
            elif [[ -f "${STORAGE_DIR}/"*"${backup_name}"* ]]; then
                backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name}*" -type f | head -1)
                log "Найден файл бэкапа по частичному совпадению в постоянном хранилище: ${backup_path}"
            # Поиск директорий по паттерну в постоянном хранилище
            elif [[ -d "${STORAGE_DIR}/"*"${backup_name#*_}" ]]; then
                backup_path=$(find "${STORAGE_DIR}" -name "*${backup_name#*_}" -type d | head -1)
                log "Найдена директория бэкапа по паттерну в постоянном хранилище: ${backup_path}"
            else
                log "ERROR: Бэкап не найден: ${backup_name}"
                log "Попробуйте указать полное имя файла с расширением .tar.gz"
                log "Доступные бэкапы:"
                list_backups
                exit 1
            fi
            
            restore_backup "$backup_path"
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