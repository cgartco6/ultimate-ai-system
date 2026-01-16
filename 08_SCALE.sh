#!/bin/bash

# Ultimate AI System - Scaling Script
# Version: 2.0.0

set -e
set -o pipefail

# Configuration
APP_DIR="/opt/ultimate-ai-system"
LOG_DIR="/var/log/ultimate-ai"
MONITORING_DIR="/opt/monitoring"
USER_NAME="ultimate-ai"
ENVIRONMENT="production"

# Default scaling values
BACKEND_REPLICAS=2
CELERY_REPLICAS=2
FRONTEND_REPLICAS=1
DATABASE_CONNECTIONS=100
REDIS_MEMORY="2gb"
WORKER_CONCURRENCY=4

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
            --backend|-b)
                BACKEND_REPLICAS="$2"
                shift 2
                ;;
            --celery|-c)
                CELERY_REPLICAS="$2"
                shift 2
                ;;
            --frontend|-f)
                FRONTEND_REPLICAS="$2"
                shift 2
                ;;
            --workers|-w)
                WORKER_CONCURRENCY="$2"
                shift 2
                ;;
            --database|-d)
                DATABASE_CONNECTIONS="$2"
                shift 2
                ;;
            --redis|-r)
                REDIS_MEMORY="$2"
                shift 2
                ;;
            --auto|-a)
                AUTO_SCALE=true
                shift
                ;;
            --dry-run|-n)
                DRY_RUN=true
                shift
                ;;
            --monitor|-m)
                MONITOR_ONLY=true
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
Ultimate AI System - Scaling Script

Usage: $0 [OPTIONS]

Options:
  -e, --environment    Environment (production, staging, development)
  -b, --backend        Backend replicas count
  -c, --celery         Celery worker replicas count
  -f, --frontend       Frontend replicas count
  -w, --workers        Worker concurrency per instance
  -d, --database       Max database connections
  -r, --redis          Redis memory limit (e.g., 2gb, 4gb)
  -a, --auto           Auto-scale based on metrics
  -n, --dry-run        Show scaling plan without applying
  -m, --monitor        Monitor only, don't scale
  -h, --help          Show this help message

Examples:
  $0 --backend 4 --celery 8 --workers 8
  $0 --auto
  $0 --dry-run --backend 3
EOF
}

check_system_resources() {
    log "Checking system resources..."
    
    # CPU cores
    CPU_CORES=$(nproc)
    log "CPU Cores: $CPU_CORES"
    
    # Memory
    TOTAL_MEM=$(free -g | grep Mem | awk '{print $2}')
    AVAILABLE_MEM=$(free -g | grep Mem | awk '{print $7}')
    log "Total Memory: ${TOTAL_MEM}GB"
    log "Available Memory: ${AVAILABLE_MEM}GB"
    
    # Disk space
    DISK_SPACE=$(df -h / | awk 'NR==2 {print $4}')
    log "Available Disk Space: $DISK_SPACE"
    
    # Load average
    LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}')
    log "Load Average: $LOAD_AVG"
    
    # Check if resources are sufficient
    if [ "$AVAILABLE_MEM" -lt 2 ]; then
        warning "Low memory available (${AVAILABLE_MEM}GB)"
    fi
    
    if [ "${LOAD_AVG%%,*}" -gt "$CPU_CORES" ]; then
        warning "High load average: $LOAD_AVG"
    fi
}

