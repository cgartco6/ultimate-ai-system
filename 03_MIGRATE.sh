#!/bin/bash

# Ultimate AI System - Database Migration Script
# Version: 2.0.0

set -e
set -o pipefail

# Configuration
APP_DIR="/opt/ultimate-ai-system"
BACKUP_DIR="/var/backups/ultimate-ai"
LOG_DIR="/var/log/ultimate-ai"
USER_NAME="ultimate-ai"
ENVIRONMENT="production"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --environment|-e)
                ENVIRONMENT="$2"
                shift 2
                ;;
            --rollback|-r)
                ROLLBACK_VERSION="$2"
                shift 2
                ;;
            --backup-only|-b)
                BACKUP_ONLY=true
                shift
                ;;
            --force|-f)
                FORCE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Ultimate AI System - Migration Script

Usage: $0 [OPTIONS]

Options:
  -e, --environment    Set environment (production, staging, development)
  -r, --rollback       Rollback to specific version
  -b, --backup-only    Create backup without migration
  -f, --force          Force migration even with errors
  -h, --help          Show this help message

Examples:
  $0 --environment production
  $0 --rollback abc123
  $0 --backup-only
EOF
}

create_backup() {
    log "Creating database backup before migration..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/migration_$TIMESTAMP"
    
    mkdir -p "$BACKUP_PATH"
    
    # Backup PostgreSQL database
    if command -v pg_dump &>/dev/null; then
        export PGPASSWORD=$(grep DB_PASSWORD $APP_DIR/.env | cut -d= -f2)
        pg_dump -h localhost -U ultimate_ai_user -d ultimate_ai \
            --clean --if-exists --create \
            > "$BACKUP_PATH/database.sql"
        unset PGPASSWORD
        
        # Verify backup
        if [ -s "$BACKUP_PATH/database.sql" ]; then
            success "Database backup created: $BACKUP_PATH/database.sql"
        else
            error "Database backup failed or empty"
            exit 1
        fi
    else
        error "pg_dump not found. Cannot create backup."
        exit 1
    fi
    
    # Backup migration versions
    if [ -f "$APP_DIR/backend/alembic/versions" ]; then
        cp -r "$APP_DIR/backend/alembic/versions" "$BACKUP_PATH/"
    fi
    
    # Backup Alembic configuration
    if [ -f "$APP_DIR/backend/alembic.ini" ]; then
        cp "$APP_DIR/backend/alembic.ini" "$BACKUP_PATH/"
    fi
    
    # Create backup manifest
    cat > "$BACKUP_PATH/manifest.json" << EOF
{
    "migration_backup": {
        "timestamp": "$TIMESTAMP",
        "environment": "$ENVIRONMENT",
        "version": "$(cd $APP_DIR/backend && $APP_DIR/venv/bin/alembic current 2>/dev/null || echo 'unknown')",
        "files": {
            "database": "$BACKUP_PATH/database.sql",
            "versions": "$BACKUP_PATH/versions",
            "alembic_ini": "$BACKUP_PATH/alembic.ini"
        }
    }
}
EOF
    
    success "Migration backup created successfully"
}

check_migration_status() {
    log "Checking current migration status..."
    
    cd "$APP_DIR/backend"
    
    # Get current revision
    CURRENT_REV=$($APP_DIR/venv/bin/alembic current 2>/dev/null | awk '{print $1}' || echo "None")
    
    # Get available revisions
    AVAILABLE_REVS=$($APP_DIR/venv/bin/alembic history 2>/dev/null | grep -E "^[a-f0-9]+" | wc -l)
    
    log "Current revision: $CURRENT_REV"
    log "Available revisions: $AVAILABLE_REVS"
    
    if [ "$CURRENT_REV" = "None" ] && [ $AVAILABLE_REVS -gt 0 ]; then
        warning "Database appears to be uninitialized"
        if [ "$FORCE" != "true" ]; then
            read -p "Continue with initial migration? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                error "Migration aborted by user"
                exit 1
            fi
        fi
    fi
}

