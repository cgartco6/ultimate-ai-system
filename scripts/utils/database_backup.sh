#!/bin/bash

# Ultimate AI System - Database Backup Script
# Version: 2.0.0

set -e
set -o pipefail

# Configuration
BACKUP_DIR="/var/backups/ultimate-ai"
LOG_DIR="/var/log/ultimate-ai"
RETENTION_DAYS=30
S3_BUCKET="ultimate-ai-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_DIR/backup.log"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log "[SUCCESS] $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "[WARNING] $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    log "[ERROR] $1"
}

# Check requirements
check_requirements() {
    if ! command -v pg_dump &>/dev/null; then
        error "pg_dump not found. Install postgresql-client."
        exit 1
    fi
    
    if ! command -v aws &>/dev/null && [ -n "$S3_BUCKET" ]; then
        warning "AWS CLI not found. S3 backup will be skipped."
    fi
}

# Create backup directory
create_backup_dir() {
    mkdir -p "$BACKUP_DIR/$TIMESTAMP"
    mkdir -p "$LOG_DIR"
}

# Backup PostgreSQL database
backup_postgresql() {
    local backup_file="$BACKUP_DIR/$TIMESTAMP/database.sql"
    
    log "Starting PostgreSQL backup..."
    
    # Get database connection info from environment
    local DB_HOST="${DB_HOST:-localhost}"
    local DB_PORT="${DB_PORT:-5432}"
    local DB_NAME="${DB_DATABASE:-ultimate_ai}"
    local DB_USER="${DB_USERNAME:-ultimate_ai_user}"
    local DB_PASSWORD="${DB_PASSWORD}"
    
    if [ -z "$DB_PASSWORD" ]; then
        error "Database password not set in environment"
        exit 1
    fi
    
    # Set password for pg_dump
    export PGPASSWORD="$DB_PASSWORD"
    
    # Create backup
    pg_dump \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --clean \
        --if-exists \
        --create \
        --encoding=UTF8 \
        --no-password \
        --verbose \
        --file="$backup_file" 2>> "$LOG_DIR/backup.log"
    
    # Check backup size
    local size=$(du -h "$backup_file" | cut -f1)
    success "PostgreSQL backup completed: $backup_file ($size)"
    
    # Create schema-only backup
    local schema_file="$BACKUP_DIR/$TIMESTAMP/schema.sql"
    pg_dump \
        -h "$DB_HOST" \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --schema-only \
        --no-password \
        --file="$schema_file" 2>> "$LOG_DIR/backup.log"
    
    # Unset password
    unset PGPASSWORD
}

# Backup Redis
backup_redis() {
    local backup_file="$BACKUP_DIR/$TIMESTAMP/redis.rdb"
    
    log "Starting Redis backup..."
    
    # Get Redis connection info
    local REDIS_HOST="${REDIS_HOST:-localhost}"
    local REDIS_PORT="${REDIS_PORT:-6379}"
    local REDIS_PASSWORD="${REDIS_PASSWORD}"
    
    if [ -z "$REDIS_PASSWORD" ]; then
        warning "Redis password not set, attempting backup without auth"
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SAVE
    else
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" SAVE
    fi
    
    # Copy RDB file
    local rdb_path=$(redis-cli CONFIG GET dir | tail -1)
    cp "$rdb_path/dump.rdb" "$backup_file"
    
    local size=$(du -h "$backup_file" | cut -f1)
    success "Redis backup completed: $backup_file ($size)"
}

