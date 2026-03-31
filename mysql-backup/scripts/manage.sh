#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$SCRIPTS_DIR")"
DOCKER_DIR="$PROJECT_ROOT/docker"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка Docker Compose
check_docker_compose() {
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        error "Docker Compose не найден"
        exit 1
    fi
    
    # Определение команды docker compose
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
    else
        DOCKER_COMPOSE="docker-compose"
    fi
}

# Создание необходимых директорий
setup_directories() {
    log "Создание необходимых директорий..."
    
    local backup_storage_path="/opt/m2-deployment/backups/mysql"
    
    # Создание локальных директорий
    sudo mkdir -p "$backup_storage_path"
    sudo chown -R 1000:1000 "$backup_storage_path" 2>/dev/null || true
    
    log "Директории созданы"
}

# Запуск системы бэкапов
start_backup_system() {
    log "Запуск системы бэкапов MySQL..."
    
    cd "$DOCKER_DIR"
    
    # Проверка конфигурации
    if [[ ! -f ".env.mysql.backup" ]]; then
        warn "Файл .env.mysql.backup не найден."
        echo "Запустите сначала: ./scripts/mysql/setup.sh"
        return 1
    fi
    
    # Проверка, что основная система запущена
    log "Проверка MySQL контейнера..."
    if ! docker ps --format "{{.Names}}" | grep -q "^m2_mysql$"; then
        warn "MySQL контейнер 'm2_mysql' не запущен."
        log "Запущенные контейнеры:"
        docker ps --format "table {{.Names}}\t{{.Status}}"
        warn "Запустите основную систему сначала:"
        echo "  docker-compose -f docker-compose.ci-prod.yml up -d mysql"
        return 1
    fi
    log "MySQL контейнер найден"
    
    # Проверка сети
    log "Проверка Docker сети..."
    if ! docker network ls --format "{{.Name}}" | grep -q "^docker_m2_network$"; then
        warn "Docker сеть 'docker_m2_network' не найдена."
        log "Доступные сети:"
        docker network ls
        warn "Убедитесь, что основная система запущена:"
        echo "  docker-compose -f docker-compose.ci-prod.yml up -d"
        return 1
    fi
    log "Docker сеть найдена"
    
    # Запуск сервисов
    log "Запуск контейнеров бэкапов..."
    
    if (cd "$DOCKER_DIR" && $DOCKER_COMPOSE -f docker-compose.mysql.backup.yml --env-file ../.env.mysql.backup up -d); then
        log "Система бэкапов запущена"
        
        # Ожидание готовности
        log "Ожидание готовности сервисов..."
        sleep 5
        
        # Показ статуса
        show_status
    else
        error "Ошибка запуска системы бэкапов"
        return 1
    fi
}

# Остановка системы бэкапов
stop_backup_system() {
    log "Остановка системы бэкапов..."
    
    cd "$DOCKER_DIR"
    
    # Остановка основного compose файла
    (cd "$DOCKER_DIR" && $DOCKER_COMPOSE -f docker-compose.mysql.backup.yml down)
    
    log "Система бэкапов остановлена"
}

# Показ статуса
show_status() {
    log "Статус системы бэкапов:"
    
    cd "$DOCKER_DIR"
    
    # Проверяем какая версия запущена
    if docker ps --format "{{.Names}}" | grep -q "^m2_mysql_backup$"; then
        echo "✅ Сервис бэкапов запущен"
        docker ps --filter "name=m2_mysql_backup" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    else
        echo "❌ Сервис бэкапов не запущен"
        log "Запущенные контейнеры с 'backup' в имени:"
        docker ps --format "{{.Names}}" | grep backup || echo "Нет контейнеров с 'backup' в имени"
    fi
    
    echo
    log "Последние логи бэкапов:"
    docker exec m2_mysql_backup tail -n 10 /var/log/backup/backup.log 2>/dev/null || echo "Логи бэкапов недоступны"
    
    echo
    log "Доступные бэкапы:"
    docker exec m2_mysql_backup ls -la /backups/ 2>/dev/null || echo "Бэкапы недоступны"
}