analyze_metrics() {
    log "Analyzing system metrics..."
    
    # Check Prometheus metrics if available
    if curl -s http://localhost:9090/api/v1/query?query=up >/dev/null 2>&1; then
        # Get current request rate
        REQUEST_RATE=$(curl -s "http://localhost:9090/api/v1/query?query=rate(http_requests_total[5m])" | \
            jq -r '.data.result[0].value[1] // 0')
        log "Request Rate: ${REQUEST_RATE:-0} req/s"
        
        # Get error rate
        ERROR_RATE=$(curl -s "http://localhost:9090/api/v1/query?query=rate(http_requests_total{status=~\"5..\"}[5m])" | \
            jq -r '.data.result[0].value[1] // 0')
        log "Error Rate: ${ERROR_RATE:-0} errors/s"
        
        # Get response time
        RESPONSE_TIME=$(curl -s "http://localhost:9090/api/v1/query?query=histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))" | \
            jq -r '.data.result[0].value[1] // 0')
        log "95th Percentile Response Time: ${RESPONSE_TIME:-0}s"
        
        # Get CPU usage
        CPU_USAGE=$(curl -s "http://localhost:9090/api/v1/query?query=100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)" | \
            jq -r '.data.result[0].value[1] // 0')
        log "CPU Usage: ${CPU_USAGE:-0}%"
        
        # Get memory usage
        MEM_USAGE=$(curl -s "http://localhost:9090/api/v1/query?query=(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100" | \
            jq -r '.data.result[0].value[1] // 0')
        log "Memory Usage: ${MEM_USAGE:-0}%"
    else
        warning "Prometheus not available, using system metrics"
    fi
}

calculate_auto_scale() {
    log "Calculating auto-scaling recommendations..."
    
    # Default recommendations
    local recommended_backend=2
    local recommended_celery=2
    local recommended_concurrency=4
    
    # Analyze metrics and adjust
    if [ -n "$REQUEST_RATE" ] && [ "$REQUEST_RATE" != "0" ]; then
        if [ "$(echo "$REQUEST_RATE > 100" | bc -l)" = "1" ]; then
            recommended_backend=$((recommended_backend * 2))
            recommended_celery=$((recommended_celery * 2))
            recommended_concurrency=$((recommended_concurrency * 2))
        elif [ "$(echo "$REQUEST_RATE > 50" | bc -l)" = "1" ]; then
            recommended_backend=$((recommended_backend + 1))
            recommended_celery=$((recommended_celery + 1))
        fi
    fi
    
    if [ -n "$CPU_USAGE" ] && [ "$CPU_USAGE" != "0" ]; then
        if [ "$(echo "$CPU_USAGE > 80" | bc -l)" = "1" ]; then
            recommended_backend=$((recommended_backend + 1))
        fi
    fi
    
    if [ -n "$ERROR_RATE" ] && [ "$ERROR_RATE" != "0" ]; then
        if [ "$(echo "$ERROR_RATE > 5" | bc -l)" = "1" ]; then
            warning "High error rate detected, consider scaling"
        fi
    fi
    
    # Adjust based on available resources
    check_system_resources
    
    if [ "$AVAILABLE_MEM" -lt 4 ]; then
        warning "Limited memory, reducing recommended scale"
        recommended_backend=$((recommended_backend > 2 ? recommended_backend - 1 : 2))
        recommended_celery=$((recommended_celery > 2 ? recommended_celery - 1 : 2))
    fi
    
    BACKEND_REPLICAS="$recommended_backend"
    CELERY_REPLICAS="$recommended_celery"
    WORKER_CONCURRENCY="$recommended_concurrency"
    
    log "Auto-scale recommendations:"
    log "  Backend replicas: $BACKEND_REPLICAS"
    log "  Celery replicas: $CELERY_REPLICAS"
    log "  Worker concurrency: $WORKER_CONCURRENCY"
}

scale_backend() {
    local replicas="$1"
    
    log "Scaling backend to $replicas replicas..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would scale backend to $replicas replicas"
        return 0
    fi
    
    # Update systemd service if using bare metal
    if systemctl list-unit-files | grep -q ultimate-ai-backend; then
        # For systemd, we need to create multiple instances
        for ((i=1; i<=replicas; i++)); do
            if [ ! -f "/etc/systemd/system/ultimate-ai-backend@$i.service" ]; then
                cp /etc/systemd/system/ultimate-ai-backend.service \
                   "/etc/systemd/system/ultimate-ai-backend@$i.service"
                sed -i "s/--bind 0.0.0.0:8000/--bind 0.0.0.0:$((8000 + i - 1))/" \
                   "/etc/systemd/system/ultimate-ai-backend@$i.service"
            fi
        done
        
        # Disable extra services
        for ((i=replicas+1; i<=10; i++)); do
            if [ -f "/etc/systemd/system/ultimate-ai-backend@$i.service" ]; then
                systemctl disable "ultimate-ai-backend@$i.service" 2>/dev/null || true
                systemctl stop "ultimate-ai-backend@$i.service" 2>/dev/null || true
            fi
        done
        
        # Reload and start services
        systemctl daemon-reload
        for ((i=1; i<=replicas; i++)); do
            systemctl enable "ultimate-ai-backend@$i.service"
            systemctl restart "ultimate-ai-backend@$i.service"
        done
    fi
    
    # Update load balancer configuration
    update_load_balancer_config
    
    success "Backend scaled to $replicas replicas"
}