run_migrations() {
    log "Running database migrations..."
    
    cd "$APP_DIR/backend"
    
    # Set environment
    export ENV="$ENVIRONMENT"
    
    # Run migrations
    if [ "$FORCE" = "true" ]; then
        log "Running migrations with --force flag..."
        $APP_DIR/venv/bin/alembic upgrade head --sql > "$LOG_DIR/migration_$(date +%Y%m%d_%H%M%S).sql" 2>&1
        $APP_DIR/venv/bin/alembic upgrade head
    else
        # Dry run first
        log "Performing dry run..."
        $APP_DIR/venv/bin/alembic upgrade head --sql > "$LOG_DIR/migration_dry_run_$(date +%Y%m%d_%H%M%S).sql" 2>&1
        
        # Check for errors in dry run
        if grep -q "ERROR\|FAILED\|Traceback" "$LOG_DIR/migration_dry_run_$(date +%Y%m%d_%H%M%S).sql"; then
            error "Dry run failed. Check logs: $LOG_DIR/migration_dry_run_$(date +%Y%m%d_%H%M%S).sql"
            if [ "$FORCE" != "true" ]; then
                exit 1
            fi
        fi
        
        # Run actual migration
        log "Applying migrations..."
        $APP_DIR/venv/bin/alembic upgrade head
    fi
    
    # Verify migration
    NEW_REV=$($APP_DIR/venv/bin/alembic current 2>/dev/null | awk '{print $1}')
    log "New revision: $NEW_REV"
    
    if [ "$NEW_REV" != "None" ]; then
        success "Migrations completed successfully"
        return 0
    else
        error "Migration may have failed"
        return 1
    fi
}

