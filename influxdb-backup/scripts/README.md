# InfluxDB Backup System

Профессиональная система автоматических бэкапов для InfluxDB с поддержкой Google Drive.

## Быстрый старт

```bash
# 1. Убедитесь, что InfluxDB запущен
docker-compose -f docker/docker-compose.ci-prod.yml up -d influxdb

# 2. Настройте систему бэкапов
./scripts/influxdb/setup.sh

# 3. Запустите систему бэкапов
./scripts/influxdb/manage.sh start

# 4. Создайте тестовый бэкап
./scripts/influxdb/manage.sh backup
```

## Основные команды

```bash
# Управление системой
./scripts/influxdb/manage.sh start     # Запуск
./scripts/influxdb/manage.sh stop      # Остановка
./scripts/influxdb/manage.sh status    # Статус
./scripts/influxdb/manage.sh health    # Проверка здоровья

# Работа с бэкапами
./scripts/influxdb/manage.sh backup         # Создать бэкап
./scripts/influxdb/manage.sh restore        # Восстановить
./scripts/influxdb/manage.sh cleanup 7      # Очистить старые (7 дней)
./scripts/influxdb/manage.sh clean-local all # Удалить все локальные файлы

# Управление расписанием
./scripts/influxdb/manage.sh schedule show           # Показать расписание
./scripts/influxdb/manage.sh schedule set '0 */6 * * *' # Каждые 6 часов
./scripts/influxdb/manage.sh schedule disable        # Отключить автобэкапы

# Логи
./scripts/influxdb/manage.sh logs backup   # Логи бэкапов
./scripts/influxdb/manage.sh logs monitor  # Логи мониторинга
```

## Файлы системы

- `manage.sh` - Основной управляющий скрипт
- `backup.sh` - Скрипт создания бэкапов
- `restore.sh` - Скрипт восстановления
- `monitor.py` - Мониторинг состояния
- `google_drive.py` - Работа с Google Drive
- `health-check.sh` - Проверка здоровья системы

## Конфигурация

Основные настройки в `docker/.env.influxdb.backup`:

```env
# InfluxDB (автоматически извлекается из основной конфигурации)
INFLUXDB_HOST=influxdb
INFLUXDB_PORT=8086
INFLUXDB_TOKEN=your_token
INFLUXDB_ORG_NAME=m2hydro
INFLUXDB_BUCKET_NAME=sensors

# Расписание и хранение
BACKUP_SCHEDULE=0 2 * * *  # Каждый день в 2:00
BACKUP_RETENTION_DAYS=30
BACKUP_COMPRESSION=true

# Типы бэкапов
BACKUP_TYPE=full  # full, metadata, data
BACKUP_ALL_BUCKETS=false
BACKUP_INCLUDE_METADATA=true

# Google Drive (опционально)
GOOGLE_DRIVE_ENABLED=true
GOOGLE_DRIVE_CLIENT_ID=your_client_id
GOOGLE_DRIVE_CLIENT_SECRET=your_client_secret
GOOGLE_DRIVE_REFRESH_TOKEN=your_refresh_token

# Уведомления (автоматически извлекается из основной конфигурации)
TG_BOT_TOKEN=your_bot_token
TG_CHAT_ID=your_chat_id
```

## Архитектура

Система состоит из одного Docker контейнера:

1. **m2_influxdb_backup** - Создание бэкапов по расписанию и мониторинг

Использует существующий контейнер `m2_influxdb` из основной системы через Docker сеть.

## Хранение бэкапов

- **Локально**: `/opt/m2-deployment/backups/influxdb/`
- **В контейнере**: `/backups/` (временное)
- **Google Drive**: `InfluxDB-Backups/YYYY-MM/` (опционально)

## Мониторинг

Система автоматически отслеживает:
- ✅ Доступность InfluxDB API
- ✅ Доступность организации и bucket
- ✅ Свежесть бэкапов (не старше 25 часов)
- ✅ Целостность бэкапов
- ✅ Свободное место на диске
- ✅ Работу процессов (cron, мониторинг)

Уведомления отправляются в Telegram при проблемах.

## Восстановление

```bash
# Интерактивное восстановление
./scripts/influxdb/manage.sh restore

# Или напрямую
docker exec m2_influxdb_backup /app/scripts/restore.sh list
docker exec m2_influxdb_backup /app/scripts/restore.sh restore backup_name.tar.gz
```

## Google Drive

Для настройки Google Drive см. `GOOGLE_DRIVE_SETUP.md`

## Безопасность

- Создается резервная копия перед восстановлением
- Подтверждение при перезаписи данных
- Логирование всех операций
- Шифрование в транзите (HTTPS для Google Drive)

## Устранение неполадок

```bash
# Проверка статуса
./scripts/influxdb/manage.sh status

# Проверка здоровья
./scripts/influxdb/manage.sh health

# Просмотр логов
./scripts/influxdb/manage.sh logs backup
docker exec m2_influxdb_backup tail -f /var/log/backup/backup.log

# Проверка InfluxDB
docker exec m2_influxdb curl -f http://localhost:8086/health
```

## Документация

- `INFLUXDB-BACKUP-GUIDE.md` - Полное руководство
- `GOOGLE_DRIVE_SETUP.md` - Настройка Google Drive
- `README.md` - Этот файл