# Настройка Google Drive для бэкапов InfluxDB

## Шаг 1: Создание проекта в Google Cloud Console

1. Перейдите в [Google Cloud Console](https://console.cloud.google.com/)
2. Создайте новый проект или выберите существующий
3. Включите Google Drive API:
   - Перейдите в "APIs & Services" > "Library"
   - Найдите "Google Drive API"
   - Нажмите "Enable"

## Шаг 2: Создание учетных данных

1. Перейдите в "APIs & Services" > "Credentials"
2. Нажмите "Create Credentials" > "OAuth 2.0 Client IDs"
3. Выберите "Desktop application"
4. Дайте имя (например, "InfluxDB Backup")
5. Скачайте JSON файл с учетными данными

## Шаг 3: Получение Refresh Token

Создайте временный скрипт для получения refresh token:

```python
#!/usr/bin/env python3

import os
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build

# Области доступа
SCOPES = ['https://www.googleapis.com/auth/drive.file']

def get_refresh_token():
    """Получение refresh token для Google Drive API"""
    
    # Путь к файлу с учетными данными (скачанный JSON)
    credentials_file = 'path/to/your/credentials.json'
    
    flow = InstalledAppFlow.from_client_secrets_file(
        credentials_file, SCOPES)
    
    # Запуск локального сервера для авторизации
    creds = flow.run_local_server(port=0)
    
    print("=== Учетные данные для .env файла ===")
    print(f"GOOGLE_DRIVE_CLIENT_ID={creds.client_id}")
    print(f"GOOGLE_DRIVE_CLIENT_SECRET={creds.client_secret}")
    print(f"GOOGLE_DRIVE_REFRESH_TOKEN={creds.refresh_token}")
    
    # Тест API
    service = build('drive', 'v3', credentials=creds)
    results = service.files().list(pageSize=1).execute()
    print("✓ API работает корректно")

if __name__ == '__main__':
    get_refresh_token()
```

## Шаг 4: Настройка переменных окружения

Добавьте в файл `docker/.env.backup`:

```env
# Google Drive Configuration
GOOGLE_DRIVE_ENABLED=true
GOOGLE_DRIVE_CLIENT_ID=your_client_id_here
GOOGLE_DRIVE_CLIENT_SECRET=your_client_secret_here
GOOGLE_DRIVE_REFRESH_TOKEN=your_refresh_token_here
GOOGLE_DRIVE_FOLDER_ID=optional_specific_folder_id
```

## Шаг 5: Создание папки для бэкапов (опционально)

Если хотите использовать конкретную папку:

1. Создайте папку в Google Drive
2. Откройте папку в браузере
3. Скопируйте ID папки из URL (часть после `/folders/`)
4. Добавьте в `GOOGLE_DRIVE_FOLDER_ID`

## Шаг 6: Тестирование

```bash
# Запуск системы бэкапов
./scripts/influxdb/manage.sh start

# Создание тестового бэкапа
./scripts/influxdb/manage.sh backup

# Проверка загрузки в Google Drive
docker exec m2_influxdb_backup python3 /app/scripts/google_drive.py list
```

## Структура хранения в Google Drive

```
Google Drive/
└── InfluxDB-Backups/
    ├── 2025-07/
    │   ├── backup_2025-07-30_02-00.tar.gz
    │   └── backup_2025-07-29_02-00.tar.gz
    └── 2025-08/
        └── backup_2025-08-01_02-00.tar.gz
```

## Безопасность

1. **Ограничьте области доступа** - используйте только `drive.file`
2. **Храните учетные данные безопасно** - не коммитьте их в репозиторий
3. **Регулярно обновляйте токены** - мониторьте срок действия
4. **Используйте отдельный Google аккаунт** - для бэкапов

## Устранение неполадок

### Ошибка авторизации
```bash
# Проверка переменных окружения
docker exec m2_influxdb_backup env | grep GOOGLE_DRIVE

# Тест подключения
docker exec m2_influxdb_backup python3 /app/scripts/google_drive.py list
```

### Превышение квоты API
- Google Drive API имеет лимиты запросов
- При больших объемах данных используйте паузы между операциями
- Рассмотрите возможность использования Service Account

### Проблемы с загрузкой больших файлов
- Google Drive поддерживает resumable uploads
- Файлы больше 5GB загружаются частями
- При обрывах соединения загрузка продолжается автоматически

## Мониторинг использования

```bash
# Просмотр статистики Google Drive
docker exec m2_influxdb_backup python3 /app/scripts/google_drive.py list

# Очистка старых бэкапов
docker exec m2_influxdb_backup python3 /app/scripts/google_drive.py cleanup 30
```