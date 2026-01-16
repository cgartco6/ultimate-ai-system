#!/bin/bash

# Ultimate AI System - Backup & Restore Script
# Version: 2.0.0

set -e
set -o pipefail

# Configuration
APP_DIR="/opt/ultimate-ai-system"
BACKUP_DIR="/var/backups/ultimate-ai"
LOG_DIR="/var/log/ultimate-ai"
RETENTION_DAYS=30
S3_BUCKET="${S3_BACKUP_BUCKET:-ultimate-ai-backups}"
ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_DIR/backup.log"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_DIR/backup.log"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_DIR/backup.log"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_DIR/backup.log"; }

show_help() {
    cat << EOF
Ultimate AI System - Backup & Restore

Usage: $0 [COMMAND] [OPTIONS]

Commands:
  backup           Create a new backup
  restore          Restore from backup
  list             List available backups
  verify           Verify backup integrity
  cleanup          Cleanup old backups
  schedule         Configure backup schedule

Options:
  --type           Backup type (full|partial|database|logs)
  --backup-id      Specific backup ID to restore
  --date           Restore from specific date (YYYY-MM-DD)
  --encrypt        Encrypt backup with GPG
  --compress       Compression level (0-9)
  --verify-only    Only verify, don't backup
  --force          Force operation without confirmation

Examples:
  $0 backup --type full
  $0 restore --backup-id 20240101_120000
  $0 list
  $0 verify --backup-id latest
EOF
}

check_requirements() {
    log "Checking requirements..."
    
    local missing=()
    
    # Check for required tools
    command -v pg_dump >/dev/null 2>&1 || missing+=("postgresql-client")
    command -v redis-cli >/dev/null 2>&1 || missing+=("redis-tools")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
    command -v gzip >/dev/null 2>&1 || missing+=("gzip")
    
    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing required packages: ${missing[*]}"
        return 1
    fi
    
    # Check AWS CLI if S3 enabled
    if [ -n "$S3_BUCKET" ]; then
        command -v aws >/dev/null 2>&1 || warning "AWS CLI not found, S3 backup disabled"
    fi
    
    # Check GPG if encryption enabled
    if [ -n "$ENCRYPTION_KEY" ]; then
        command -v gpg >/dev/null 2>&1 || warning "GPG not found, encryption disabled"
    fi
    
    success "Requirements check passed"
}

create_backup() {
    local backup_type="${1:-full}"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_id="${backup_type}_${timestamp}"
    local backup_path="$BACKUP_DIR/$backup_id"
    
    log "Creating $backup_type backup: $backup_id"
    
    # Create backup directory
    mkdir -p "$backup_path"
    mkdir -p "$backup_path/{database,redis,app,logs,config}"
    
    # Export environment
    export_env_vars
    
    case $backup_type in
        full)
            backup_database
            backup_redis
            backup_application
            backup_logs
            backup_configs
            ;;
        database)
            backup_database
            ;;
        redis)
            backup_redis
            ;;
        app)
            backup_application
            ;;
        logs)
            backup_logs
            ;;
        config)
            backup_configs
            ;;
        *)
            error "Unknown backup type: $backup_type"
            return 1
            ;;
    esac
    
    # Create manifest
    create_manifest "$backup_path" "$backup_type" "$backup_id"
    
    # Compress backup
    compress_backup "$backup_path" "$backup_id"
    
    # Encrypt if key provided
    if [ -n "$ENCRYPTION_KEY" ]; then
        encrypt_backup "$BACKUP_DIR/${backup_id}.tar.gz" "$backup_id"
    fi
    
    # Upload to S3
    if [ -n "$S3_BUCKET" ] && command -v aws >/dev/null 2>&1; then
        upload_to_s3 "$backup_id"
    fi
    
    # Cleanup temp files
    rm -rf "$backup_path"
    
    success "Backup completed: $backup_id"
    echo "Backup ID: $backup_id"
    echo "Location: $BACKUP_DIR/${backup_id}.tar.gz"
    
    return 0
}