# Создание бэкапа вручную
create_backup() {
    log "Создание бэкапа вручную..."
    
    if ! docker exec m2_mysql_backup /app/scripts/backup.sh; then
        error "Ошибка создания бэкапа"
        return 1
    fi
    
    log "Бэкап создан успешно"
}

# Интерактивное восстановление
restore_interactive() {
    log "Запуск интерактивного восстановления..."
    
    docker exec -it m2_mysql_backup /app/scripts/restore.sh interactive
}

# Синхронизация с удаленным сервером
sync_remote() {
    log "Запуск синхронизации с удаленным сервером..."
    
    if ! docker exec m2_mysql_backup /app/scripts/sync-remote.sh sync; then
        error "Ошибка синхронизации с удаленным сервером"
        return 1
    fi
    
    log "Синхронизация завершена успешно"
}

# Показ логов
show_logs() {
    local service=${1:-backup}
    
    case "$service" in
        "backup")
            log "Логи сервиса бэкапов:"
            docker logs -f m2_mysql_backup
            ;;
        "monitor")
            log "Логи мониторинга:"
            docker exec m2_mysql_backup tail -f /var/log/backup/monitor.log 2>/dev/null || echo "Логи мониторинга недоступны"
            ;;
        *)
            log "Все логи сервиса бэкапов:"
            docker logs -f m2_mysql_backup
            ;;
    esac
}

# Проверка здоровья системы
health_check() {
    log "Проверка здоровья системы бэкапов..."
    
    if docker exec m2_mysql_backup /app/scripts/health-check.sh; then
        log "Система работает нормально"
    else
        warn "Обнаружены проблемы"
    fi
}

# Очистка старых бэкапов
cleanup_backups() {
    local days=${1:-30}
    
    log "Очистка бэкапов старше $days дней..."
    
    # Локальные бэкапы
    docker exec m2_mysql_backup find /backups -name "backup_*" -type f -mtime +$days -delete
    
    # Бэкапы в хранилище
    docker exec m2_mysql_backup find /backup-storage -name "backup_*" -type f -mtime +$days -delete 2>/dev/null || true
    
    log "Очистка завершена"
}

# Удаление локальных бэкапов и pre-restore файлов
cleanup_local() {
    local type=${1:-"all"}
    
    case "$type" in
        "backups")
            log "Удаление всех локальных бэкапов..."
            docker exec m2_mysql_backup find /backups -name "backup_*" -type f -delete 2>/dev/null || true
            log "Локальные бэкапы удалены"
            ;;
        "pre-restore")
            log "Удаление всех pre-restore файлов..."
            docker exec m2_mysql_backup find /backups -name "pre-restore-*" -type f -delete 2>/dev/null || true
            log "Pre-restore файлы удалены"
            ;;
        "all")
            log "Удаление всех локальных файлов бэкапов..."
            docker exec m2_mysql_backup find /backups -name "backup_*" -o -name "pre-restore-*" -type f -delete 2>/dev/null || true
            log "Все локальные файлы бэкапов удалены"
            ;;
        *)
            error "Неверный тип: $type"
            echo "Доступные типы: backups, pre-restore, all"
            return 1
            ;;
    esac
    
    # Показать оставшиеся файлы
    echo ""
    log "Оставшиеся файлы:"
    docker exec m2_mysql_backup ls -la /backups/ 2>/dev/null || echo "Директория недоступна"
}

