# dbark

Два независимых Docker-сервиса для резервного копирования баз данных.

```
dbark/
├── mysql-backup/        — бэкапы MySQL
│   ├── scripts/         — скрипты бэкапа (backup.sh, restore.sh, google_drive.py и др.)
│   ├── docker-compose.yml
│   ├── env              — пример конфигурации (без секретов, в репозитории)
│   ├── .env             — реальная конфигурация с секретами (не в репозитории)
│   └── manage.sh
└── influxdb-backup/     — бэкапы InfluxDB
    ├── scripts/         — скрипты бэкапа
    ├── Dockerfile
    ├── docker-compose.yml
    ├── env              — пример конфигурации (без секретов, в репозитории)
    ├── .env             — реальная конфигурация с секретами (не в репозитории)
    └── manage.sh
```

---

## Начало работы

```bash
# Скопировать пример конфига и заполнить своими данными
cp mysql-backup/env mysql-backup/.env
cp influxdb-backup/env influxdb-backup/.env
```

Файл `.env` не попадает в репозиторий (добавлен в `.gitignore`).

---

## Что редактировать

Все настройки в `.env` рядом с `docker-compose.yml`.

### Ключевые параметры

| Параметр                  | Описание                              |
|---------------------------|---------------------------------------|
| `BACKUP_RETENTION_DAYS`   | Хранить бэкапы N дней (локально и GDrive) |
| `BACKUP_SCHEDULE`         | Cron расписание (по умолчанию 02:00)  |
| `GOOGLE_DRIVE_ENABLED`    | `true` / `false`                      |
| `GOOGLE_DRIVE_FOLDER_ID`  | ID папки в Google Drive               |
| `TG_BOT_TOKEN`            | Telegram уведомления                  |

### Включить Google Drive

В `.env` выставить:
```env
GOOGLE_DRIVE_ENABLED=true
GOOGLE_DRIVE_CLIENT_ID=...
GOOGLE_DRIVE_CLIENT_SECRET=...
GOOGLE_DRIVE_REFRESH_TOKEN=...
GOOGLE_DRIVE_FOLDER_ID=...
```

Как получить токены — см. `influxdb-backup/scripts/GOOGLE_DRIVE_SETUP.md`.

---

## Копирование на сервер

### Первый деплой

```bash
# Из корня m2-backend (локально):
rsync -av dbark/ root@server.com:/opt/m2-deployment/dbark/
```

> **rsync vs scp:**
> `rsync -av` копирует только изменённые файлы, сохраняет права и временные метки — быстрее и безопаснее для обновлений.
> `scp -r` всегда копирует всё заново.
> По умолчанию `rsync` не удаляет файлы на сервере если они удалены локально — для полного зеркалирования добавь флаг `--delete`.

### Обновление конфигов или скриптов (перезалить и перезапустить)

```bash
# Из корня m2-backend (локально):
rsync -av dbark/ root@server.com:/opt/m2-deployment/dbark/ && \
ssh root@server.com "
  cd /opt/m2-deployment/dbark/mysql-backup && bash manage.sh stop && bash manage.sh start
  cd /opt/m2-deployment/dbark/influxdb-backup && bash manage.sh stop && bash manage.sh build && bash manage.sh start
"
```

> `influxdb-backup` требует `build` при изменении скриптов — они копируются в образ через Dockerfile.
> `mysql-backup` монтирует скрипты как volume, поэтому `build` не нужен.

---

## Запуск на сервере

```bash
# Создать директории для хранения бэкапов (один раз)
mkdir -p /opt/m2-deployment/backups/mysql
mkdir -p /opt/m2-deployment/backups/influxdb

# Создать volume для InfluxDB (один раз)
docker volume create docker_influxdb_backups

# MySQL backup (требует сборки)
cd /opt/m2-deployment/dbark/mysql-backup
bash manage.sh build
bash manage.sh start

# InfluxDB backup (требует сборки)
cd /opt/m2-deployment/dbark/influxdb-backup
bash manage.sh build
bash manage.sh start

# Проверить статус
docker ps | grep backup
```

---

## Управление

```bash
bash manage.sh start    # Запустить
bash manage.sh stop     # Остановить
bash manage.sh restart  # Перезапустить
bash manage.sh status   # Статус контейнера
bash manage.sh logs     # Логи
bash manage.sh backup   # Запустить бэкап вручную (не ждать cron)
```

---

## Расписание и хранение

- **Автоматически:** каждый день в 02:00
- **Локально:** `/opt/m2-deployment/backups/mysql` и `/opt/m2-deployment/backups/influxdb`
- **Срок хранения:** `BACKUP_RETENTION_DAYS` дней (локально и в Google Drive)
- **Уведомления:** Telegram при успехе и ошибке
