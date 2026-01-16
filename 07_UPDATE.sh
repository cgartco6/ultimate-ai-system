#!/bin/bash

# Ultimate AI System - Update Script
# Version: 2.0.0

set -e
set -o pipefail

# Configuration
APP_DIR="/opt/ultimate-ai-system"
BACKUP_DIR="/var/backups/ultimate-ai"
LOG_DIR="/var/log/ultimate-ai"
UPDATE_CACHE_DIR="/var/cache/ultimate-ai/updates"
USER_NAME="ultimate-ai"
BRANCH="main"
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
            --branch|-b)
                BRANCH="$2"
                shift 2
                ;;
            --type|-t)
                UPDATE_TYPE="$2"
                shift 2
                ;;
            --dry-run|-d)
                DRY_RUN=true
                shift
                ;;
            --force|-f)
                FORCE=true
                shift
                ;;
            --rollback|-r)
                ROLLBACK=true
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
Ultimate AI System - Update Script

Usage: $0 [OPTIONS]

Options:
  -e, --environment    Environment (production, staging, development)
  -b, --branch         Git branch to update from (default: main)
  -t, --type           Update type (system, app, security, all)
  -d, --dry-run        Show what would be updated without making changes
  -f, --force          Force update even with warnings
  -r, --rollback       Rollback last update
  -h, --help          Show this help message

Examples:
  $0 --environment production --type all
  $0 --dry-run --type security
  $0 --rollback
EOF
}

create_update_backup() {
    log "Creating update backup..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/update_$TIMESTAMP"
    
    mkdir -p "$BACKUP_PATH"
    
    # Backup application state
    cp -r "$APP_DIR" "$BACKUP_PATH/app"
    
    # Backup database schema
    if command -v pg_dump &>/dev/null; then
        export PGPASSWORD=$(grep DB_PASSWORD $APP_DIR/.env | cut -d= -f2)
        pg_dump -h localhost -U ultimate_ai_user -d ultimate_ai --schema-only \
            > "$BACKUP_PATH/database_schema.sql"
        unset PGPASSWORD
    fi
    
    # Backup configuration files
    cp -r /etc/nginx/sites-available/ultimate-ai "$BACKUP_PATH/" 2>/dev/null || true
    cp /etc/systemd/system/ultimate-ai-*.service "$BACKUP_PATH/" 2>/dev/null || true
    
    # Create update manifest
    cat > "$BACKUP_PATH/update_manifest.json" << EOF
{
    "update_backup": {
        "timestamp": "$TIMESTAMP",
        "type": "$UPDATE_TYPE",
        "environment": "$ENVIRONMENT",
        "branch": "$BRANCH",
        "previous_version": "$(get_current_version)",
        "files": {
            "application": "$BACKUP_PATH/app",
            "database_schema": "$BACKUP_PATH/database_schema.sql",
            "configs": "$BACKUP_PATH/*.service"
        }
    }
}
EOF
    
    success "Update backup created: $BACKUP_PATH"
}

get_current_version() {
    if [ -f "$APP_DIR/backend/app/__version__.py" ]; then
        grep "__version__" "$APP_DIR/backend/app/__version__.py" | cut -d'=' -f2 | tr -d " '\""
    else
        echo "unknown"
    fi
}

get_latest_version() {
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run mode - would check for updates"
        echo "dry-run-version"
        return 0
    fi
    
    cd "$APP_DIR"
    
    # Check git for updates
    if [ -d ".git" ]; then
        git fetch origin "$BRANCH"
        LOCAL_HASH=$(git rev-parse HEAD)
        REMOTE_HASH=$(git rev-parse "origin/$BRANCH")
        
        if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
            log "Updates available"
            git log --oneline "$LOCAL_HASH..origin/$BRANCH" | head -5
            return 0
        else
            log "Already up to date"
            return 1
        fi
    else
        warning "Not a git repository, cannot check for updates"
        return 2
    fi
}

update_system_packages() {
    log "Updating system packages..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would update system packages"
        apt list --upgradable 2>/dev/null | head -20
        return 0
    fi
    
    # Update package lists
    apt-get update
    
    # Upgrade packages
    apt-get upgrade -y
    
    # Clean up
    apt-get autoremove -y
    apt-get autoclean -y
    
    success "System packages updated"
}

