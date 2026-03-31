#!/usr/bin/env python3

import os
import json
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build

# Области доступа
SCOPES = ['https://www.googleapis.com/auth/drive.file']

def get_refresh_token():
    """Получение refresh token для Google Drive API"""
    
    print("=== Настройка Google Drive для бэкапов ===")
    print()
    print("1. Перейдите в Google Cloud Console: https://console.cloud.google.com/")
    print("2. Создайте проект или выберите существующий")
    print("3. Включите Google Drive API")
    print("4. Создайте OAuth 2.0 Client ID (Desktop application)")
    print("5. Скачайте JSON файл с учетными данными")
    print()
    
    credentials_file = input("Введите путь к файлу credentials.json: ")
    
    if not os.path.exists(credentials_file):
        print(f"Файл {credentials_file} не найден!")
        return
    
    try:
        flow = InstalledAppFlow.from_client_secrets_file(
            credentials_file, SCOPES)
        
        # Запуск локального сервера для авторизации
        creds = flow.run_local_server(port=0)
        
        print()
        print("=== Учетные данные для .env файла ===")
        print(f"GOOGLE_DRIVE_CLIENT_ID={creds.client_id}")
        print(f"GOOGLE_DRIVE_CLIENT_SECRET={creds.client_secret}")
        print(f"GOOGLE_DRIVE_REFRESH_TOKEN={creds.refresh_token}")
        print()
        
        # Тест API
        service = build('drive', 'v3', credentials=creds)
        results = service.files().list(pageSize=1).execute()
        print("✓ API работает корректно")
        
        # Создание папки для бэкапов
        folder_metadata = {
            'name': 'InfluxDB-Backups',
            'mimeType': 'application/vnd.google-apps.folder'
        }
        
        folder = service.files().create(body=folder_metadata).execute()
        print(f"✓ Создана папка для бэкапов с ID: {folder['id']}")
        print(f"GOOGLE_DRIVE_FOLDER_ID={folder['id']}")
        
    except Exception as e:
        print(f"Ошибка: {e}")

if __name__ == '__main__':
    get_refresh_token()