# Backup application files
backup_application() {
    local backup_dir="$BACKUP_DIR/$TIMESTAMP/app"
    
    log "Starting application backup..."
    
    mkdir -p "$backup_dir"
    
    # Backup configuration
    cp -r /opt/ultimate-ai-system/.env "$backup_dir/"
    cp -r /opt/ultimate-ai-system/backend/alembic.ini "$backup_dir/"
    
    # Backup important directories
    rsync -a --exclude='venv' --exclude='node_modules' --exclude='.git' \
        /opt/ultimate-ai-system/backend/ "$backup_dir/backend/"
    
    rsync -a --exclude='node_modules' --exclude='.next' --exclude='.git' \
        /opt/ultimate-ai-system/frontend/ "$backup_dir/frontend/"
    
    # Backup AI models
    if [ -d "/opt/ultimate-ai-system/ml_models" ]; then
        rsync -a /opt/ultimate-ai-system/ml_models/ "$backup_dir/ml_models/"
    fi
    
    # Backup SSL certificates
    if [ -d "/etc/ssl/ultimate-ai" ]; then
        cp -r /etc/ssl/ultimate-ai/ "$backup_dir/ssl/"
    fi
    
    local size=$(du -sh "$backup_dir" | cut -f1)
    success "Application backup completed: $backup_dir ($size)"
}

# Backup logs
backup_logs() {
    local backup_dir="$BACKUP_DIR/$TIMESTAMP/logs"
    
    log "Starting logs backup..."
    
    mkdir -p "$backup_dir"
    
    # Archive logs
    tar -czf "$backup_dir/app_logs.tar.gz" -C /var/log/ultimate-ai .
    
    # Archive nginx logs
    tar -czf "$backup_dir/nginx_logs.tar.gz" -C /var/log/nginx .
    
    # Archive system logs
    journalctl --since="24 hours ago" > "$backup_dir/system_journal.log"
    
    local size=$(du -sh "$backup_dir" | cut -f1)
    success "Logs backup completed: $backup_dir ($size)"
}

# Create backup manifest
create_manifest() {
    local manifest_file="$BACKUP_DIR/$TIMESTAMP/manifest.json"
    
    cat > "$manifest_file" << EOF
{
    "backup": {
        "timestamp": "$TIMESTAMP",
        "type": "full",
        "version": "2.0.0"
    },
    "components": {
        "postgresql": "$(ls -lh $BACKUP_DIR/$TIMESTAMP/database.sql 2>/dev/null | awk '{print $5}')",
        "redis": "$(ls -lh $BACKUP_DIR/$TIMESTAMP/redis.rdb 2>/dev/null | awk '{print $5}')",
        "application": "$(du -sh $BACKUP_DIR/$TIMESTAMP/app 2>/dev/null | awk '{print $1}')",
        "logs": "$(du -sh $BACKUP_DIR/$TIMESTAMP/logs 2>/dev/null | awk '{print $1}')"
    },
    "system": {
        "hostname": "$(hostname)",
        "os": "$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)",
        "kernel": "$(uname -r)"
    },
    "database": {
        "name": "${DB_DATABASE:-ultimate_ai}",
        "version": "$(psql --version | awk '{print $3}')"
    },
    "checksums": {
        "database": "$(sha256sum $BACKUP_DIR/$TIMESTAMP/database.sql 2>/dev/null | awk '{print $1}')",
        "redis": "$(sha256sum $BACKUP_DIR/$TIMESTAMP/redis.rdb 2>/dev/null | awk '{print $1}')"
    }
}
EOF
    
    success "Backup manifest created: $manifest_file"
}

# Compress backup
compress_backup() {
    log "Compressing backup..."
    
    cd "$BACKUP_DIR"
    tar -czf "ultimate-ai-backup-$TIMESTAMP.tar.gz" "$TIMESTAMP"
    
    local size=$(du -h "ultimate-ai-backup-$TIMESTAMP.tar.gz" | cut -f1)
    success "Backup compressed: ultimate-ai-backup-$TIMESTAMP.tar.gz ($size)"
    
    # Remove uncompressed directory
    rm -rf "$TIMESTAMP"
}

