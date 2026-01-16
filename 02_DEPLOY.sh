#!/bin/bash

# Ultimate AI System - Production Deployment Script
# Version: 2.0.0

set -e
set -o pipefail

# Configuration
DEPLOY_DIR="/opt/ultimate-ai-system"
BACKUP_DIR="/var/backups/ultimate-ai"
LOG_DIR="/var/log/ultimate-ai"
USER_NAME="ultimate-ai"
BRANCH="main"
ENVIRONMENT="production"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --branch|-b)
                BRANCH="$2"
                shift 2
                ;;
            --environment|-e)
                ENVIRONMENT="$2"
                shift 2
                ;;
            --rollback|-r)
                rollback
                exit 0
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
Ultimate AI System - Deployment Script

Usage: $0 [OPTIONS]

Options:
  -b, --branch        Git branch to deploy (default: main)
  -e, --environment   Deployment environment (default: production)
  -r, --rollback      Rollback to previous version
  -h, --help         Show this help message

Examples:
  $0 --branch main --environment production
  $0 --rollback
EOF
}

# Create backup
create_backup() {
    log "Creating backup of current version..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/deploy_$TIMESTAMP"
    
    mkdir -p "$BACKUP_PATH"
    
    # Backup application files
    rsync -a --exclude='venv' --exclude='node_modules' --exclude='.git' \
        "$DEPLOY_DIR/" "$BACKUP_PATH/app/"
    
    # Backup database
    if command -v pg_dump &>/dev/null; then
        pg_dump -U ultimate_ai_user -h localhost -d ultimate_ai > "$BACKUP_PATH/database.sql"
    fi
    
    # Backup environment file
    cp "$DEPLOY_DIR/.env" "$BACKUP_PATH/"
    
    # Create backup manifest
    cat > "$BACKUP_PATH/manifest.json" << EOF
{
    "timestamp": "$TIMESTAMP",
    "branch": "$BRANCH",
    "environment": "$ENVIRONMENT",
    "files": {
        "app": "$BACKUP_PATH/app",
        "database": "$BACKUP_PATH/database.sql",
        "env": "$BACKUP_PATH/.env"
    }
}
EOF
    
    # Keep only last 5 backups
    ls -dt "$BACKUP_DIR/deploy_"* | tail -n +6 | xargs rm -rf
    
    success "Backup created: $BACKUP_PATH"
}

# Deploy application
deploy_application() {
    log "Deploying application from branch: $BRANCH"
    
    cd "$DEPLOY_DIR"
    
    # Pull latest code
    if [ -d ".git" ]; then
        log "Pulling latest code from $BRANCH..."
        git fetch origin
        git checkout "$BRANCH"
        git pull origin "$BRANCH"
    else
        error "Git repository not found in $DEPLOY_DIR"
        exit 1
    fi
    
    # Update submodules if any
    if [ -f ".gitmodules" ]; then
        git submodule update --init --recursive
    fi
    
    success "Code updated successfully"
}

# Install dependencies
install_dependencies() {
    log "Installing dependencies..."
    
    cd "$DEPLOY_DIR"
    
    # Python dependencies
    if [ -f "backend/requirements.txt" ]; then
        log "Installing Python dependencies..."
        sudo -u "$USER_NAME" "$DEPLOY_DIR/venv/bin/pip" install --upgrade -r backend/requirements.txt
    fi
    
    # Node.js dependencies
    if [ -f "frontend/package.json" ]; then
        log "Installing Node.js dependencies..."
        cd frontend
        sudo -u "$USER_NAME" npm ci --only=production
        cd ..
    fi
    
    success "Dependencies installed"
}