update_python_dependencies() {
    log "Updating Python dependencies..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would update Python packages"
        "$APP_DIR/venv/bin/pip" list --outdated --format=freeze 2>/dev/null | head -20
        return 0
    fi
    
    cd "$APP_DIR/backend"
    
    # Update pip
    "$APP_DIR/venv/bin/pip" install --upgrade pip setuptools wheel
    
    # Update requirements
    if [ -f "requirements.txt" ]; then
        "$APP_DIR/venv/bin/pip" install --upgrade -r requirements.txt
    fi
    
    # Update development requirements if in development
    if [ "$ENVIRONMENT" = "development" ] && [ -f "requirements-dev.txt" ]; then
        "$APP_DIR/venv/bin/pip" install --upgrade -r requirements-dev.txt
    fi
    
    # Cleanup pip cache
    "$APP_DIR/venv/bin/pip" cache purge
    
    success "Python dependencies updated"
}

update_node_dependencies() {
    log "Updating Node.js dependencies..."
    
    if [ ! -f "$APP_DIR/frontend/package.json" ]; then
        warning "Frontend not found, skipping Node.js update"
        return 0
    fi
    
    cd "$APP_DIR/frontend"
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would update Node.js packages"
        npm outdated 2>/dev/null || true
        return 0
    fi
    
    # Update npm
    npm install -g npm@latest
    
    # Update packages
    npm update
    
    # Audit and fix vulnerabilities
    npm audit fix --force || true
    
    # Clean npm cache
    npm cache clean --force
    
    success "Node.js dependencies updated"
}

update_application_code() {
    log "Updating application code..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would update application code from $BRANCH"
        return 0
    fi
    
    cd "$APP_DIR"
    
    # Check if git repository
    if [ ! -d ".git" ]; then
        error "Not a git repository"
        return 1
    fi
    
    # Stash any local changes
    if git status --porcelain | grep -q "^ [MD]"; then
        warning "Local changes detected, stashing..."
        git stash save "Update stash $(date +%Y%m%d_%H%M%S)"
    fi
    
    # Pull updates
    git fetch origin
    git checkout "$BRANCH"
    git pull origin "$BRANCH"
    
    # Update submodules if any
    if [ -f ".gitmodules" ]; then
        git submodule update --init --recursive
    fi
    
    # Apply stashed changes if any
    if git stash list | grep -q "Update stash"; then
        warning "Applying stashed changes..."
        git stash pop || warning "Could not apply stash, conflicts may exist"
    fi
    
    success "Application code updated"
}

