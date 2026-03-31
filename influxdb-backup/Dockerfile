FROM influxdb:2.7-alpine

# Установка дополнительных утилит
RUN apk add --no-cache \
    curl \
    jq \
    docker-cli \
    dcron \
    bash \
    gzip \
    tar \
    python3 \
    py3-pip \
    py3-requests \
    && python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir google-api-python-client google-auth-httplib2 google-auth-oauthlib

# Добавляем виртуальное окружение в PATH
ENV PATH="/opt/venv/bin:$PATH"

# Создание рабочей директории
WORKDIR /app

# Создание директорий
RUN mkdir -p /app/scripts /backups /backup-storage /var/log/backup

# Копирование скриптов будет выполнено через volume mount
# Создание пустых файлов для структуры
RUN touch /app/scripts/backup.sh /app/scripts/restore.sh /app/scripts/health-check.sh
RUN chmod +x /app/scripts/*.sh

# Создание базового crontab
RUN echo "0 2 * * * /app/scripts/backup.sh >> /var/log/backup/cron.log 2>&1" > /etc/crontabs/root
RUN chmod 0644 /etc/crontabs/root

# Создание базового entrypoint
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

echo "=== InfluxDB Backup Service Starting ==="

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

# Настройка cron расписания
if [[ -n "${BACKUP_SCHEDULE:-}" ]]; then
    echo "${BACKUP_SCHEDULE} /app/scripts/backup.sh >> /var/log/backup/cron.log 2>&1" > /etc/crontabs/root
    echo "Настроено расписание бэкапов: ${BACKUP_SCHEDULE}"
fi

# Запуск cron демона
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

echo "=== Backup Service Started ==="
echo "Доступные команды:"
echo "  docker exec m2_influxdb_backup /app/scripts/backup.sh"
echo "  docker exec -it m2_influxdb_backup /app/scripts/restore.sh interactive"

# Поддержание контейнера в рабочем состоянии
tail -f /var/log/backup/*.log 2>/dev/null || tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]