# Build frontend
build_frontend() {
    log "Building frontend application..."
    
    if [ -f "$DEPLOY_DIR/frontend/package.json" ]; then
        cd "$DEPLOY_DIR/frontend"
        
        # Set environment
        export NODE_ENV="$ENVIRONMENT"
        
        # Install build dependencies if needed
        if [ ! -d "node_modules" ]; then
            sudo -u "$USER_NAME" npm ci
        fi
        
        # Build application
        log "Running build process..."
        sudo -u "$USER_NAME" npm run build
        
        # Copy build to nginx directory
        if [ -d "build" ] || [ -d "out" ] || [ -d ".next" ]; then
            rm -rf /var/www/ultimate-ai/*
            
            if [ -d "build" ]; then
                cp -r build/* /var/www/ultimate-ai/
            elif [ -d "out" ]; then
                cp -r out/* /var/www/ultimate-ai/
            elif [ -d ".next" ]; then
                cp -r .next/* /var/www/ultimate-ai/
            fi
            
            chown -R www-data:www-data /var/www/ultimate-ai
        fi
        
        success "Frontend built successfully"
    else
        warning "Frontend not found, skipping build"
    fi
}

# Run database migrations
run_migrations() {
    log "Running database migrations..."
    
    cd "$DEPLOY_DIR/backend"
    
    # Check if alembic is available
    if [ -f "alembic.ini" ]; then
        sudo -u "$USER_NAME" "$DEPLOY_DIR/venv/bin/alembic" upgrade head
        success "Database migrations completed"
    else
        warning "Alembic configuration not found, skipping migrations"
    fi
}

# Clear caches
clear_caches() {
    log "Clearing application caches..."
    
    # Clear Redis cache
    if command -v redis-cli &>/dev/null; then
        redis-cli FLUSHALL
    fi
    
    # Clear Python cache
    find "$DEPLOY_DIR" -name "__pycache__" -type d -exec rm -rf {} +
    find "$DEPLOY_DIR" -name "*.pyc" -delete
    
    # Clear frontend cache
    if [ -d "$DEPLOY_DIR/frontend/.next" ]; then
        rm -rf "$DEPLOY_DIR/frontend/.next/cache"
    fi
    
    success "Caches cleared"
}

# Warm up caches
warmup_caches() {
    log "Warming up application caches..."
    
    # Warm up backend
    if curl -s http://localhost:8000/health >/dev/null 2>&1; then
        # Pre-load common endpoints
        curl -s http://localhost:8000/api/ai/status >/dev/null
        curl -s http://localhost:8000/api/trading/markets >/dev/null
        curl -s http://localhost:8000/api/workout/programs >/dev/null
    fi
    
    success "Caches warmed up"
}

# Restart services
restart_services() {
    log "Restarting application services..."
    
    # Restart in order
    systemctl restart ultimate-ai-backend
    sleep 5
    
    systemctl restart ultimate-ai-celery
    systemctl restart ultimate-ai-celery-beat
    sleep 2
    
    systemctl restart ultimate-ai-flower
    systemctl restart nginx
    
    # Wait for services to start
    sleep 10
    
    success "Services restarted"
}

# Health check
health_check() {
    log "Performing health checks..."
    
    ALL_HEALTHY=true
    
    # Check backend
    if ! curl -f -s http://localhost:8000/health >/dev/null; then
        error "Backend health check failed"
        ALL_HEALTHY=false
    else
        success "Backend is healthy"
    fi
    
    # Check database
    if ! pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
        error "Database health check failed"
        ALL_HEALTHY=false
    else
        success "Database is healthy"
    fi
    
    # Check Redis
    if ! redis-cli ping >/dev/null 2>&1; then
        error "Redis health check failed"
        ALL_HEALTHY=false
    else
        success "Redis is healthy"
    fi
    
    # Check frontend (if available)
    if curl -f -s http://localhost:3000 >/dev/null 2>&1 || \
       curl -f -s http://localhost >/dev/null 2>&1; then
        success "Frontend is accessible"
    else
        warning "Frontend health check inconclusive"
    fi
    
    if [ "$ALL_HEALTHY" = true ]; then
        success "All health checks passed!"
        return 0
    else
        error "Some health checks failed"
        return 1
    fi
}

# Rollback to previous version
rollback() {
    log "Initiating rollback..."
    
    # Get latest backup
    LATEST_BACKUP=$(ls -dt "$BACKUP_DIR/deploy_"* | head -1)
    
    if [ -z "$LATEST_BACKUP" ]; then
        error "No backup found for rollback"
        exit 1
    fi
    
    log "Rolling back to: $LATEST_BACKUP"
    
    # Stop services
    systemctl stop ultimate-ai-backend
    systemctl stop ultimate-ai-celery
    systemctl stop ultimate-ai-celery-beat
    
    # Restore application files
    rm -rf "$DEPLOY_DIR"/*
    cp -r "$LATEST_BACKUP/app/"* "$DEPLOY_DIR/"
    
    # Restore environment file
    cp "$LATEST_BACKUP/.env" "$DEPLOY_DIR/"
    
    # Restore database if backup exists
    if [ -f "$LATEST_BACKUP/database.sql" ]; then
        log "Restoring database..."
        psql -U ultimate_ai_user -h localhost -d ultimate_ai < "$LATEST_BACKUP/database.sql"
    fi
    
    # Restart services
    restart_services
    
    # Health check
    if health_check; then
        success "Rollback completed successfully!"
    else
        error "Rollback completed but health checks failed"
        exit 1
    fi
}

# Main deployment function
deploy() {
    log "Starting deployment process..."
    log "Environment: $ENVIRONMENT"
    log "Branch: $BRANCH"
    
    # Step 1: Create backup
    create_backup
    
    # Step 2: Deploy application
    deploy_application
    
    # Step 3: Install dependencies
    install_dependencies
    
    # Step 4: Build frontend
    build_frontend
    
    # Step 5: Run migrations
    run_migrations
    
    # Step 6: Clear caches
    clear_caches
    
    # Step 7: Restart services
    restart_services
    
    # Step 8: Warm up caches
    warmup_caches
    
    # Step 9: Health check
    if health_check; then
        success "Deployment completed successfully!"
        
        # Send deployment notification
        send_notification "success"
    else
        error "Deployment completed but health checks failed"
        
        # Send failure notification
        send_notification "failure"
        
        # Optionally auto-rollback
        if [ "$ENVIRONMENT" = "production" ]; then
            warning "Auto-rollback triggered due to health check failure"
            rollback
        fi
        
        exit 1
    fi
}

# Send deployment notification
send_notification() {
    local status=$1
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="Deployment $status - Environment: $ENVIRONMENT, Branch: $BRANCH, Time: $timestamp"
    
    log "Sending deployment notification..."
    
    # Example: Send to Slack
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"$message\"}" \
            "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
    fi
    
    # Example: Send email
    if [ -n "$ALERT_EMAIL" ]; then
        echo "$message" | mail -s "Ultimate AI System Deployment $status" "$ALERT_EMAIL"
    fi
    
    success "Notification sent"
}

# Run main deployment
main() {
    check_root
    parse_args "$@"
    
    # Create lock file to prevent concurrent deployments
    LOCK_FILE="/tmp/ultimate-ai-deploy.lock"
    if [ -f "$LOCK_FILE" ]; then
        error "Deployment already in progress (lock file exists)"
        exit 1
    fi
    
    trap 'rm -f $LOCK_FILE' EXIT
    touch "$LOCK_FILE"
    
    # Start deployment
    deploy
    
    # Cleanup
    rm -f "$LOCK_FILE"
}

# Execute main function
main "$@"
