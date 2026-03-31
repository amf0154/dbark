#!/usr/bin/env python3

import os
import sys
import json
import logging
from pathlib import Path
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload, MediaIoBaseDownload
from googleapiclient.errors import HttpError

# Настройка логирования
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class GoogleDriveBackup:
    def __init__(self):
        self.client_id = os.getenv('GOOGLE_DRIVE_CLIENT_ID')
        self.client_secret = os.getenv('GOOGLE_DRIVE_CLIENT_SECRET')
        self.refresh_token = os.getenv('GOOGLE_DRIVE_REFRESH_TOKEN')
        self.folder_id = os.getenv('GOOGLE_DRIVE_FOLDER_ID')
        
        if not all([self.client_id, self.client_secret, self.refresh_token]):
            raise ValueError("Не все переменные Google Drive настроены")
        
        self.service = self._get_service()
    
    def _get_service(self):
        """Создание сервиса Google Drive API"""
        try:
            # Создание credentials из refresh token
            creds = Credentials(
                token=None,
                refresh_token=self.refresh_token,
                token_uri='https://oauth2.googleapis.com/token',
                client_id=self.client_id,
                client_secret=self.client_secret
            )
            
            # Обновление токена
            creds.refresh(Request())
            
            # Создание сервиса
            service = build('drive', 'v3', credentials=creds)
            logger.info("Google Drive API сервис создан успешно")
            return service
            
        except Exception as e:
            logger.error(f"Ошибка создания Google Drive сервиса: {e}")
            raise
    
    def create_folder_if_not_exists(self, folder_name, parent_id=None):
        """Создание папки если она не существует"""
        try:
            # Поиск существующей папки
            query = f"name='{folder_name}' and mimeType='application/vnd.google-apps.folder'"
            if parent_id:
                query += f" and '{parent_id}' in parents"
            
            results = self.service.files().list(q=query).execute()
            items = results.get('files', [])
            
            if items:
                logger.info(f"Папка '{folder_name}' уже существует")
                return items[0]['id']
            
            # Создание новой папки
            folder_metadata = {
                'name': folder_name,
                'mimeType': 'application/vnd.google-apps.folder'
            }
            
            if parent_id:
                folder_metadata['parents'] = [parent_id]
            
            folder = self.service.files().create(body=folder_metadata).execute()
            logger.info(f"Создана папка '{folder_name}' с ID: {folder['id']}")
            return folder['id']
            
        except HttpError as e:
            logger.error(f"Ошибка создания папки: {e}")
            raise
    
    def upload_file(self, file_path, folder_id=None):
        """Загрузка файла в Google Drive"""
        try:
            file_path = Path(file_path)
            if not file_path.exists():
                raise FileNotFoundError(f"Файл не найден: {file_path}")
            
            # Определение папки для загрузки
            target_folder_id = folder_id or self.folder_id
            
            # Создание папки для бэкапов InfluxDB если не указана конкретная папка
            if not target_folder_id:
                target_folder_id = self.create_folder_if_not_exists('InfluxDB-Backups')
            
            # Создание папки по environment и дате
            import os
            from datetime import datetime
            
            environment = os.getenv('ENVIRONMENT', 'staging')
            env_folder_id = self.create_folder_if_not_exists(environment, target_folder_id)
            
            date_folder = datetime.now().strftime('%Y-%m')
            date_folder_id = self.create_folder_if_not_exists(date_folder, env_folder_id)
            
            # Метаданные файла
            file_metadata = {
                'name': file_path.name,
                'parents': [date_folder_id]
            }
            
            # Загрузка файла
            media = MediaFileUpload(str(file_path), resumable=True)
            
            logger.info(f"Начало загрузки файла: {file_path.name}")
            file = self.service.files().create(
                body=file_metadata,
                media_body=media,
                fields='id,name,size'
            ).execute()
            
            logger.info(f"Файл загружен успешно. ID: {file['id']}, Размер: {file.get('size', 'unknown')} байт")
            return file['id']
            
        except HttpError as e:
            logger.error(f"Ошибка загрузки файла: {e}")
            raise
        except Exception as e:
            logger.error(f"Общая ошибка загрузки: {e}")
            raise
    
    def list_backups(self, folder_id=None):
        """Получение списка бэкапов"""
        try:
            target_folder_id = folder_id or self.folder_id
            
            if not target_folder_id:
                # Поиск папки с бэкапами
                results = self.service.files().list(
                    q="name='InfluxDB-Backups' and mimeType='application/vnd.google-apps.folder'"
                ).execute()
                items = results.get('files', [])
                if not items:
                    logger.info("Папка с бэкапами не найдена")
                    return []
                target_folder_id = items[0]['id']
            
            # Рекурсивный поиск всех файлов бэкапов
            all_files = []
            self._search_backups_recursive(target_folder_id, all_files)
            
            return all_files
            
        except HttpError as e:
            logger.error(f"Ошибка получения списка бэкапов: {e}")
            return []
    
    def _search_backups_recursive(self, folder_id, all_files):
        """Рекурсивный поиск бэкапов во всех подпапках"""
        try:
            # Получение всех файлов в текущей папке
            query = f"'{folder_id}' in parents"
            results = self.service.files().list(
                q=query,
                fields="files(id,name,size,createdTime,parents,mimeType)"
            ).execute()
            
            files = results.get('files', [])
            
            for file in files:
                if file.get('mimeType') == 'application/vnd.google-apps.folder':
                    # Это папка, ищем файлы в ней рекурсивно
                    self._search_backups_recursive(file['id'], all_files)
                elif (file['name'].endswith('.tar.gz') and 
                      ('backup_' in file['name'] or 'm2_' in file['name'] or 'influxdb_' in file['name'])):
                    # Это файл бэкапа с любым префиксом
                    all_files.append(file)
                    
        except HttpError as e:
            logger.error(f"Ошибка поиска в папке {folder_id}: {e}")
            
        except HttpError as e:
            logger.error(f"Ошибка получения списка бэкапов: {e}")
            return []
    
    def delete_old_backups(self, retention_days=30):
        """Удаление старых бэкапов"""
        try:
            from datetime import datetime, timedelta
            
            cutoff_date = datetime.now() - timedelta(days=retention_days)
            backups = self.list_backups()
            
            deleted_count = 0
            for backup in backups:
                created_time = datetime.fromisoformat(backup['createdTime'].replace('Z', '+00:00'))
                
                if created_time < cutoff_date:
                    try:
                        self.service.files().delete(fileId=backup['id']).execute()
                        logger.info(f"Удален старый бэкап: {backup['name']}")
                        deleted_count += 1
                    except HttpError as e:
                        logger.error(f"Ошибка удаления файла {backup['name']}: {e}")
            
            logger.info(f"Удалено старых бэкапов: {deleted_count}")
            return deleted_count
            
        except Exception as e:
            logger.error(f"Ошибка очистки старых бэкапов: {e}")
            return 0
    
    def download_file(self, file_id, local_path):
        """Скачивание файла из Google Drive"""
        try:
            request = self.service.files().get_media(fileId=file_id)
            
            with open(local_path, 'wb') as f:
                downloader = MediaIoBaseDownload(f, request)
                done = False
                while done is False:
                    status, done = downloader.next_chunk()
                    logger.info(f"Скачивание: {int(status.progress() * 100)}%")
            
            logger.info(f"Файл скачан: {local_path}")
            return True
            
        except HttpError as e:
            logger.error(f"Ошибка скачивания файла: {e}")
            return False
    
    def find_file_by_name(self, filename):
        """Поиск файла по имени"""
        try:
            # Поиск файла по точному имени
            query = f"name='{filename}'"
            results = self.service.files().list(
                q=query,
                fields="files(id,name,size,createdTime)"
            ).execute()
            
            files = results.get('files', [])
            if files:
                return files[0]  # Возвращаем первый найденный файл
            
            # Если не найден, попробуем поиск по части имени
            query = f"name contains '{filename}'"
            results = self.service.files().list(
                q=query,
                fields="files(id,name,size,createdTime)"
            ).execute()
            
            files = results.get('files', [])
            if files:
                # Ищем наиболее точное совпадение
                for file in files:
                    if filename in file['name']:
                        return file
                return files[0]  # Если точного совпадения нет, возвращаем первый
            
            return None
            
        except HttpError as e:
            logger.error(f"Ошибка поиска файла: {e}")
            return None
    
    def download_by_name(self, filename, local_path):
        """Скачивание файла по имени"""
        try:
            file_info = self.find_file_by_name(filename)
            if not file_info:
                logger.error(f"Файл не найден: {filename}")
                return False
            
            logger.info(f"Найден файл: {file_info['name']} (ID: {file_info['id']})")
            return self.download_file(file_info['id'], local_path)
            
        except Exception as e:
            logger.error(f"Ошибка скачивания файла по имени: {e}")
            return False

