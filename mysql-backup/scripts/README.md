# MySQL Backup System

Профессиональная система автоматических бэкапов для MySQL с поддержкой Google Drive.

## Быстрый старт

```bash
# 1. Убедитесь, что MySQL запущен
docker-compose -f docker/docker-compose.ci-prod.yml up -d mysql


===
Остановить контейнер:
docker-compose -f docker-compose.mysql.backup.yml --env-file .env.mysql.backup down
===

# 2. Настройте конфигурацию
./scripts/mysql/setup.sh  # Создаст файл .env.mysql.backup
# Или скопируйте пример: cp docker/.env.mysql.backup.example docker/.env.mysql.backup
# Отредактируйте файл docker/.env.mysql.backup с вашими настройками

# 3. Запустите систему бэкапов
./scripts/mysql/manage.sh setup
./scripts/mysql/manage.sh start

# 4. Создайте тестовый бэкап
./scripts/mysql/manage.sh backup
```

## Основные команды

```bash
# Управление системой
./scripts/mysql/manage.sh start     # Запуск
./scripts/mysql/manage.sh stop      # Остановка
./scripts/mysql/manage.sh status    # Статус
./scripts/mysql/manage.sh health    # Проверка здоровья

# Работа с бэкапами
./scripts/mysql/manage.sh backup    # Создать бэкап
./scripts/mysql/manage.sh restore   # Восстановить
./scripts/mysql/manage.sh sync      # Синхронизация с удаленным сервером
./scripts/mysql/manage.sh cleanup 7 # Очистить старые (7 дней)

# Логи
./scripts/mysql/manage.sh logs backup   # Логи бэкапов
./scripts/mysql/manage.sh logs monitor  # Логи мониторинга
```

## Файлы системы

- `manage.sh` - Основной управляющий скрипт
- `backup.sh` - Скрипт создания бэкапов
- `restore.sh` - Скрипт восстановления
- `sync-remote.sh` - Синхронизация с удаленным MariaDB сервером
- `monitor.py` - Мониторинг состояния
- `google_drive.py` - Работа с Google Drive
- `health-check.sh` - Проверка здоровья системы

## Конфигурация

Основные настройки в `docker/.env.mysql.backup`:

```env
# MySQL (должны совпадать с основной системой)
MYSQL_HOST=mysql
MYSQL_PORT=3306
MYSQL_ROOT_PASSWORD=your_password
MYSQL_DATABASE=m2hydro

# Расписание и хранение
BACKUP_SCHEDULE=0 2 * * *  # Каждый день в 2:00
BACKUP_RETENTION_DAYS=30

# Google Drive (опционально)
GOOGLE_DRIVE_ENABLED=true
GOOGLE_DRIVE_CLIENT_ID=your_client_id
GOOGLE_DRIVE_CLIENT_SECRET=your_client_secret
GOOGLE_DRIVE_REFRESH_TOKEN=your_refresh_token

# Синхронизация с удаленным сервером (MariaDB -> MySQL)
REMOTE_MYSQL_HOST=api.m2m.by
REMOTE_MYSQL_PORT=3306
REMOTE_MYSQL_USER=root
REMOTE_MYSQL_PASSWORD=your_remote_password
REMOTE_MYSQL_DATABASE=m2hydro

# Уведомления (используют существующие переменные)
TG_BOT_TOKEN=your_bot_token
TG_CHAT_ID=your_chat_id
```

## Архитектура

Система состоит из двух Docker контейнеров:

1. **mysql-backup-service** - Создание бэкапов по расписанию
2. **mysql-backup-monitor** - Мониторинг состояния системы

Использует существующий контейнер `m2_mysql` из основной системы.

## Хранение бэкапов

- **Локально**: `/opt/m2-deployment/backups/mysql/`
- **В контейнере**: `/backups/` (временное)
- **Google Drive**: `MySQL-Backups/YYYY-MM/` (опционально)

## Мониторинг

Система автоматически отслеживает:
- ✅ Доступность MySQL
- ✅ Свежесть бэкапов (не старше 25 часов)
- ✅ Свободное место на диске
- ✅ Работу процессов

Уведомления отправляются в Telegram при проблемах.

## Восстановление

```bash
# Интерактивное восстановление
./scripts/mysql/manage.sh restore

# Или напрямую
docker exec m2_mysql_backup /app/scripts/restore.sh list
docker exec m2_mysql_backup /app/scripts/restore.sh restore backup_name.sql.gz
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
./scripts/mysql/manage.sh status

# Проверка здоровья
./scripts/mysql/manage.sh health

# Просмотр логов
./scripts/mysql/manage.sh logs backup
docker exec m2_mysql_backup tail -f /var/log/backup/backup.log

# Проверка MySQL
docker exec m2_mysql mysql -u root -p -e "SELECT 1"
```

## Документация

- `MYSQL-BACKUP-GUIDE.md` - Полное руководство
- `GOOGLE_DRIVE_SETUP.md` - Настройка Google Drive
- `README.md` - Этот файл
## Син
хронизация с удаленным сервером

Система поддерживает синхронизацию с удаленным MariaDB сервером с автоматической обработкой совместимости:

```bash
# Полная синхронизация (дамп + обработка + импорт)
./scripts/mysql/manage.sh sync

# Или напрямую через скрипт синхронизации
docker exec m2_mysql_backup /app/scripts/sync-remote.sh sync
docker exec m2_mysql_backup /app/scripts/sync-remote.sh dump
docker exec m2_mysql_backup /app/scripts/sync-remote.sh stats
```

### Особенности обработки MariaDB -> MySQL:
- ✅ Замена `uuid()` на `(UUID())`
- ✅ Очистка специфичных для MariaDB комментариев
- ✅ Автоматическое создание резервной копии перед импортом
- ✅ Проверка целостности данных после импорта

### Конфигурация удаленного сервера:
```env
REMOTE_MYSQL_HOST=api.m2m.by
REMOTE_MYSQL_PORT=3306
REMOTE_MYSQL_USER=root
REMOTE_MYSQL_PASSWORD=your_password
REMOTE_MYSQL_DATABASE=m2hydro
```