export_env_vars() {
    log "Exporting environment variables..."
    
    # Load environment
    if [ -f "$APP_DIR/.env" ]; then
        set -a
        source "$APP_DIR/.env"
        set +a
    fi
    
    # Set default DB credentials
    DB_HOST="${DB_HOST:-localhost}"
    DB_PORT="${DB_PORT:-5432}"
    DB_NAME="${DB_DATABASE:-ultimate_ai}"
    DB_USER="${DB_USERNAME:-ultimate_ai_user}"
    DB_PASSWORD="${DB_PASSWORD}"
    
    # Set Redis credentials
    REDIS_HOST="${REDIS_HOST:-localhost}"
    REDIS_PORT="${REDIS_PORT:-6379}"
    REDIS_PASSWORD="${REDIS_PASSWORD}"
    
    export PGPASSWORD="$DB_PASSWORD"
}

backup_database() {
    log "Backing up PostgreSQL database..."
    
    local db_backup="$backup_path/database"
    
    # Full database dump
    pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        --clean --if-exists --create --verbose \
        > "$db_backup/full.sql" 2>> "$LOG_DIR/backup.log"
    
    # Schema only
    pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        --schema-only \
        > "$db_backup/schema.sql" 2>> "$LOG_DIR/backup.log"
    
    # Data only
    pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        --data-only \
        > "$db_backup/data.sql" 2>> "$LOG_DIR/backup.log"
    
    # Backup specific tables
    backup_critical_tables "$db_backup"
    
    # Backup roles and permissions
    pg_dumpall -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
        --roles-only \
        > "$db_backup/roles.sql" 2>> "$LOG_DIR/backup.log"
    
    # Verify backup
    if [ -s "$db_backup/full.sql" ]; then
        local size=$(du -h "$db_backup/full.sql" | cut -f1)
        success "Database backup completed ($size)"
    else
        error "Database backup failed"
        return 1
    fi
}

backup_critical_tables() {
    local backup_dir="$1"
    
    log "Backing up critical tables..."
    
    # List of critical tables
    local tables=(
        "users"
        "trades"
        "positions"
        "workout_sessions"
        "workout_exercises"
        "injuries"
        "ai_agents"
        "trading_strategies"
        "system_settings"
    )
    
    for table in "${tables[@]}"; do
        log "Backing up table: $table"
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
            -c "\copy $table to '$backup_dir/${table}.csv' csv header" \
            >> "$LOG_DIR/backup.log" 2>&1
    done
    
    success "Critical tables backed up"
}

backup_redis() {
    log "Backing up Redis database..."
    
    local redis_backup="$backup_path/redis"
    
    # Save Redis data
    if [ -n "$REDIS_PASSWORD" ]; then
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" SAVE
    else
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SAVE
    fi
    
    # Find RDB file
    local rdb_path=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" CONFIG GET dir | tail -1)
    local rdb_file="$rdb_path/dump.rdb"
    
    if [ -f "$rdb_file" ]; then
        cp "$rdb_file" "$redis_backup/dump.rdb"
        local size=$(du -h "$redis_backup/dump.rdb" | cut -f1)
        success "Redis backup completed ($size)"
    else
        error "Redis RDB file not found"
        return 1
    fi
    
    # Backup Redis configuration
    if [ -n "$REDIS_PASSWORD" ]; then
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" CONFIG GET "*" \
            > "$redis_backup/redis.conf"
    else
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" CONFIG GET "*" \
            > "$redis_backup/redis.conf"
    fi
}

backup_application() {
    log "Backing up application files..."
    
    local app_backup="$backup_path/app"
    
    # Backup source code
    rsync -a --exclude='venv' --exclude='node_modules' --exclude='.git' \
        --exclude='__pycache__' --exclude='*.pyc' \
        "$APP_DIR/" "$app_backup/"
    
    # Backup virtual environment packages list
    if [ -f "$APP_DIR/venv/bin/pip" ]; then
        "$APP_DIR/venv/bin/pip" freeze > "$app_backup/requirements.txt"
    fi
    
    # Backup Node.js packages
    if [ -f "$APP_DIR/frontend/package.json" ]; then
        cp "$APP_DIR/frontend/package.json" "$app_backup/frontend_package.json"
        cp "$APP_DIR/frontend/package-lock.json" "$app_backup/frontend_package_lock.json" 2>/dev/null || true
    fi
    
    local size=$(du -sh "$app_backup" | cut -f1)
    success "Application backup completed ($size)"
}

