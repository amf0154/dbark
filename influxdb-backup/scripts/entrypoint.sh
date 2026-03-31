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

# Настройка cron расписания из переменной окружения
if [[ -n "${BACKUP_SCHEDULE:-}" ]]; then
    echo "${BACKUP_SCHEDULE} /app/scripts/backup.sh >> /var/log/backup/cron.log 2>&1" > /etc/crontabs/root
    echo "Настроено расписание бэкапов: ${BACKUP_SCHEDULE}"
else
    # Используем расписание по умолчанию
    echo "0 2 * * * /app/scripts/backup.sh >> /var/log/backup/cron.log 2>&1" > /etc/crontabs/root
    echo "Настроено расписание бэкапов по умолчанию: 0 2 * * *"
fi

# Проверим что crontab создался
echo "Текущее расписание cron:"
cat /etc/crontabs/root

# Запуск cron демона
echo "Запуск cron демона..."
crond -f -d 8 &

# Ожидание готовности InfluxDB
echo "Ожидание готовности InfluxDB..."
max_attempts=30
attempt=0
while ! curl -s -f "http://${INFLUXDB_HOST:-m2_influxdb}:${INFLUXDB_PORT:-8086}/ping" > /dev/null; do
    echo "InfluxDB не готов, ожидание... (попытка $((++attempt))/$max_attempts)"
    if [[ $attempt -ge $max_attempts ]]; then
        echo "ERROR: InfluxDB недоступен после $max_attempts попыток"
        exit 1
    fi
    sleep 10
done
echo "InfluxDB готов"

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
echo "=== InfluxDB Backup Service ==="
echo "Доступные команды:"
echo "  docker exec m2_influxdb_backup /app/scripts/backup.sh"
echo "  docker exec -it m2_influxdb_backup /app/scripts/restore.sh interactive"
echo "  docker exec m2_influxdb_backup /app/scripts/restore.sh list"
echo
echo "Логи:"
echo "  docker exec m2_influxdb_backup tail -f /var/log/backup/backup.log"
echo "  docker exec m2_influxdb_backup tail -f /var/log/backup/monitor.log"
echo
echo "Система бэкапов запущена и готова к работе"

# Поддержание контейнера в рабочем состоянии
tail -f /var/log/backup/*.log 2>/dev/null || tail -f /dev/null