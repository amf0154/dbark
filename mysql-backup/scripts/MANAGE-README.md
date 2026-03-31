# MySQL Backup Management - Руководство

Скрипт `manage.sh` предоставляет полное управление системой бэкапов MySQL.

## Новые функции

### 1. Управление расписанием бэкапов

#### Просмотр текущего расписания

```bash
./scripts/mysql/manage.sh schedule show
```

#### Установка нового расписания

```bash
# Каждые 6 часов
./scripts/mysql/manage.sh schedule set '0 */6 * * *'

# Каждый день в 3:00 утра
./scripts/mysql/manage.sh schedule set '0 3 * * *'

# Каждые 30 минут (для тестирования)
./scripts/mysql/manage.sh schedule set '*/30 * * * *'

# Два раза в день: в 2:00 и 14:00
./scripts/mysql/manage.sh schedule set '0 2,14 * * *'
```

#### Отключение автоматических бэкапов

```bash
./scripts/mysql/manage.sh schedule disable
```

#### Примеры расписаний

```bash
./scripts/mysql/manage.sh schedule examples
```

### 2. Очистка локальных файлов

#### Удаление всех pre-restore файлов

```bash
./scripts/mysql/manage.sh clean-local pre-restore
```

#### Удаление всех локальных бэкапов

```bash
./scripts/mysql/manage.sh clean-local backups
```

#### Удаление всех локальных файлов (бэкапы + pre-restore)

```bash
./scripts/mysql/manage.sh clean-local all
```

## Примеры использования

### Настройка частых бэкапов для активной разработки

```bash
# Установить бэкапы каждые 4 часа
./scripts/mysql/manage.sh schedule set '0 */4 * * *'

# Проверить статус
./scripts/mysql/manage.sh status

# Очистить старые pre-restore файлы
./scripts/mysql/manage.sh clean-local pre-restore
```

### Настройка редких бэкапов для стабильного production

```bash
# Установить бэкапы раз в день в 2:00
./scripts/mysql/manage.sh schedule set '0 2 * * *'

# Очистить бэкапы старше 7 дней
./scripts/mysql/manage.sh cleanup 7
```

### Подготовка к восстановлению

```bash
# Очистить все pre-restore файлы
./scripts/mysql/manage.sh clean-local pre-restore

# Посмотреть доступные бэкапы
./scripts/mysql/manage.sh status

# Запустить восстановление
./scripts/mysql/manage.sh restore
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
./scripts/mysql/manage.sh status
```

### Просмотр логов

```bash
./scripts/mysql/manage.sh logs backup
```

### Проверка здоровья

```bash
./scripts/mysql/manage.sh health
```

## Безопасность

-   **Pre-restore файлы** создаются автоматически перед каждым восстановлением
-   **Локальные бэкапы** хранятся в `/backups/` внутри контейнера
-   **Удаление файлов** необратимо - будьте осторожны
-   **Расписание** применяется немедленно и сохраняется при перезапуске

## Устранение проблем

### Если расписание не работает

```bash
# Проверить статус cron в контейнере
docker exec m2_mysql_backup service cron status

# Перезапустить cron
docker exec m2_mysql_backup service cron restart

# Проверить логи cron
docker exec m2_mysql_backup tail -f /var/log/backup/cron.log
```

### Если не хватает места

```bash
# Очистить старые бэкапы (старше 7 дней)
./scripts/mysql/manage.sh cleanup 7

# Очистить все pre-restore файлы
./scripts/mysql/manage.sh clean-local pre-restore

# Проверить размер директории
docker exec m2_mysql_backup du -sh /backups/
```