backup_logs() {
    log "Backing up system logs..."
    
    local logs_backup="$backup_path/logs"
    
    # Application logs
    if [ -d "$LOG_DIR" ]; then
        tar -czf "$logs_backup/app_logs.tar.gz" -C "$LOG_DIR" .
    fi
    
    # System logs
    journalctl --since="7 days ago" --output=short-precise \
        > "$logs_backup/system_journal.log"
    
    # Nginx logs
    if [ -d "/var/log/nginx" ]; then
        tar -czf "$logs_backup/nginx_logs.tar.gz" -C "/var/log/nginx" .
    fi
    
    # Docker logs
    if command -v docker >/dev/null 2>&1; then
        docker ps -aq | xargs docker inspect --format='{{.Name}} {{.LogPath}}' \
            > "$logs_backup/docker_containers.txt"
    fi
    
    local size=$(du -sh "$logs_backup" | cut -f1)
    success "Logs backup completed ($size)"
}

backup_configs() {
    log "Backing up configuration files..."
    
    local config_backup="$backup_path/config"
    
    # System configurations
    cp -r /etc/nginx "$config_backup/nginx" 2>/dev/null || true
    cp -r /etc/postgresql "$config_backup/postgresql" 2>/dev/null || true
    cp -r /etc/redis "$config_backup/redis" 2>/dev/null || true
    
    # Application configurations
    cp "$APP_DIR/.env" "$config_backup/app.env"
    cp "$APP_DIR/docker-compose.yml" "$config_backup/"
    cp "$APP_DIR/docker-compose.prod.yml" "$config_backup/" 2>/dev/null || true
    
    # SSL certificates
    if [ -d "/etc/ssl/ultimate-ai" ]; then
        cp -r "/etc/ssl/ultimate-ai" "$config_backup/ssl"
    fi
    
    # Systemd services
    cp /etc/systemd/system/ultimate-ai-*.service "$config_backup/" 2>/dev/null || true
    
    local size=$(du -sh "$config_backup" | cut -f1)
    success "Configurations backup completed ($size)"
}

create_manifest() {
    local backup_path="$1"
    local backup_type="$2"
    local backup_id="$3"
    
    log "Creating backup manifest..."
    
    cat > "$backup_path/manifest.json" << EOF
{
    "backup": {
        "id": "$backup_id",
        "type": "$backup_type",
        "timestamp": "$(date +%Y-%m-%dT%H:%M:%SZ)",
        "system": {
            "hostname": "$(hostname)",
            "os": "$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)",
            "kernel": "$(uname -r)"
        },
        "application": {
            "version": "$(cat $APP_DIR/backend/app/__version__.py 2>/dev/null | grep __version__ | cut -d'=' -f2 | tr -d \"' \" || echo 'unknown')",
            "database_version": "$(psql --version | awk '{print \$3}')",
            "redis_version": "$(redis-server --version | awk '{print \$3}' | cut -d'=' -f2)"
        },
        "files": {
            "database": "$(du -sh $backup_path/database 2>/dev/null | cut -f1 || echo '0')",
            "redis": "$(du -sh $backup_path/redis 2>/dev/null | cut -f1 || echo '0')",
            "application": "$(du -sh $backup_path/app 2>/dev/null | cut -f1 || echo '0')",
            "logs": "$(du -sh $backup_path/logs 2>/dev/null | cut -f1 || echo '0')",
            "config": "$(du -sh $backup_path/config 2>/dev/null | cut -f1 || echo '0')"
        },
        "checksums": {
            "database": "$(find $backup_path/database -type f -exec sha256sum {} \; 2>/dev/null | sha256sum | cut -d' ' -f1 || echo '')",
            "redis": "$(sha256sum $backup_path/redis/dump.rdb 2>/dev/null | cut -d' ' -f1 || echo '')"
        }
    }
}
EOF
    
    success "Manifest created: $backup_path/manifest.json"
}

compress_backup() {
    local backup_path="$1"
    local backup_id="$2"
    local compression_level="${3:-6}"
    
    log "Compressing backup (level: $compression_level)..."
    
    cd "$BACKUP_DIR"
    
    # Create tar archive
    tar -czf "${backup_id}.tar.gz" \
        --checkpoint=1000 \
        --checkpoint-action=dot \
        --level="$compression_level" \
        "$backup_id" 2>> "$LOG_DIR/backup.log"
    
    local size=$(du -h "${backup_id}.tar.gz" | cut -f1)
    success "Backup compressed: ${backup_id}.tar.gz ($size)"
}