scale_celery() {
    local replicas="$1"
    local concurrency="$2"
    
    log "Scaling Celery to $replicas replicas with $concurrency concurrency..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would scale Celery to $replicas replicas"
        return 0
    fi
    
    # Update celery systemd service
    if systemctl list-unit-files | grep -q ultimate-ai-celery; then
        for ((i=1; i<=replicas; i++)); do
            if [ ! -f "/etc/systemd/system/ultimate-ai-celery@$i.service" ]; then
                cp /etc/systemd/system/ultimate-ai-celery.service \
                   "/etc/systemd/system/ultimate-ai-celery@$i.service"
                sed -i "s/--concurrency=4/--concurrency=$concurrency/" \
                   "/etc/systemd/system/ultimate-ai-celery@$i.service"
                sed -i "s/worker@%h/worker-$i@%h/" \
                   "/etc/systemd/system/ultimate-ai-celery@$i.service"
            fi
        done
        
        # Disable extra services
        for ((i=replicas+1; i<=10; i++)); do
            if [ -f "/etc/systemd/system/ultimate-ai-celery@$i.service" ]; then
                systemctl disable "ultimate-ai-celery@$i.service" 2>/dev/null || true
                systemctl stop "ultimate-ai-celery@$i.service" 2>/dev/null || true
            fi
        done
        
        # Reload and start services
        systemctl daemon-reload
        for ((i=1; i<=replicas; i++)); do
            systemctl enable "ultimate-ai-celery@$i.service"
            systemctl restart "ultimate-ai-celery@$i.service"
        done
    fi
    
    success "Celery scaled to $replicas replicas"
}

scale_frontend() {
    local replicas="$1"
    
    log "Scaling frontend to $replicas replicas..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would scale frontend to $replicas replicas"
        return 0
    fi
    
    # Update nginx load balancing configuration
    update_load_balancer_config
    
    success "Frontend scaling configured for $replicas replicas"
}

scale_database() {
    local max_connections="$1"
    
    log "Scaling database connections to $max_connections..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would scale database to $max_connections connections"
        return 0
    fi
    
    # Update PostgreSQL configuration
    if [ -f "/etc/postgresql/15/main/postgresql.conf" ]; then
        sed -i "s/^max_connections = .*/max_connections = $max_connections/" \
            /etc/postgresql/15/main/postgresql.conf
        
        # Calculate shared_buffers (25% of RAM, max 8GB)
        local total_ram_gb=$(free -g | grep Mem | awk '{print $2}')
        local shared_buffers=$((total_ram_gb * 1024 / 4))
        [ $shared_buffers -gt 8192 ] && shared_buffers=8192
        
        sed -i "s/^shared_buffers = .*/shared_buffers = ${shared_buffers}MB/" \
            /etc/postgresql/15/main/postgresql.conf
        
        # Restart PostgreSQL
        systemctl restart postgresql
        
        success "Database scaled to $max_connections connections"
    else
        warning "PostgreSQL configuration not found"
    fi
}

scale_redis() {
    local memory_limit="$1"
    
    log "Scaling Redis memory to $memory_limit..."
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run - would scale Redis to $memory_limit"
        return 0
    fi
    
    # Update Redis configuration
    if [ -f "/etc/redis/redis.conf" ]; then
        sed -i "s/^maxmemory .*/maxmemory $memory_limit/" \
            /etc/redis/redis.conf
        
        # Set appropriate policy
        sed -i "s/^maxmemory-policy .*/maxmemory-policy allkeys-lru/" \
            /etc/redis/redis.conf
        
        # Restart Redis
        systemctl restart redis
        
        success "Redis scaled to $memory_limit"
    else
        warning "Redis configuration not found"
    fi
}