# Управление расписанием бэкапов
manage_schedule() {
    local action=${1:-"show"}
    local schedule=${2:-"0 2 * * *"}  # По умолчанию каждый день в 2:00
    
    case "$action" in
        "show")
            log "Текущее расписание бэкапов:"
            docker exec m2_mysql_backup crontab -l 2>/dev/null | grep backup || echo "Расписание не найдено"
            ;;
        "set")
            log "Установка нового расписания: $schedule"
            # Создаем новый crontab с расписанием
            docker exec m2_mysql_backup bash -c "echo '$schedule /app/scripts/backup.sh' | crontab -"
            log "Расписание установлено"
            
            # Перезапускаем cron
            docker exec m2_mysql_backup service cron restart 2>/dev/null || true
            
            # Показываем новое расписание
            manage_schedule "show"
            ;;
        "disable")
            log "Отключение автоматических бэкапов..."
            docker exec m2_mysql_backup crontab -r 2>/dev/null || true
            log "Автоматические бэкапы отключены"
            ;;
        "examples")
            echo "Примеры расписаний (формат cron):"
            echo "  '0 2 * * *'     - каждый день в 2:00"
            echo "  '0 */6 * * *'   - каждые 6 часов"
            echo "  '0 2 * * 0'     - каждое воскресенье в 2:00"
            echo "  '*/30 * * * *'  - каждые 30 минут"
            echo "  '0 2,14 * * *'  - каждый день в 2:00 и 14:00"
            echo ""
            echo "Использование:"
            echo "  $0 schedule set '0 */4 * * *'  # каждые 4 часа"
            echo "  $0 schedule show               # показать текущее"
            echo "  $0 schedule disable            # отключить"
            ;;
        *)
            error "Неверное действие: $action"
            echo "Доступные действия: show, set, disable, examples"
            return 1
            ;;
    esac
}

# Показ справки
show_help() {
    echo "Управление системой бэкапов MySQL"
    echo
    echo "Использование: $0 [КОМАНДА] [ОПЦИИ]"
    echo
    echo "Команды:"
    echo "  setup              Настройка директорий и разрешений"
    echo "  start              Запуск системы бэкапов"
    echo "  stop               Остановка системы бэкапов"
    echo "  restart            Перезапуск системы бэкапов"
    echo "  status             Показать статус системы"
    echo "  backup             Создать бэкап вручную"
    echo "  restore            Интерактивное восстановление"
    echo "  sync               Синхронизация с удаленным сервером"
    echo "  logs [service]     Показать логи (backup/monitor)"
    echo "  health             Проверка здоровья системы"
    echo "  cleanup [days]     Очистка старых бэкапов (по умолчанию 30 дней)"
    echo "  clean-local [type] Удаление локальных файлов (backups/pre-restore/all)"
    echo "  schedule [action]  Управление расписанием бэкапов (show/set/disable/examples)"
    echo "  help               Показать эту справку"
    echo
    echo "Примеры:"
    echo "  $0 setup"
    echo "  $0 start"
    echo "  $0 backup"
    echo "  $0 restore"
    echo "  $0 sync"
    echo "  $0 logs backup"
    echo "  $0 cleanup 7"
    echo "  $0 clean-local backups"
    echo "  $0 clean-local pre-restore"
    echo "  $0 schedule show"
    echo "  $0 schedule set '0 */6 * * *'"
    echo "  $0 schedule examples"
}

# Основная функция
main() {
    check_docker_compose
    
    case "${1:-help}" in
        "setup")
            setup_directories
            ;;
        "start")
            setup_directories
            start_backup_system
            ;;
        "stop")
            stop_backup_system
            ;;
        "restart")
            stop_backup_system
            sleep 2
            start_backup_system
            ;;
        "status")
            show_status
            ;;
        "backup")
            create_backup
            ;;
        "restore")
            restore_interactive
            ;;
        "sync")
            sync_remote
            ;;
        "logs")
            show_logs "${2:-backup}"
            ;;
        "health")
            health_check
            ;;
        "cleanup")
            cleanup_backups "${2:-30}"
            ;;
        "clean-local")
            cleanup_local "${2:-all}"
            ;;
        "schedule")
            manage_schedule "${2:-show}" "${3:-}"
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            error "Неизвестная команда: $1"
            show_help
            exit 1
            ;;
    esac
}

# Запуск
main "$@"