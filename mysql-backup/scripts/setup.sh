#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
DOCKER_DIR="$PROJECT_ROOT/docker"

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[SETUP]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Создание конфигурационного файла
create_config() {
    local config_file="$DOCKER_DIR/.env.mysql.backup"
    
    if [[ -f "$config_file" ]]; then
        log "Конфигурационный файл уже существует: $config_file"
        return 0
    fi
    
    log "Создание конфигурационного файла..."
    
    # Попытка получить настройки из основного .env файла
    local main_env="$PROJECT_ROOT/.env.production"
    if [[ ! -f "$main_env" ]]; then
        main_env="$PROJECT_ROOT/.env"
    fi
    
    # Значения по умолчанию
    local mysql_host="mysql"
    local mysql_port="3306"
    local mysql_root_password="ArGenTum2023@m2"
    local mysql_database="m2hydro_prod"
    local mysql_user="m2user"
    local mysql_password="your_user_password"
    local tg_bot_token="6429183639:AAHN3rDqYVl9_rU6QnZns_hjvKzggUevJSI"
    local tg_chat_id="-1001721174107"
    
    # Попытка извлечь значения из основного .env
    if [[ -f "$main_env" ]]; then
        log "Извлечение настроек из $main_env"
        mysql_host=$(grep "^MYSQL_HOST=" "$main_env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "$mysql_host")
        mysql_port=$(grep "^MYSQL_PORT=" "$main_env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "$mysql_port")
        mysql_root_password=$(grep "^MYSQL_ROOT_PASSWORD=" "$main_env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "$mysql_root_password")
        mysql_database=$(grep "^MYSQL_DATABASE=" "$main_env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "$mysql_database")
        mysql_user=$(grep "^MYSQL_USER=" "$main_env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "$mysql_user")
        mysql_password=$(grep "^MYSQL_PASSWORD=" "$main_env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "$mysql_password")
        tg_bot_token=$(grep "^TG_BOT_TOKEN=" "$main_env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "$tg_bot_token")
        tg_chat_id=$(grep "^TG_CHAT_ID=" "$main_env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "$tg_chat_id")
    fi
    
    # Создание конфигурационного файла
    cat > "$config_file" << EOF
# MySQL Configuration (автоматически извлечено из основной конфигурации)
MYSQL_HOST=$mysql_host
MYSQL_PORT=$mysql_port
MYSQL_ROOT_PASSWORD=$mysql_root_password
MYSQL_DATABASE=$mysql_database
MYSQL_USER=$mysql_user
MYSQL_PASSWORD=$mysql_password

# Backup Configuration
BACKUP_SCHEDULE=0 2 * * *  # Каждый день в 2:00
BACKUP_RETENTION_DAYS=30
BACKUP_COMPRESSION=true
CREATE_INITIAL_BACKUP=false
ENABLE_MONITORING=true

# Backup Options
BACKUP_TYPE=full  # full, schema, data
BACKUP_SINGLE_TRANSACTION=true
BACKUP_ROUTINES=true
BACKUP_TRIGGERS=true
BACKUP_EVENTS=true

# Monitoring Configuration
MONITOR_INTERVAL=300  # 5 минут
MAX_BACKUP_AGE_HOURS=25

# Remote Backup (Google Drive) - опционально
GOOGLE_DRIVE_ENABLED=true
GOOGLE_DRIVE_CLIENT_ID=your-client-id.apps.googleusercontent.com
GOOGLE_DRIVE_CLIENT_SECRET=your-client-secret
GOOGLE_DRIVE_REDIRECT_URI=https://developers.google.com/oauthplayground
GOOGLE_DRIVE_REFRESH_TOKEN=your-refresh-token

# Notifications (автоматически извлечено из основной конфигурации)
TG_BOT_TOKEN=$tg_bot_token
TG_CHAT_ID=$tg_chat_id
BACKUP_WEBHOOK_URL=

# Paths
BACKUP_STORAGE_PATH=/opt/m2-deployment/backups/mysql

# Environment
ENVIRONMENT=production
BACKUP_PREFIX=backup

# Remote Sync Configuration (для синхронизации с удаленным сервером)
REMOTE_MYSQL_HOST=api.m2m.by
REMOTE_MYSQL_PORT=3306
REMOTE_MYSQL_USER=root
REMOTE_MYSQL_PASSWORD=your_remote_password
REMOTE_MYSQL_DATABASE=m2hydro
EOF
    
    log "Конфигурационный файл создан: $config_file"
    
    if [[ "$mysql_root_password" == "your_secure_password" ]]; then
        warn "ВНИМАНИЕ: Не удалось автоматически определить MYSQL_ROOT_PASSWORD"
        warn "Отредактируйте файл $config_file и укажите правильный пароль"
    fi
}

# Создание необходимых директорий
create_directories() {
    log "Создание директорий для бэкапов..."
    
    local backup_dir="/opt/m2-deployment/backups/mysql"
    
    if [[ ! -d "$backup_dir" ]]; then
        sudo mkdir -p "$backup_dir" || {
            error "Не удалось создать директорию $backup_dir"
            error "Выполните вручную: sudo mkdir -p $backup_dir"
            return 1
        }
        
        # Попытка установить права доступа
        sudo chown -R 1000:1000 "$backup_dir" 2>/dev/null || {
            warn "Не удалось установить права доступа для $backup_dir"
            warn "Возможно потребуется выполнить: sudo chown -R 1000:1000 $backup_dir"
        }
    fi
    
    log "Директории созданы"
}

# Проверка Docker и docker-compose
check_docker() {
    log "Проверка Docker..."
    
    if ! command -v docker &> /dev/null; then
        error "Docker не найден"
        return 1
    fi
    
    if ! docker ps &> /dev/null; then
        error "Docker не запущен или нет прав доступа"
        return 1
    fi
    
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        error "Docker Compose не найден"
        return 1
    fi
    
    log "Docker проверен"
}

# Проверка основной системы
check_main_system() {
    log "Проверка основной системы..."
    
    if ! docker ps | grep -q "m2_mysql"; then
        warn "MySQL контейнер не запущен"
        warn "Запустите основную систему: docker-compose -f docker/docker-compose.ci-prod.yml up -d mysql"
        return 1
    fi
    
    log "Основная система работает"
}

# Создание Docker Compose файла для бэкапов
create_docker_compose() {
    local compose_file="$DOCKER_DIR/docker-compose.mysql.backup.yml"
    
    if [[ -f "$compose_file" ]]; then
        log "Docker Compose файл уже существует: $compose_file"
        return 0
    fi
    
    log "Создание Docker Compose файла для бэкапов..."
    
    cat > "$compose_file" << 'EOF'
services:
  mysql-backup:
    image: ubuntu:22.04
    container_name: m2_mysql_backup
    restart: unless-stopped
    networks:
      - m2_network
    volumes:
      - ../scripts/mysql:/app/scripts:ro
      - /opt/m2-deployment/backups/mysql:/backup-storage
      - mysql_backup_data:/backups
      - mysql_backup_logs:/var/log/backup
    environment:
      - MYSQL_HOST=${MYSQL_HOST}
      - MYSQL_PORT=${MYSQL_PORT}
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - BACKUP_SCHEDULE=${BACKUP_SCHEDULE}
      - BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS}
      - BACKUP_COMPRESSION=${BACKUP_COMPRESSION}
      - BACKUP_TYPE=${BACKUP_TYPE}
      - BACKUP_SINGLE_TRANSACTION=${BACKUP_SINGLE_TRANSACTION}
      - BACKUP_ROUTINES=${BACKUP_ROUTINES}
      - BACKUP_TRIGGERS=${BACKUP_TRIGGERS}
      - BACKUP_EVENTS=${BACKUP_EVENTS}
      - CREATE_INITIAL_BACKUP=${CREATE_INITIAL_BACKUP}
      - ENABLE_MONITORING=${ENABLE_MONITORING}
      - MONITOR_INTERVAL=${MONITOR_INTERVAL}
      - MAX_BACKUP_AGE_HOURS=${MAX_BACKUP_AGE_HOURS}
      - GOOGLE_DRIVE_ENABLED=${GOOGLE_DRIVE_ENABLED}
      - GOOGLE_DRIVE_CLIENT_ID=${GOOGLE_DRIVE_CLIENT_ID}
      - GOOGLE_DRIVE_CLIENT_SECRET=${GOOGLE_DRIVE_CLIENT_SECRET}
      - GOOGLE_DRIVE_REFRESH_TOKEN=${GOOGLE_DRIVE_REFRESH_TOKEN}
      - GOOGLE_DRIVE_FOLDER_ID=${GOOGLE_DRIVE_FOLDER_ID}
      - TG_BOT_TOKEN=${TG_BOT_TOKEN}
      - TG_CHAT_ID=${TG_CHAT_ID}
      - TELEGRAM_BOT_TOKEN=${TG_BOT_TOKEN}
      - TELEGRAM_CHAT_ID=${TG_CHAT_ID}
      - BACKUP_WEBHOOK_URL=${BACKUP_WEBHOOK_URL}
      - ENVIRONMENT=${ENVIRONMENT}
      - BACKUP_PREFIX=${BACKUP_PREFIX}
      - REMOTE_MYSQL_HOST=${REMOTE_MYSQL_HOST}
      - REMOTE_MYSQL_PORT=${REMOTE_MYSQL_PORT}
      - REMOTE_MYSQL_USER=${REMOTE_MYSQL_USER}
      - REMOTE_MYSQL_PASSWORD=${REMOTE_MYSQL_PASSWORD}
      - REMOTE_MYSQL_DATABASE=${REMOTE_MYSQL_DATABASE}
    entrypoint: ["/app/scripts/entrypoint.sh"]
    # depends_on:
    #   - mysql  # Закомментировано, так как MySQL может быть в другом compose файле
    healthcheck:
      test: ["CMD-SHELL", "/app/scripts/health-check.sh"]
      interval: 5m
      timeout: 30s
      retries: 3

networks:
  m2_network:
    external: true
    name: docker_m2_network

volumes:
  mysql_backup_data:
    driver: local
  mysql_backup_logs:
    driver: local
EOF
    
    log "Docker Compose файл создан: $compose_file"
}

# Основная функция
main() {
    log "=== Настройка системы бэкапов MySQL ==="
    
    check_docker
    create_config
    create_directories
    create_docker_compose
    
    log "=== Настройка завершена ==="
    echo
    log "Следующие шаги:"
    echo "1. Проверьте конфигурацию: $DOCKER_DIR/.env.mysql.backup"
    echo "2. Запустите основную систему (если не запущена): docker-compose -f docker/docker-compose.ci-prod.yml up -d mysql"
    echo "3. Запустите систему бэкапов: ./scripts/mysql/manage.sh start"
    echo "4. Создайте тестовый бэкап: ./scripts/mysql/manage.sh backup"
}

main "$@"