def main():
    """Основная функция для тестирования"""
    import sys
    
    if len(sys.argv) < 2:
        print("Использование:")
        print("  python3 google_drive.py upload <file_path>")
        print("  python3 google_drive.py list")
        print("  python3 google_drive.py download <filename> <local_path>")
        print("  python3 google_drive.py find <filename>")
        print("  python3 google_drive.py cleanup [days]")
        return
    
    try:
        drive = GoogleDriveBackup()
        
        command = sys.argv[1]
        
        if command == 'upload' and len(sys.argv) > 2:
            file_path = sys.argv[2]
            file_id = drive.upload_file(file_path)
            print(f"Файл загружен с ID: {file_id}")
            
        elif command == 'list':
            backups = drive.list_backups()
            print(f"Найдено бэкапов: {len(backups)}")
            if backups:
                print("Список бэкапов в Google Drive:")
                for backup in backups:
                    size_mb = int(backup.get('size', 0)) / (1024 * 1024)
                    created_date = backup['createdTime'][:10]  # Только дата
                    print(f"{backup['name']} ({size_mb:.1f} MB) - {created_date}")
            else:
                print("Бэкапы не найдены. Возможные причины:")
                print("  - Бэкапы еще не загружались в Google Drive")
                print("  - Проблемы с доступом к Google Drive API")
                print("  - Бэкапы находятся в другой папке")
                
        elif command == 'download' and len(sys.argv) > 3:
            filename = sys.argv[2]
            local_path = sys.argv[3]
            success = drive.download_by_name(filename, local_path)
            if success:
                # Не выводим сообщение в stdout, только возвращаем код успеха
                pass
            else:
                print(f"Ошибка скачивания файла: {filename}", file=sys.stderr)
                sys.exit(1)
                
        elif command == 'find' and len(sys.argv) > 2:
            filename = sys.argv[2]
            file_info = drive.find_file_by_name(filename)
            if file_info:
                size_mb = int(file_info.get('size', 0)) / (1024 * 1024)
                created_date = file_info['createdTime'][:10]
                print(f"Найден файл: {file_info['name']}")
                print(f"ID: {file_info['id']}")
                print(f"Размер: {size_mb:.1f} MB")
                print(f"Дата создания: {created_date}")
            else:
                print(f"Файл не найден: {filename}")
                
        elif command == 'cleanup':
            days = int(sys.argv[2]) if len(sys.argv) > 2 else 30
            deleted = drive.delete_old_backups(days)
            print(f"Удалено файлов: {deleted}")
            
        else:
            print("Неизвестная команда")
            print("Доступные команды:")
            print("  upload <file_path>")
            print("  list")
            print("  download <filename> <local_path>")
            print("  find <filename>")
            print("  cleanup [days]")
            
    except Exception as e:
        logger.error(f"Ошибка: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()