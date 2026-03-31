# InfluxDB Backup Management - Руководство

Скрипт `manage.sh` предоставляет полное управление системой бэкапов InfluxDB.

## Новые функции

### 1. Управление расписанием бэкапов

#### Просмотр текущего расписания

```bash
./scripts/influxdb/manage.sh schedule show
```

#### Установка нового расписания

```bash
# Каждые 6 часов
./scripts/influxdb/manage.sh schedule set '0 */6 * * *'

# Каждый день в 3:00 утра
./scripts/influxdb/manage.sh schedule set '0 3 * * *'

# Каждые 30 минут (для тестирования)
./scripts/influxdb/manage.sh schedule set '*/30 * * * *'

# Два раза в день: в 2:00 и 14:00
./scripts/influxdb/manage.sh schedule set '0 2,14 * * *'
```

#### Отключение автоматических бэкапов

```bash
./scripts/influxdb/manage.sh schedule disable
```

#### Примеры расписаний

```bash
./scripts/influxdb/manage.sh schedule examples
```

### 2. Очистка локальных файлов

#### Удаление всех pre-restore файлов

```bash
./scripts/influxdb/manage.sh clean-local pre-restore
```

#### Удаление всех локальных бэкапов

```bash
./scripts/influxdb/manage.sh clean-local backups
```

#### Удаление всех локальных файлов (бэкапы + pre-restore)

```bash
./scripts/influxdb/manage.sh clean-local all
```

### 3. Синхронизация с Google Drive

#### Загрузка бэкапов в Google Drive

```bash
./scripts/influxdb/manage.sh sync
```

## Примеры использования

### Настройка частых бэкапов для активной разработки

```bash
# Установить бэкапы каждые 4 часа
./scripts/influxdb/manage.sh schedule set '0 */4 * * *'

# Проверить статус
./scripts/influxdb/manage.sh status

# Очистить старые pre-restore файлы
./scripts/influxdb/manage.sh clean-local pre-restore
```

### Настройка редких бэкапов для стабильного production

```bash
# Установить бэкапы раз в день в 2:00
./scripts/influxdb/manage.sh schedule set '0 2 * * *'

# Очистить бэкапы старше 7 дней
./scripts/influxdb/manage.sh cleanup 7
```

### Подготовка к восстановлению

```bash
# Очистить все pre-restore файлы
./scripts/influxdb/manage.sh clean-local pre-restore

# Посмотреть доступные бэкапы
./scripts/influxdb/manage.sh status

# Запустить восстановление
./scripts/influxdb/manage.sh restore
```

### Работа с Google Drive

```bash
# Синхронизировать бэкапы с Google Drive
./scripts/influxdb/manage.sh sync

# Проверить статус после синхронизации
./scripts/influxdb/manage.sh status
```

## Формат расписания (Cron)

```
┌───────────── минуты (0 - 59)
│ ┌─────────── часы (0 - 23)
│ │ ┌───────── день месяца (1 - 31)
│ │ │ ┌─────── месяц (1 - 12)
│ │ │ │ ┌───── день недели (0 - 6) (0 = воскресенье)
│ │ │ │ │
* * * * *
```

### Популярные расписания:

-   `0 2 * * *` - каждый день в 2:00
-   `0 */6 * * *` - каждые 6 часов
-   `0 2 * * 0` - каждое воскресенье в 2:00
-   `*/30 * * * *` - каждые 30 минут
-   `0 2,14 * * *` - каждый день в 2:00 и 14:00
-   `0 1 1 * *` - первого числа каждого месяца в 1:00

## Мониторинг

### Проверка статуса системы

```bash
./scripts/influxdb/manage.sh status
```

### Просмотр логов

```bash
./scripts/influxdb/manage.sh logs backup
./scripts/influxdb/manage.sh logs monitor
```

### Проверка здоровья

```bash
./scripts/influxdb/manage.sh health
```

## Особенности InfluxDB

### Типы бэкапов

В конфигурации `.env.influxdb.backup` можно настроить:

```env
BACKUP_TYPE=full              # Полный бэкап (данные + метаданные)
BACKUP_ALL_BUCKETS=false      # Бэкап всех buckets или только указанного
BACKUP_INCLUDE_METADATA=true  # Включать метаданные (организации, пользователи)
```

### Проверка InfluxDB

```bash
# Проверка доступности API
curl -f http://influxdb:8086/health

# Проверка через контейнер бэкапов
docker exec m2_influxdb_backup curl -f http://influxdb:8086/ping
```

## Безопасность

-   **Pre-restore файлы** создаются автоматически перед каждым восстановлением
-   **Локальные бэкапы** хранятся в `/backups/` внутри контейнера
-   **Удаление файлов** необратимо - будьте осторожны
-   **Расписание** применяется немедленно и сохраняется при перезапуске
-   **Токены InfluxDB** хранятся в переменных окружения

## Устранение проблем

### Если расписание не работает

```bash
# Проверить статус cron в контейнере
docker exec m2_influxdb_backup service cron status

# Перезапустить cron
docker exec m2_influxdb_backup service cron restart

# Проверить логи cron
docker exec m2_influxdb_backup tail -f /var/log/backup/cron.log
```

### Если не хватает места

```bash
# Очистить старые бэкапы (старше 7 дней)
./scripts/influxdb/manage.sh cleanup 7

# Очистить все pre-restore файлы
./scripts/influxdb/manage.sh clean-local pre-restore

# Проверить размер директории
docker exec m2_influxdb_backup du -sh /backups/
```

### Проблемы с InfluxDB

```bash
# Проверить доступность InfluxDB
./scripts/influxdb/manage.sh health

# Проверить логи InfluxDB
docker logs m2_influxdb

# Проверить сеть
docker network ls | grep m2_network
```

### Проблемы с Google Drive

```bash
# Проверить настройки Google Drive
docker exec m2_influxdb_backup cat /app/scripts/google_drive.py

# Проверить токены
docker exec m2_influxdb_backup env | grep GOOGLE_DRIVE

# Тестовая синхронизация
./scripts/influxdb/manage.sh sync
```