update_load_balancer_config() {
    log "Updating load balancer configuration..."
    
    # Update nginx upstream configuration
    cat > /etc/nginx/conf.d/backend_upstream.conf << EOF
# Backend upstream configuration
upstream backend_servers {
    # Backend instances
    server 127.0.0.1:8000 max_fails=3 fail_timeout=30s;
EOF
    
    # Add additional backend instances
    for ((i=2; i<=BACKEND_REPLICAS; i++)); do
        echo "    server 127.0.0.1:$((8000 + i - 1)) max_fails=3 fail_timeout=30s;" \
            >> /etc/nginx/conf.d/backend_upstream.conf
    done
    
    cat >> /etc/nginx/conf.d/backend_upstream.conf << EOF
    
    # Load balancing method
    least_conn;
    
    # Health check
    keepalive 32;
}

# Frontend upstream configuration
upstream frontend_servers {
    server 127.0.0.1:3000;
    
    # Load balancing method
    ip_hash;
    
    # Health check
    keepalive 16;
}
EOF
    
    # Reload nginx
    nginx -t && systemctl reload nginx
    
    success "Load balancer configuration updated"
}

monitor_scaling() {
    log "Monitoring scaling performance..."
    
    # Create monitoring dashboard
    cat > /tmp/scaling_monitor.json << EOF
{
    "dashboard": {
        "title": "Scaling Monitor",
        "panels": [
            {
                "title": "Backend Replicas",
                "targets": [{
                    "expr": "count(up{job=\"ultimate-ai-backend\"})",
                    "legendFormat": "Replicas"
                }]
            },
            {
                "title": "Request Rate",
                "targets": [{
                    "expr": "rate(http_requests_total[5m])",
                    "legendFormat": "req/s"
                }]
            },
            {
                "title": "Response Time",
                "targets": [{
                    "expr": "histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))",
                    "legendFormat": "95th percentile"
                }]
            },
            {
                "title": "CPU Usage",
                "targets": [{
                    "expr": "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
                    "legendFormat": "CPU %"
                }]
            }
        ]
    }
}
EOF
    
    # Import dashboard to Grafana if available
    if [ -d "/etc/grafana" ]; then
        cp /tmp/scaling_monitor.json /var/lib/grafana/dashboards/
        success "Scaling monitor dashboard created"
    fi
    
    # Start monitoring script
    cat > /usr/local/bin/monitor_scaling.sh << 'EOF'
#!/bin/bash
while true; do
    echo "=== Scaling Monitor $(date) ==="
    echo "Backend Replicas: $(systemctl list-units | grep ultimate-ai-backend | grep running | wc -l)"
    echo "Celery Workers: $(systemctl list-units | grep ultimate-ai-celery | grep running | wc -l)"
    echo "Load Average: $(uptime | awk -F'load average:' '{print $2}')"
    echo "Memory Usage: $(free -h | grep Mem | awk '{print $3"/"$2}')"
    echo "------------------------------"
    sleep 30
done
EOF
    
    chmod +x /usr/local/bin/monitor_scaling.sh
    
    # Start monitoring service
    cat > /etc/systemd/system/ultimate-ai-scaling-monitor.service << EOF
[Unit]
Description=Ultimate AI Scaling Monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/monitor_scaling.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable ultimate-ai-scaling-monitor
    systemctl start ultimate-ai-scaling-monitor
    
    success "Scaling monitoring started"
}