encrypt_backup() {
    local backup_file="$1"
    local backup_id="$2"
    
    if [ -z "$ENCRYPTION_KEY" ]; then
        return 0
    fi
    
    log "Encrypting backup with GPG..."
    
    # Create encrypted version
    gpg --batch --yes --passphrase "$ENCRYPTION_KEY" \
        --cipher-algo AES256 \
        --symmetric \
        --output "${backup_file}.gpg" \
        "$backup_file" 2>> "$LOG_DIR/backup.log"
    
    if [ $? -eq 0 ]; then
        # Remove unencrypted version
        rm "$backup_file"
        success "Backup encrypted: ${backup_file}.gpg"
    else
        warning "Encryption failed, keeping unencrypted backup"
    fi
}

upload_to_s3() {
    local backup_id="$1"
    local backup_file="$BACKUP_DIR/${backup_id}.tar.gz"
    
    if [ ! -f "$backup_file" ]; then
        backup_file="$BACKUP_DIR/${backup_id}.tar.gz.gpg"
    fi
    
    if [ ! -f "$backup_file" ]; then
        error "Backup file not found: $backup_file"
        return 1
    fi
    
    log "Uploading to S3: $S3_BUCKET"
    
    # Upload with metadata
    aws s3 cp "$backup_file" "s3://$S3_BUCKET/backups/" \
        --storage-class STANDARD_IA \
        --metadata "backup-id=$backup_id,type=ultimate-ai,encrypted=$([ -n "$ENCRYPTION_KEY" ] && echo true || echo false)" \
        --no-progress
    
    if [ $? -eq 0 ]; then
        success "Backup uploaded to S3: s3://$S3_BUCKET/backups/$(basename $backup_file)"
        
        # Verify upload
        aws s3 ls "s3://$S3_BUCKET/backups/$(basename $backup_file)" \
            || warning "S3 upload verification failed"
    else
        error "S3 upload failed"
        return 1
    fi
}

restore_backup() {
    local backup_id="$1"
    local restore_path="$2"
    
    log "Restoring backup: $backup_id"
    
    # Find backup file
    local backup_file=""
    if [ -f "$BACKUP_DIR/${backup_id}.tar.gz.gpg" ]; then
        backup_file="$BACKUP_DIR/${backup_id}.tar.gz.gpg"
        decrypt_backup "$backup_file" "${backup_file%.gpg}"
        backup_file="${backup_file%.gpg}"
    elif [ -f "$BACKUP_DIR/${backup_id}.tar.gz" ]; then
        backup_file="$BACKUP_DIR/${backup_id}.tar.gz"
    elif [ -n "$S3_BUCKET" ] && command -v aws >/dev/null 2>&1; then
        # Try to download from S3
        log "Downloading backup from S3..."
        aws s3 cp "s3://$S3_BUCKET/backups/${backup_id}.tar.gz" "$BACKUP_DIR/" \
            || aws s3 cp "s3://$S3_BUCKET/backups/${backup_id}.tar.gz.gpg" "$BACKUP_DIR/"
        
        if [ -f "$BACKUP_DIR/${backup_id}.tar.gz.gpg" ]; then
            decrypt_backup "$BACKUP_DIR/${backup_id}.tar.gz.gpg" "$BACKUP_DIR/${backup_id}.tar.gz"
            backup_file="$BACKUP_DIR/${backup_id}.tar.gz"
        elif [ -f "$BACKUP_DIR/${backup_id}.tar.gz" ]; then
            backup_file="$BACKUP_DIR/${backup_id}.tar.gz"
        fi
    fi
    
    if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
        error "Backup not found: $backup_id"
        return 1
    fi
    
    # Extract backup
    local extract_dir="$BACKUP_DIR/restore_${backup_id}_$(date +%s)"
    mkdir -p "$extract_dir"
    
    log "Extracting backup..."
    tar -xzf "$backup_file" -C "$extract_dir"
    
    # Read manifest
    local manifest="$extract_dir/$backup_id/manifest.json"
    if [ ! -f "$manifest" ]; then
        error "Manifest not found in backup"
        return 1
    fi
    
    # Parse backup type
    local backup_type=$(jq -r '.backup.type' "$manifest")
    
    # Stop services
    log "Stopping services..."
    systemctl stop ultimate-ai-backend
    systemctl stop ultimate-ai-celery
    systemctl stop nginx 2>/dev/null || true
    
    # Perform restore based on type
    case $backup_type in
        full|database)
            restore_database "$extract_dir/$backup_id"
            ;;
    esac
    
    case $backup_type in
        full|redis)
            restore_redis "$extract_dir/$backup_id"
            ;;
    esac
    
    case $backup_type in
        full|app)
            restore_application "$extract_dir/$backup_id"
            ;;
    esac
    
    case $backup_type in
        full|config)
            restore_configs "$extract_dir/$backup_id"
            ;;
    esac
    
    # Start services
    log "Starting services..."
    systemctl start nginx 2>/dev/null || true
    systemctl start ultimate-ai-backend
    systemctl start ultimate-ai-celery
    
    # Cleanup
    rm -rf "$extract_dir"
    
    success "Restore completed: $backup_id"
}

