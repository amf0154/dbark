#!/bin/bash

set -e

# Создание необходимых директорий
mkdir -p /var/log/backup /backups /backup-storage

# Проверка наличия скриптов
if [[ ! -f "/app/scripts/backup.sh" ]]; then
    echo "ERROR: Скрипты не найдены. Проверьте volume mount."
    exit 1
fi

# Настройка прав доступа
chmod +x /app/scripts/*.sh 2>/dev/null || true
chmod +x /app/scripts/*.py 2>/dev/null || true

# Создание директории для логов
mkdir -p /var/log/backup

# Установка Python зависимостей для Google Drive (если нужно)
if [[ "${GOOGLE_DRIVE_ENABLED:-false}" == "true" ]]; then
    echo "Установка зависимостей для Google Drive..."
    pip3 install --quiet google-auth google-auth-oauthlib google-auth-httplib2 google-api-python-client
fi

# Создание файла с переменными окружения для cron
cat > /etc/cron.d/mysql-backup << EOF
# Переменные окружения для cron
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-}
MYSQL_DATABASE=${MYSQL_DATABASE:-}
MYSQL_USER=${MYSQL_USER:-}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
BACKUP_COMPRESSION=${BACKUP_COMPRESSION:-true}
BACKUP_TYPE=${BACKUP_TYPE:-full}
BACKUP_SINGLE_TRANSACTION=${BACKUP_SINGLE_TRANSACTION:-true}
BACKUP_ROUTINES=${BACKUP_ROUTINES:-true}
BACKUP_TRIGGERS=${BACKUP_TRIGGERS:-true}
BACKUP_EVENTS=${BACKUP_EVENTS:-true}
GOOGLE_DRIVE_ENABLED=${GOOGLE_DRIVE_ENABLED:-false}
GOOGLE_DRIVE_CLIENT_ID=${GOOGLE_DRIVE_CLIENT_ID:-}
GOOGLE_DRIVE_CLIENT_SECRET=${GOOGLE_DRIVE_CLIENT_SECRET:-}
GOOGLE_DRIVE_REFRESH_TOKEN=${GOOGLE_DRIVE_REFRESH_TOKEN:-}
GOOGLE_DRIVE_FOLDER_ID=${GOOGLE_DRIVE_FOLDER_ID:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
TG_BOT_TOKEN=${TG_BOT_TOKEN:-}
TG_CHAT_ID=${TG_CHAT_ID:-}
ENVIRONMENT=${ENVIRONMENT:-staging}
BACKUP_PREFIX=${BACKUP_PREFIX:-backup}
EOF

if [[ -n "${BACKUP_SCHEDULE:-}" ]]; then
    echo "${BACKUP_SCHEDULE} root /app/scripts/backup.sh >> /var/log/backup/cron.log 2>&1" >> /etc/cron.d/mysql-backup
    echo "Настроено расписание бэкапов: ${BACKUP_SCHEDULE}"
else
    # Используем расписание по умолчанию
    echo "0 2 * * * root /app/scripts/backup.sh >> /var/log/backup/cron.log 2>&1" >> /etc/cron.d/mysql-backup
    echo "Настроено расписание бэкапов по умолчанию: 0 2 * * *"
fi

# Настройка прав для cron файла
chmod 0644 /etc/cron.d/mysql-backup

echo "Текущее расписание cron:"
cat /etc/cron.d/mysql-backup

# Запуск cron демона
echo "Запуск cron демона..."
service cron start

# Проверка что cron запустился
if service cron status > /dev/null 2>&1; then
    echo "✓ Cron демон запущен успешно"
else
    echo "⚠ Проблемы с запуском cron демона"
fi

# Ожидание готовности MySQL
echo "Ожидание готовности MySQL..."
max_attempts=30
attempt=0
while ! mysqladmin ping -h"${MYSQL_HOST:-mysql}" -P"${MYSQL_PORT:-3306}" -u root -p"${MYSQL_ROOT_PASSWORD}" --silent; do
    echo "MySQL не готов, ожидание... (попытка $((++attempt))/$max_attempts)"
    if [[ $attempt -ge $max_attempts ]]; then
        echo "ERROR: MySQL недоступен после $max_attempts попыток"
        exit 1
    fi
    sleep 10
done
echo "MySQL готов"

# Проверка подключения к базе данных
if [[ -n "${MYSQL_DATABASE:-}" ]]; then
    echo "Проверка доступности базы данных: ${MYSQL_DATABASE}"
    if mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u root -p"${MYSQL_ROOT_PASSWORD}" \
        -e "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;" 2>/dev/null; then
        echo "База данных ${MYSQL_DATABASE} доступна"
    else
        echo "WARNING: Проблемы с доступом к базе данных ${MYSQL_DATABASE}"
    fi
fi

# Создание первоначального бэкапа (если нужно)
if [[ "${CREATE_INITIAL_BACKUP:-false}" == "true" ]]; then
    echo "Создание первоначального бэкапа..."
    /app/scripts/backup.sh || echo "WARNING: Ошибка создания первоначального бэкапа"
fi

# Запуск мониторинга в фоне
if [[ "${ENABLE_MONITORING:-true}" == "true" && -f "/app/scripts/monitor.py" ]]; then
    echo "Запуск мониторинга бэкапов..."
    python3 /app/scripts/monitor.py &
fi

# Вывод справочной информации
echo "=== MySQL Backup Service ==="
echo "Доступные команды:"
echo "  docker exec m2_mysql_backup /app/scripts/backup.sh"
echo "  docker exec -it m2_mysql_backup /app/scripts/restore.sh interactive"
echo "  docker exec m2_mysql_backup /app/scripts/restore.sh list"
echo
echo "Логи:"
echo "  docker exec m2_mysql_backup tail -f /var/log/backup/backup.log"
echo "  docker exec m2_mysql_backup tail -f /var/log/backup/monitor.log"
echo
echo "Проверка здоровья:"
echo "  docker exec m2_mysql_backup /app/scripts/health-check.sh"
echo
echo "Система бэкапов запущена и готова к работе"

# Поддержание контейнера в рабочем состоянии
tail -f /var/log/backup/*.log 2>/dev/null || tail -f /dev/null