update_configurations() {
    log "Updating configurations..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would update configurations"
        return 0
    fi
    
    # Update environment file if template exists
    if [ -f "$APP_DIR/.env.example" ] && [ -f "$APP_DIR/.env" ]; then
        log "Updating environment configuration..."
        
        # Backup current .env
        cp "$APP_DIR/.env" "$APP_DIR/.env.backup.$(date +%s)"
        
        # Merge new variables from example
        while IFS='=' read -r key value; do
            if [[ ! $key =~ ^# ]] && [[ -n $key ]] && ! grep -q "^$key=" "$APP_DIR/.env"; then
                echo "$key=$value" >> "$APP_DIR/.env"
                log "Added new environment variable: $key"
            fi
        done < "$APP_DIR/.env.example"
    fi
    
    # Update systemd service files
    if [ -d "$APP_DIR/configs/systemd" ]; then
        log "Updating systemd services..."
        cp "$APP_DIR/configs/systemd/"*.service /etc/systemd/system/
        systemctl daemon-reload
    fi
    
    # Update nginx configuration
    if [ -f "$APP_DIR/nginx.conf" ]; then
        log "Updating nginx configuration..."
        cp "$APP_DIR/nginx.conf" /etc/nginx/
        nginx -t && systemctl reload nginx
    fi
    
    success "Configurations updated"
}

update_database() {
    log "Updating database..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would update database"
        return 0
    fi
    
    cd "$APP_DIR/backend"
    
    # Run migrations
    if [ -f "alembic.ini" ]; then
        log "Running database migrations..."
        "$APP_DIR/venv/bin/alembic" upgrade head
    fi
    
    # Run data migrations
    if [ -d "data_migrations" ]; then
        for script in data_migrations/*.py; do
            if [ -f "$script" ]; then
                log "Running data migration: $(basename $script)"
                "$APP_DIR/venv/bin/python" "$script"
            fi
        done
    fi
    
    success "Database updated"
}

update_monitoring() {
    log "Updating monitoring stack..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would update monitoring"
        return 0
    fi
    
    # Update Grafana dashboards
    if [ -d "$APP_DIR/grafana/provisioning" ]; then
        log "Updating Grafana dashboards..."
        cp -r "$APP_DIR/grafana/provisioning" /etc/grafana/
        systemctl restart grafana-server 2>/dev/null || true
    fi
    
    # Update Prometheus configuration
    if [ -f "$APP_DIR/prometheus.yml" ]; then
        log "Updating Prometheus configuration..."
        cp "$APP_DIR/prometheus.yml" /etc/prometheus/
        systemctl restart prometheus 2>/dev/null || true
    fi
    
    success "Monitoring stack updated"
}

build_frontend() {
    log "Building frontend..."
    
    if [ ! -f "$APP_DIR/frontend/package.json" ]; then
        warning "Frontend not found, skipping build"
        return 0
    fi
    
    cd "$APP_DIR/frontend"
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would build frontend"
        return 0
    fi
    
    # Install dependencies if needed
    if [ ! -d "node_modules" ]; then
        npm ci
    fi
    
    # Build based on environment
    export NODE_ENV="$ENVIRONMENT"
    
    case "$ENVIRONMENT" in
        production)
            npm run build
            ;;
        staging)
            npm run build:staging || npm run build
            ;;
        development)
            npm run build:dev || npm run dev
            ;;
    esac
    
    # Copy build to web directory
    if [ -d "build" ] || [ -d "dist" ] || [ -d ".next" ]; then
        rm -rf /var/www/ultimate-ai/*
        
        if [ -d "build" ]; then
            cp -r build/* /var/www/ultimate-ai/
        elif [ -d "dist" ]; then
            cp -r dist/* /var/www/ultimate-ai/
        elif [ -d ".next" ]; then
            cp -r .next/* /var/www/ultimate-ai/
        fi
        
        chown -R www-data:www-data /var/www/ultimate-ai
    fi
    
    success "Frontend built"
}

restart_services() {
    log "Restarting services..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would restart services"
        return 0
    fi
    
    # Restart in correct order
    systemctl restart nginx 2>/dev/null || true
    systemctl restart ultimate-ai-backend
    sleep 2
    systemctl restart ultimate-ai-celery
    systemctl restart ultimate-ai-celery-beat
    sleep 2
    systemctl restart ultimate-ai-flower 2>/dev/null || true
    
    # Wait for services to start
    sleep 5
    
    success "Services restarted"
}

verify_update() {
    log "Verifying update..."
    
    # Check service status
    local failed_services=()
    for service in ultimate-ai-backend ultimate-ai-celery nginx; do
        if ! systemctl is-active --quiet "$service"; then
            failed_services+=("$service")
        fi
    done
    
    if [ ${#failed_services[@]} -ne 0 ]; then
        error "Services failed to start: ${failed_services[*]}"
        return 1
    fi
    
    # Check health endpoints
    if ! curl -s -f "http://localhost:8000/health" >/dev/null; then
        error "Backend health check failed"
        return 1
    fi
    
    # Check database connection
    cd "$APP_DIR/backend"
    if ! "$APP_DIR/venv/bin/python" -c "
import sys
sys.path.insert(0, '.')
from app.core.database import SessionLocal
db = SessionLocal()
try:
    db.execute('SELECT 1')
    print('Database connection OK')
    db.close()
except Exception as e:
    print(f'Database error: {e}')
    sys.exit(1)
"; then
        error "Database verification failed"
        return 1
    fi
    
    success "Update verified successfully"
    return 0
}

rollback_update() {
    log "Rolling back last update..."
    
    # Find latest update backup
    local latest_backup=$(find "$BACKUP_DIR" -name "update_*" -type d | sort | tail -1)
    
    if [ -z "$latest_backup" ]; then
        error "No update backup found"
        return 1
    fi
    
    log "Found backup: $latest_backup"
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would rollback to: $latest_backup"
        return 0
    fi
    
    # Stop services
    systemctl stop ultimate-ai-backend
    systemctl stop ultimate-ai-celery
    
    # Restore application
    rm -rf "$APP_DIR"
    cp -r "$latest_backup/app" "$APP_DIR"
    chown -R "$USER_NAME:$USER_NAME" "$APP_DIR"
    
    # Restore database schema if backup exists
    if [ -f "$latest_backup/database_schema.sql" ]; then
        log "Restoring database schema..."
        export PGPASSWORD=$(grep DB_PASSWORD $APP_DIR/.env | cut -d= -f2)
        psql -h localhost -U ultimate_ai_user -d ultimate_ai \
            -f "$latest_backup/database_schema.sql"
        unset PGPASSWORD
    fi
    
    # Restart services
    restart_services
    
    success "Rollback completed to: $(basename $latest_backup)"
}

notify_update() {
    local status="$1"
    local message="$2"
    
    log "Sending update notification..."
    
    # Send to Slack
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{
                \"text\": \"*System Update $status*\\nEnvironment: $ENVIRONMENT\\nType: $UPDATE_TYPE\\n$message\\nTime: $(date)\"
            }" \
            "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
    fi
    
    # Send email
    if [ -n "$ALERT_EMAIL" ]; then
        echo "Update $status: $message" | mail -s "Ultimate AI Update $status" "$ALERT_EMAIL"
    fi
}

main() {
    check_root
    parse_args "$@"
    
    UPDATE_TYPE="${UPDATE_TYPE:-all}"
    
    log "Starting Ultimate AI System Update"
    log "Environment: $ENVIRONMENT"
    log "Branch: $BRANCH"
    log "Type: $UPDATE_TYPE"
    log "Dry run: ${DRY_RUN:-false}"
    
    # Check for rollback
    if [ "$ROLLBACK" = "true" ]; then
        rollback_update
        exit 0
    fi
    
    # Check for updates
    if ! get_latest_version && [ "$FORCE" != "true" ] && [ "$UPDATE_TYPE" != "security" ]; then
        log "No updates available"
        exit 0
    fi
    
    # Create backup
    create_update_backup
    
    # Perform updates based on type
    case "$UPDATE_TYPE" in
        system)
            update_system_packages
            ;;
        app)
            update_application_code
            update_python_dependencies
            update_node_dependencies
            update_database
            build_frontend
            ;;
        security)
            update_system_packages
            update_python_dependencies
            update_node_dependencies
            ;;
        all)
            update_system_packages
            update_application_code
            update_python_dependencies
            update_node_dependencies
            update_configurations
            update_database
            update_monitoring
            build_frontend
            ;;
        *)
            error "Unknown update type: $UPDATE_TYPE"
            exit 1
            ;;
    esac
    
    # Only restart if not dry run
    if [ "$DRY_RUN" != "true" ]; then
        restart_services
        verify_update
        
        if [ $? -eq 0 ]; then
            success "Update completed successfully!"
            
            # Send success notification
            local new_version=$(get_current_version)
            notify_update "SUCCESS" "System updated to version: $new_version"
            
            # Show update summary
            show_update_summary
        else
            error "Update verification failed, attempting rollback..."
            
            # Attempt automatic rollback
            rollback_update
            
            # Send failure notification
            notify_update "FAILED" "Update failed, system rolled back"
            
            exit 1
        fi
    else
        log "Dry run completed - no changes made"
    fi
}

show_update_summary() {
    cat << EOF

===============================================================================
✅ UPDATE COMPLETE
===============================================================================

Update Details:
- Environment: $ENVIRONMENT
- Type: $UPDATE_TYPE
- Previous Version: $(cat $BACKUP_PATH/update_manifest.json | jq -r '.update_backup.previous_version')
- New Version: $(get_current_version)
- Backup Location: $BACKUP_PATH

Services Updated:
$(systemctl list-units --type=service --state=running | grep ultimate-ai)

Next Steps:
1. Monitor system logs for errors
2. Check monitoring dashboards
3. Verify all features are working
4. Test critical user flows

To rollback if needed:
  $0 --rollback

===============================================================================
EOF
}

# Error handling
trap 'error "Update failed at line $LINENO"; exit 1' ERR

# Create log directory
mkdir -p "$LOG_DIR"

# Load environment
if [ -f "$APP_DIR/.env" ]; then
    set -a
    source "$APP_DIR/.env"
    set +a
fi

# Run main function
main "$@" 2>&1 | tee -a "$LOG_DIR/update.log"
