#!/bin/bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

SERVICE_NAME="mysql-backup"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"

case "$1" in
    build)
        echo "Building $SERVICE_NAME..."
        docker-compose -f $COMPOSE_FILE --env-file $ENV_FILE build
        ;;
    start)
        echo "Starting $SERVICE_NAME..."
        docker-compose -f $COMPOSE_FILE --env-file $ENV_FILE up -d
        echo "$SERVICE_NAME started."
        ;;
    stop)
        echo "Stopping $SERVICE_NAME..."
        docker-compose -f $COMPOSE_FILE down
        echo "$SERVICE_NAME stopped."
        ;;
    restart)
        echo "Restarting $SERVICE_NAME..."
        docker-compose -f $COMPOSE_FILE --env-file $ENV_FILE restart
        echo "$SERVICE_NAME restarted."
        ;;
    logs)
        docker-compose -f $COMPOSE_FILE logs -f
        ;;
    status)
        docker-compose -f $COMPOSE_FILE ps
        ;;
    backup)
        echo "Running manual backup..."
        docker exec m2_mysql_backup /app/scripts/backup.sh
        ;;
    *)
        echo "Usage: $0 {build|start|stop|restart|logs|status|backup}"
        exit 1
        ;;
esac

exit 0