# Upload to S3
upload_to_s3() {
    local backup_file="$BACKUP_DIR/ultimate-ai-backup-$TIMESTAMP.tar.gz"
    
    if [ -z "$S3_BUCKET" ] || ! command -v aws &>/dev/null; then
        warning "S3 upload skipped (AWS CLI not configured)"
        return 0
    fi
    
    log "Uploading backup to S3..."
    
    # Upload to S3
    aws s3 cp "$backup_file" "s3://$S3_BUCKET/backups/" \
        --storage-class STANDARD_IA \
        --metadata "backup-type=full,timestamp=$TIMESTAMP" \
        >> "$LOG_DIR/backup.log" 2>&1
    
    if [ $? -eq 0 ]; then
        success "Backup uploaded to S3: s3://$S3_BUCKET/backups/ultimate-ai-backup-$TIMESTAMP.tar.gz"
        
        # Verify upload
        aws s3 ls "s3://$S3_BUCKET/backups/ultimate-ai-backup-$TIMESTAMP.tar.gz" >> "$LOG_DIR/backup.log" 2>&1
    else
        error "Failed to upload backup to S3"
        return 1
    fi
}

# Cleanup old backups
cleanup_backups() {
    log "Cleaning up old backups..."
    
    # Local backups
    find "$BACKUP_DIR" -name "ultimate-ai-backup-*.tar.gz" -mtime +$RETENTION_DAYS -delete
    
    # S3 backups (if configured)
    if [ -n "$S3_BUCKET" ] && command -v aws &>/dev/null; then
        aws s3 ls "s3://$S3_BUCKET/backups/" | grep "ultimate-ai-backup-" | while read -r line; do
            local s3_date=$(echo "$line" | awk '{print $1" "$2}')
            local file_date=$(date -d "$s3_date" +%s)
            local cutoff_date=$(date -d "$RETENTION_DAYS days ago" +%s)
            
            if [ "$file_date" -lt "$cutoff_date" ]; then
                local filename=$(echo "$line" | awk '{print $4}')
                aws s3 rm "s3://$S3_BUCKET/backups/$filename"
                log "Deleted old S3 backup: $filename"
            fi
        done
    fi
    
    success "Old backups cleanup completed"
}

# Send notification
send_notification() {
    local status=$1
    local message=$2
    
    # Email notification
    if [ -n "$ALERT_EMAIL" ]; then
        echo "Backup $status: $message" | mail -s "Ultimate AI Backup $status" "$ALERT_EMAIL"
    fi
    
    # Slack notification
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"Backup $status: $message\"}" \
            "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
    fi
    
    log "Notification sent: $status"
}

# Main backup function
main_backup() {
    log "=== Starting Ultimate AI System Backup ==="
    
    # Check requirements
    check_requirements
    
    # Create backup directory
    create_backup_dir
    
    # Perform backups
    backup_postgresql
    backup_redis
    backup_application
    backup_logs
    
    # Create manifest
    create_manifest
    
    # Compress backup
    compress_backup
    
    # Upload to S3
    upload_to_s3
    
    # Cleanup old backups
    cleanup_backups
    
    # Calculate total size
    local total_size=$(du -ch "$BACKUP_DIR"/ultimate-ai-backup-*.tar.gz | grep total | awk '{print $1}')
    
    # Send success notification
    local message="Backup completed successfully. Size: $total_size, Timestamp: $TIMESTAMP"
    send_notification "SUCCESS" "$message"
    
    log "=== Backup completed successfully ==="
    success "Backup completed successfully! Total size: $total_size"
}

# Error handler
handle_error() {
    local error_msg="$1"
    error "Backup failed: $error_msg"
    
    # Send failure notification
    send_notification "FAILED" "Backup failed: $error_msg"
    
    exit 1
}

# Set trap for errors
trap 'handle_error "Script terminated unexpectedly"' ERR

# Load environment variables
if [ -f /opt/ultimate-ai-system/.env ]; then
    set -a
    source /opt/ultimate-ai-system/.env
    set +a
fi

# Run main backup
main_backup

# Exit successfully
exit 0
