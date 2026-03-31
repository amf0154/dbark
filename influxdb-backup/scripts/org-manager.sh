#!/bin/bash

set -euo pipefail

INFLUXDB_HOST=${INFLUXDB_HOST:-m2_influxdb}
INFLUXDB_PORT=${INFLUXDB_PORT:-8086}
INFLUXDB_TOKEN=${INFLUXDB_TOKEN}
LOG_FILE="/var/log/backup/org-manager.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Список всех организаций
list_organizations() {
    log "Получение списка организаций..."
    
    influx org list --json \
        --host "http://${INFLUXDB_HOST}:${INFLUXDB_PORT}" \
        --token "$INFLUXDB_TOKEN" | \
    jq -r '.[] | "\(.name) (\(.id))"'
}

# Список организаций с данными
list_organizations_with_data() {
    log "Поиск организаций с данными..."
    
    local orgs=$(influx org list --json \
        --host "http://${INFLUXDB_HOST}:${INFLUXDB_PORT}" \
        --token "$INFLUXDB_TOKEN" | \
    jq -r '.[].name')
    
    while IFS= read -r org; do
        if [[ -n "$org" && "$org" != "_"* ]]; then
            local bucket_count=$(influx bucket list --org "$org" \
                --host "http://${INFLUXDB_HOST}:${INFLUXDB_PORT}" \
                --token "$INFLUXDB_TOKEN" --json 2>/dev/null | \
            jq -r '. | length' 2>/dev/null || echo "0")
            
            if [[ $bucket_count -gt 0 ]]; then
                echo "$org ($bucket_count buckets)"
            fi
        fi
    done <<< "$orgs"
}

# Создание бэкапа конкретной организации
backup_organization() {
    local org_name=$1
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local backup_path="/backups/org_${org_name}_${timestamp}"
    
    log "Создание бэкапа организации: $org_name"
    
    mkdir -p "$backup_path"
    
    if influx backup "$backup_path" \
        --host "http://${INFLUXDB_HOST}:${INFLUXDB_PORT}" \
        --token "$INFLUXDB_TOKEN" \
        --org "$org_name" \
        --compression gzip; then
        
        log "Бэкап организации $org_name создан: $backup_path"
        
        # Сжатие
        cd "$(dirname "$backup_path")"
        tar -czf "${backup_path}.tar.gz" "$(basename "$backup_path")"
        rm -rf "$backup_path"
        
        echo "${backup_path}.tar.gz"
    else
        log "ERROR: Ошибка создания бэкапа организации $org_name"
        return 1
    fi
}

# Показать справку
show_help() {
    echo "Управление организациями InfluxDB"
    echo
    echo "Использование: $0 [КОМАНДА]"
    echo
    echo "Команды:"
    echo "  list                    Показать все организации"
    echo "  list-with-data          Показать организации с данными"
    echo "  backup <org_name>       Создать бэкап конкретной организации"
    echo "  backup-all              Создать бэкапы всех организаций с данными"
    echo "  help                    Показать эту справку"
}

# Основная функция
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    
    case "${1:-help}" in
        "list")
            list_organizations
            ;;
        "list-with-data")
            list_organizations_with_data
            ;;
        "backup")
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: Укажите имя организации"
                exit 1
            fi
            backup_organization "$2"
            ;;
        "backup-all")
            log "Создание бэкапов всех организаций с данными..."
            local orgs=$(list_organizations_with_data | cut -d' ' -f1)
            local count=0
            
            while IFS= read -r org; do
                if [[ -n "$org" ]]; then
                    backup_organization "$org"
                    count=$((count + 1))
                fi
            done <<< "$orgs"
            
            log "Создано бэкапов: $count"
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            echo "ERROR: Неизвестная команда: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"