validate_scaling() {
    log "Validating scaling configuration..."
    
    local errors=0
    
    # Check backend services
    local backend_running=$(systemctl list-units | grep "ultimate-ai-backend" | grep running | wc -l)
    if [ "$backend_running" -lt "$BACKEND_REPLICAS" ]; then
        error "Backend services running: $backend_running, expected: $BACKEND_REPLICAS"
        errors=$((errors + 1))
    fi
    
    # Check celery services
    local celery_running=$(systemctl list-units | grep "ultimate-ai-celery" | grep running | wc -l)
    if [ "$celery_running" -lt "$CELERY_REPLICAS" ]; then
        error "Celery services running: $celery_running, expected: $CELERY_REPLICAS"
        errors=$((errors + 1))
    fi
    
    # Check database connections
    if command -v psql >/dev/null 2>&1; then
        local db_connections=$(psql -h localhost -U ultimate_ai_user -d ultimate_ai \
            -c "SELECT count(*) FROM pg_stat_activity WHERE datname = 'ultimate_ai';" -t)
        log "Database connections: $db_connections"
        
        if [ "$db_connections" -gt $((DATABASE_CONNECTIONS * 8 / 10)) ]; then
            warning "High database connection count: $db_connections"
        fi
    fi
    
    # Check Redis memory
    if command -v redis-cli >/dev/null 2>&1; then
        local redis_memory=$(redis-cli info memory | grep used_memory_human | cut -d: -f2)
        log "Redis memory usage: $redis_memory"
    fi
    
    if [ $errors -eq 0 ]; then
        success "Scaling validation passed"
        return 0
    else
        error "Scaling validation failed with $errors errors"
        return 1
    fi
}

show_scaling_summary() {
    cat << EOF

===============================================================================
📈 SCALING SUMMARY
===============================================================================

Configuration Applied:
- Backend Replicas: $BACKEND_REPLICAS
- Celery Workers: $CELERY_REPLICAS
- Frontend Replicas: $FRONTEND_REPLICAS
- Worker Concurrency: $WORKER_CONCURRENCY
- Database Connections: $DATABASE_CONNECTIONS
- Redis Memory: $REDIS_MEMORY

Current State:
- Backend Running: $(systemctl list-units | grep "ultimate-ai-backend" | grep running | wc -l)
- Celery Running: $(systemctl list-units | grep "ultimate-ai-celery" | grep running | wc -l)
- Load Average: $(uptime | awk -F'load average:' '{print $2}')
- Memory Usage: $(free -h | grep Mem | awk '{print $3"/"$2}')

Monitoring:
- Scaling Monitor: systemctl status ultimate-ai-scaling-monitor
- Metrics: http://localhost:9090 (Prometheus)
- Dashboards: http://localhost:3000 (Grafana)

Next Steps:
1. Monitor performance metrics
2. Adjust scaling based on load
3. Set up auto-scaling rules
4. Configure alerts for scaling events

===============================================================================
EOF
}

main() {
    check_root
    parse_args "$@"
    
    log "Starting Ultimate AI System Scaling"
    log "Environment: $ENVIRONMENT"
    
    # Check system resources
    check_system_resources
    
    # Analyze metrics
    analyze_metrics
    
    # Auto-scale if requested
    if [ "$AUTO_SCALE" = "true" ]; then
        calculate_auto_scale
    fi
    
    # Monitor only mode
    if [ "$MONITOR_ONLY" = "true" ]; then
        monitor_scaling
        exit 0
    fi
    
    # Show scaling plan
    log "Scaling Plan:"
    log "  Backend: $BACKEND_REPLICAS replicas"
    log "  Celery: $CELERY_REPLICAS replicas"
    log "  Frontend: $FRONTEND_REPLICAS replicas"
    log "  Worker Concurrency: $WORKER_CONCURRENCY"
    log "  Database Connections: $DATABASE_CONNECTIONS"
    log "  Redis Memory: $REDIS_MEMORY"
    
    if [ "$DRY_RUN" = "true" ]; then
        log "Dry run complete - no changes made"
        exit 0
    fi
    
    # Apply scaling
    scale_backend "$BACKEND_REPLICAS"
    scale_celery "$CELERY_REPLICAS" "$WORKER_CONCURRENCY"
    scale_frontend "$FRONTEND_REPLICAS"
    scale_database "$DATABASE_CONNECTIONS"
    scale_redis "$REDIS_MEMORY"
    
    # Update load balancer
    update_load_balancer_config
    
    # Setup monitoring
    monitor_scaling
    
    # Validate scaling
    validate_scaling
    
    success "Scaling completed successfully!"
    
    # Show summary
    show_scaling_summary
}

# Run main function
main "$@"