restore_database() {
    local backup_dir="$1/database"
    
    log "Restoring database..."
    
    # Drop and recreate database
    psql -h localhost -U postgres -c "DROP DATABASE IF EXISTS ultimate_ai;"
    psql -h localhost -U postgres -c "CREATE DATABASE ultimate_ai;"
    psql -h localhost -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE ultimate_ai TO ultimate_ai_user;"
    
    # Restore from backup
    if [ -f "$backup_dir/full.sql" ]; then
        psql -h localhost -U ultimate_ai_user -d ultimate_ai -f "$backup_dir/full.sql"
    else
        # Restore schema then data
        if [ -f "$backup_dir/schema.sql" ]; then
            psql -h localhost -U ultimate_ai_user -d ultimate_ai -f "$backup_dir/schema.sql"
        fi
        if [ -f "$backup_dir/data.sql" ]; then
            psql -h localhost -U ultimate_ai_user -d ultimate_ai -f "$backup_dir/data.sql"
        fi
    fi
    
    success "Database restored"
}

restore_redis() {
    local backup_dir="$1/redis"
    
    log "Restoring Redis..."
    
    # Stop Redis
    systemctl stop redis
    
    # Restore RDB file
    if [ -f "$backup_dir/dump.rdb" ]; then
        local rdb_path=$(redis-cli CONFIG GET dir | tail -1)
        cp "$backup_dir/dump.rdb" "$rdb_path/"
        chown redis:redis "$rdb_path/dump.rdb"
    fi
    
    # Start Redis
    systemctl start redis
    
    success "Redis restored"
}

restore_application() {
    local backup_dir="$1/app"
    
    log "Restoring application..."
    
    # Backup current app
    mv "$APP_DIR" "$APP_DIR.backup.$(date +%s)"
    
    # Restore from backup
    cp -r "$backup_dir" "$APP_DIR"
    chown -R ultimate-ai:ultimate-ai "$APP_DIR"
    
    # Restore virtual environment if needed
    if [ -f "$APP_DIR/requirements.txt" ] && [ ! -d "$APP_DIR/venv" ]; then
        log "Restoring Python virtual environment..."
        python3 -m venv "$APP_DIR/venv"
        "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"
    fi
    
    success "Application restored"
}

list_backups() {
    log "Available backups:"
    
    echo -e "\n${BLUE}Local Backups:${NC}"
    find "$BACKUP_DIR" -name "*.tar.gz" -o -name "*.tar.gz.gpg" | sort | while read -r backup; do
        local size=$(du -h "$backup" | cut -f1)
        local date=$(stat -c %y "$backup" | cut -d' ' -f1)
        local time=$(stat -c %y "$backup" | cut -d' ' -f2 | cut -d'.' -f1)
        local encrypted=""
        [[ "$backup" == *.gpg ]] && encrypted="[ENCRYPTED]"
        echo "  $(basename "$backup") - $size - $date $time $encrypted"
    done
    
    if [ -n "$S3_BUCKET" ] && command -v aws >/dev/null 2>&1; then
        echo -e "\n${BLUE}S3 Backups:${NC}"
        aws s3 ls "s3://$S3_BUCKET/backups/" | awk '{print "  "$4" - "$2" "$1}'
    fi
}