run_data_migrations() {
    log "Running data migrations..."
    
    cd "$APP_DIR/backend"
    
    # Check for data migration scripts
    if [ -d "data_migrations" ]; then
        for script in data_migrations/*.py; do
            if [ -f "$script" ]; then
                log "Running data migration: $script"
                $APP_DIR/venv/bin/python "$script"
                
                if [ $? -eq 0 ]; then
                    success "Data migration completed: $script"
                else
                    error "Data migration failed: $script"
                    if [ "$FORCE" != "true" ]; then
                        return 1
                    fi
                fi
            fi
        done
    fi
    
    # Run seed data if exists
    if [ -f "utils/seed_data.py" ]; then
        log "Seeding database..."
        $APP_DIR/venv/bin/python -m utils.seed_data
    fi
    
    success "Data migrations completed"
}

rollback_migration() {
    local target_version="$1"
    
    log "Rolling back to version: $target_version"
    
    cd "$APP_DIR/backend"
    
    # Create rollback backup
    create_backup
    
    # Check if version exists
    if ! $APP_DIR/venv/bin/alembic history | grep -q "$target_version"; then
        error "Target version $target_version not found in history"
        exit 1
    fi
    
    # Rollback
    if [ "$target_version" = "base" ] || [ "$target_version" = "-1" ]; then
        $APP_DIR/venv/bin/alembic downgrade base
    else
        $APP_DIR/venv/bin/alembic downgrade "$target_version"
    fi
    
    # Verify rollback
    CURRENT_REV=$($APP_DIR/venv/bin/alembic current 2>/dev/null | awk '{print $1}')
    log "Current revision after rollback: $CURRENT_REV"
    
    success "Rollback completed to version: $target_version"
}

validate_database() {
    log "Validating database state..."
    
    cd "$APP_DIR/backend"
    
    # Check if all tables exist
    if [ -f "utils/validate_db.py" ]; then
        $APP_DIR/venv/bin/python -m utils.validate_db
        if [ $? -eq 0 ]; then
            success "Database validation passed"
        else
            error "Database validation failed"
            return 1
        fi
    fi
    
    # Check data consistency
    log "Checking data consistency..."
    $APP_DIR/venv/bin/python -c "
import sys
sys.path.insert(0, '.')
from app.core.database import SessionLocal
from app.models.user import User

db = SessionLocal()
try:
    # Check if admin user exists
    admin = db.query(User).filter(User.email == 'admin@ultimate-ai.com').first()
    if admin:
        print('✓ Admin user exists')
    else:
        print('⚠ Admin user not found')
    
    # Check table counts
    from app.models.trading import Trade
    from app.models.workout import WorkoutSession
    
    trade_count = db.query(Trade).count()
    print(f'✓ Trades in database: {trade_count}')
    
    workout_count = db.query(WorkoutSession).count()
    print(f'✓ Workout sessions: {workout_count}')
    
    db.close()
except Exception as e:
    print(f'✗ Validation error: {e}')
    sys.exit(1)
"
    
    success "Database validation completed"
}

update_schema_cache() {
    log "Updating schema cache..."
    
    # Update PostgreSQL statistics
    if command -v psql &>/dev/null; then
        export PGPASSWORD=$(grep DB_PASSWORD $APP_DIR/.env | cut -d= -f2)
        psql -h localhost -U ultimate_ai_user -d ultimate_ai -c "ANALYZE;"
        unset PGPASSWORD
        success "Database statistics updated"
    fi
    
    # Clear SQLAlchemy cache
    if [ -d "$APP_DIR/backend/__pycache__" ]; then
        find "$APP_DIR/backend" -name "*.pyc" -delete
        find "$APP_DIR/backend" -name "__pycache__" -type d -exec rm -rf {} +
    fi
    
    success "Schema cache updated"
}

notify_migration() {
    local status="$1"
    local message="$2"
    
    log "Sending migration notification..."
    
    # Send to Slack if configured
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{
                \"text\": \"*Database Migration $status*\\nEnvironment: $ENVIRONMENT\\n$message\\nTime: $(date)\"
            }" \
            "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
    fi
    
    # Send email if configured
    if [ -n "$ALERT_EMAIL" ]; then
        echo "Migration $status: $message" | mail -s "Ultimate AI Migration $status" "$ALERT_EMAIL"
    fi
    
    success "Notification sent"
}

main() {
    check_root
    parse_args "$@"
    
    log "Starting Ultimate AI System Migration"
    log "Environment: $ENVIRONMENT"
    
    # Check if in backup-only mode
    if [ "$BACKUP_ONLY" = "true" ]; then
        create_backup
        exit 0
    fi
    
    # Check if rollback requested
    if [ -n "$ROLLBACK_VERSION" ]; then
        rollback_migration "$ROLLBACK_VERSION"
        exit 0
    fi
    
    # Normal migration flow
    create_backup
    check_migration_status
    run_migrations
    run_data_migrations
    validate_database
    update_schema_cache
    
    # Restart application services
    log "Restarting application services..."
    systemctl restart ultimate-ai-backend
    systemctl restart ultimate-ai-celery
    
    success "Migration completed successfully!"
    
    # Send success notification
    NEW_REV=$(cd $APP_DIR/backend && $APP_DIR/venv/bin/alembic current 2>/dev/null | awk '{print $1}')
    notify_migration "SUCCESS" "Database migrated to revision: $NEW_REV"
    
    cat << EOF

===============================================================================
✅ MIGRATION COMPLETE
===============================================================================

Migration Details:
- Environment: $ENVIRONMENT
- New Revision: $NEW_REV
- Backup Created: $BACKUP_PATH
- Logs: $LOG_DIR/migration_*.log

Next Steps:
1. Verify application functionality
2. Check monitoring dashboards
3. Test critical API endpoints
4. Review migration logs for warnings

To rollback if needed:
  $0 --rollback $(cd $APP_DIR/backend && $APP_DIR/venv/bin/alembic current 2>/dev/null | awk '{print $1}')
  
===============================================================================
EOF
}

# Error handling
trap 'error "Migration failed at line $LINENO"; exit 1' ERR

# Load environment
if [ -f "$APP_DIR/.env" ]; then
    set -a
    source "$APP_DIR/.env"
    set +a
fi

# Run main function
main "$@"