verify_backup() {
    local backup_id="$1"
    
    log "Verifying backup: $backup_id"
    
    # Find and extract backup
    local backup_file=""
    if [ -f "$BACKUP_DIR/${backup_id}.tar.gz" ]; then
        backup_file="$BACKUP_DIR/${backup_id}.tar.gz"
    elif [ -f "$BACKUP_DIR/${backup_id}.tar.gz.gpg" ]; then
        backup_file="$BACKUP_DIR/${backup_id}.tar.gz.gpg"
    fi
    
    if [ -z "$backup_file" ]; then
        error "Backup not found: $backup_id"
        return 1
    fi
    
    # Test archive integrity
    if [[ "$backup_file" == *.gpg ]]; then
        log "Testing encrypted archive..."
        gpg --batch --passphrase "$ENCRYPTION_KEY" --decrypt "$backup_file" | tar -tzf - >/dev/null
    else
        log "Testing archive integrity..."
        tar -tzf "$backup_file" >/dev/null
    fi
    
    if [ $? -eq 0 ]; then
        success "Backup integrity verified: $backup_id"
        return 0
    else
        error "Backup verification failed: $backup_id"
        return 1
    fi
}

cleanup_backups() {
    log "Cleaning up old backups..."
    
    # Local backups
    find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete
    find "$BACKUP_DIR" -name "*.tar.gz.gpg" -mtime +$RETENTION_DAYS -delete
    
    # S3 backups
    if [ -n "$S3_BUCKET" ] && command -v aws >/dev/null 2>&1; then
        aws s3 ls "s3://$S3_BUCKET/backups/" | while read -r line; do
            local date=$(echo "$line" | awk '{print $1}')
            local file=$(echo "$line" | awk '{print $4}')
            local file_date=$(date -d "$date" +%s)
            local cutoff_date=$(date -d "$RETENTION_DAYS days ago" +%s)
            
            if [ "$file_date" -lt "$cutoff_date" ]; then
                aws s3 rm "s3://$S3_BUCKET/backups/$file"
                log "Deleted old S3 backup: $file"
            fi
        done
    fi
    
    success "Cleanup completed (retention: $RETENTION_DAYS days)"
}

schedule_backups() {
    log "Configuring backup schedule..."
    
    # Create cron job
    local cron_schedule="0 2 * * *"  # Daily at 2 AM
    
    cat > /etc/cron.d/ultimate-ai-backup << EOF
# Ultimate AI System - Automated Backups
$cron_schedule root $0 backup --type partial >> $LOG_DIR/backup_cron.log 2>&1

# Weekly full backup on Sunday at 3 AM
0 3 * * 0 root $0 backup --type full >> $LOG_DIR/backup_cron.log 2>&1

# Monthly cleanup on 1st at 4 AM
0 4 1 * * root $0 cleanup >> $LOG_DIR/backup_cron.log 2>&1
EOF
    
    chmod 644 /etc/cron.d/ultimate-ai-backup
    
    success "Backup schedule configured"
    echo "Daily partial backups: 2 AM"
    echo "Weekly full backups: Sunday 3 AM"
    echo "Monthly cleanup: 1st of month 4 AM"
}

main() {
    local command="$1"
    shift
    
    # Create directories
    mkdir -p "$BACKUP_DIR" "$LOG_DIR"
    
    # Load environment
    if [ -f "$APP_DIR/.env" ]; then
        set -a
        source "$APP_DIR/.env"
        set +a
    fi
    
    case $command in
        backup)
            local backup_type="full"
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --type)
                        backup_type="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            check_requirements
            create_backup "$backup_type"
            ;;
        restore)
            local backup_id=""
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --backup-id)
                        backup_id="$2"
                        shift 2
                        ;;
                    --date)
                        local date="$2"
                        backup_id=$(find "$BACKUP_DIR" -name "*${date}*.tar.gz*" | head -1 | xargs basename | cut -d. -f1)
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            
            if [ -z "$backup_id" ]; then
                list_backups
                read -p "Enter backup ID to restore: " backup_id
            fi
            
            if [ -n "$backup_id" ]; then
                check_requirements
                restore_backup "$backup_id"
            else
                error "No backup ID specified"
                exit 1
            fi
            ;;
        list)
            list_backups
            ;;
        verify)
            local backup_id=""
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --backup-id)
                        backup_id="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            
            if [ -z "$backup_id" ]; then
                backup_id="latest"
            fi
            
            if [ "$backup_id" = "latest" ]; then
                backup_id=$(find "$BACKUP_DIR" -name "*.tar.gz*" | sort | tail -1 | xargs basename | cut -d. -f1)
            fi
            
            verify_backup "$backup_id"
            ;;
        cleanup)
            cleanup_backups
            ;;
        schedule)
            schedule_backups
            ;;
        help|-h|--help|"")
            show_help
            ;;
        *)
            error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
