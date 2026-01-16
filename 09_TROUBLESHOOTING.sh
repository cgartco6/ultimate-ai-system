#!/bin/bash

# Ultimate AI System - Troubleshooting Script
# Version: 2.0.0

set -e
set -o pipefail

# Configuration
APP_DIR="/opt/ultimate-ai-system"
LOG_DIR="/var/log/ultimate-ai"
CONFIG_DIR="/etc/ultimate-ai"
BACKUP_DIR="/var/backups/ultimate-ai"
USER_NAME="ultimate-ai"

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

show_help() {
    cat << EOF
Ultimate AI System - Troubleshooting Script

Usage: $0 [COMMAND] [OPTIONS]

Commands:
  diagnose          Run comprehensive system diagnosis
  logs              Show relevant logs
  status            Check service status
  test              Run connectivity tests
  repair            Attempt to repair issues
  performance       Check performance metrics
  security          Security checks
  backup            Backup before troubleshooting
  restore           Restore from backup

Options:
  --service         Specific service to troubleshoot
  --component       Component to check (database, redis, api, etc.)
  --since           Logs since time (e.g., "1 hour ago")
  --tail            Tail logs continuously
  --fix             Automatically fix issues when possible
  --verbose         Show detailed information
  --report          Generate troubleshooting report

Examples:
  $0 diagnose
  $0 logs --service backend --since "1 hour ago"
  $0 status --component all
  $0 repair --fix
EOF
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Some checks require root privileges"
        return 1
    fi
    return 0
}

backup_before_troubleshoot() {
    log "Creating backup before troubleshooting..."
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/troubleshoot_$TIMESTAMP"
    
    mkdir -p "$BACKUP_PATH"
    
    # Backup critical configurations
    cp -r /etc/systemd/system/ultimate-ai-*.service "$BACKUP_PATH/" 2>/dev/null || true
    cp "$APP_DIR/.env" "$BACKUP_PATH/" 2>/dev/null || true
    cp /etc/nginx/sites-available/ultimate-ai "$BACKUP_PATH/" 2>/dev/null || true
    
    # Backup database schema
    if command -v pg_dump &>/dev/null; then
        export PGPASSWORD=$(grep DB_PASSWORD $APP_DIR/.env 2>/dev/null | cut -d= -f2)
        pg_dump -h localhost -U ultimate_ai_user -d ultimate_ai --schema-only \
            > "$BACKUP_PATH/database_schema.sql" 2>/dev/null || true
        unset PGPASSWORD
    fi
    
    success "Backup created: $BACKUP_PATH"
}

run_diagnosis() {
    log "Running comprehensive system diagnosis..."
    
    echo -e "\n${BLUE}=== SYSTEM DIAGNOSIS REPORT ===${NC}"
    echo "Generated: $(date)"
    echo "Hostname: $(hostname)"
    echo "Uptime: $(uptime -p)"
    
    # System checks
    check_system_health
    check_services
    check_network
    check_database
    check_redis
    check_application
    check_security
    check_performance
    
    echo -e "\n${BLUE}=== DIAGNOSIS COMPLETE ===${NC}"
}

check_system_health() {
    echo -e "\n${YELLOW}1. SYSTEM HEALTH${NC}"
    
    # CPU
    echo -n "CPU Load: "
    uptime | awk -F'load average:' '{print $2}'
    
    # Memory
    echo -n "Memory Usage: "
    free -h | grep Mem | awk '{print $3"/"$2 " ("$3/$2*100"%)"}'
    
    # Disk
    echo "Disk Usage:"
    df -h | grep -E "^/dev/|^Filesystem"
    
    # Temperature (if available)
    if command -v sensors &>/dev/null; then
        echo -n "CPU Temperature: "
        sensors | grep Core | head -1 | awk '{print $3}'
    fi
    
    # Swap
    echo -n "Swap Usage: "
    free -h | grep Swap | awk '{print $3"/"$2 " ("$3/$2*100"%)"}'
}

check_services() {
    echo -e "\n${YELLOW}2. SERVICE STATUS${NC}"
    
    local services=(
        "postgresql"
        "redis"
        "nginx"
        "ultimate-ai-backend"
        "ultimate-ai-celery"
        "ultimate-ai-celery-beat"
        "prometheus"
        "grafana-server"
    )
    
    for service in "${services[@]}"; do
        if systemctl list-unit-files | grep -q "$service"; then
            local status=$(systemctl is-active "$service" 2>/dev/null || echo "not-found")
            if [ "$status" = "active" ]; then
                echo "✓ $service: $status"
            else
                echo "✗ $service: $status"
                # Show error if any
                journalctl -u "$service" --since "5 minutes ago" --no-pager | tail -5
            fi
        fi
    done
}

check_network() {
    echo -e "\n${YELLOW}3. NETWORK CONNECTIVITY${NC}"
    
    # Check listening ports
    echo "Listening Ports:"
    netstat -tulpn | grep -E ":80|:443|:8000|:5432|:6379|:9090|:3000" | awk '{print "  "$4" -> "$7}'
    
    # Check firewall
    if command -v ufw &>/dev/null; then
        echo "Firewall Status:"
        ufw status verbose
    elif command -v firewall-cmd &>/dev/null; then
        echo "Firewall Status:"
        firewall-cmd --list-all
    fi
    
    # Check DNS
    echo -n "DNS Resolution: "
    if nslookup google.com &>/dev/null; then
        echo "✓ Working"
    else
        echo "✗ Failed"
    fi
}

check_database() {
    echo -e "\n${YELLOW}4. DATABASE${NC}"
    
    # PostgreSQL
    if command -v pg_isready &>/dev/null; then
        echo -n "PostgreSQL: "
        if pg_isready -h localhost -p 5432; then
            echo "✓ Accessible"
            
            # Check connections
            local connections=$(psql -h localhost -U postgres -c "SELECT count(*) FROM pg_stat_activity;" -t 2>/dev/null || echo "0")
            echo "  Active Connections: $connections"
            
            # Check locks
            local locks=$(psql -h localhost -U postgres -c "SELECT count(*) FROM pg_locks WHERE granted = false;" -t 2>/dev/null || echo "0")
            if [ "$locks" -gt 0 ]; then
                echo "  Waiting Locks: $locks"
            fi
            
            # Check replication if any
            psql -h localhost -U postgres -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;" 2>/dev/null | head -5
        else
            echo "✗ Not accessible"
        fi
    else
        echo "PostgreSQL client not found"
    fi
}

check_redis() {
    echo -e "\n${YELLOW}5. REDIS${NC}"
    
    if command -v redis-cli &>/dev/null; then
        echo -n "Redis: "
        if redis-cli ping &>/dev/null; then
            echo "✓ Accessible"
            
            # Get info
            echo "  Memory: $(redis-cli info memory | grep used_memory_human | cut -d: -f2)"
            echo "  Connections: $(redis-cli info clients | grep connected_clients | cut -d: -f2)"
            echo "  Keys: $(redis-cli dbsize)"
        else
            echo "✗ Not accessible"
        fi
    fi
}

check_application() {
    echo -e "\n${YELLOW}6. APPLICATION${NC}"
    
    # Check backend API
    echo -n "Backend API: "
    if curl -s -f "http://localhost:8000/health" >/dev/null; then
        echo "✓ Healthy"
        
        # Get version
        local version=$(curl -s "http://localhost:8000/health" | jq -r '.version' 2>/dev/null || echo "unknown")
        echo "  Version: $version"
    else
        echo "✗ Unhealthy"
        echo "  Response: $(curl -s "http://localhost:8000/health" | head -c 100)"
    fi
    
    # Check frontend
    echo -n "Frontend: "
    if curl -s -f "http://localhost:3000" >/dev/null; then
        echo "✓ Accessible"
    else
        echo "✗ Not accessible"
    fi
    
    # Check Celery
    echo -n "Celery Workers: "
    if systemctl is-active ultimate-ai-celery &>/dev/null; then
        echo "✓ Running"
        
        # Check worker count
        local workers=$(ps aux | grep "celery worker" | grep -v grep | wc -l)
        echo "  Worker Processes: $workers"
    else
        echo "✗ Not running"
    fi
}

check_security() {
    echo -e "\n${YELLOW}7. SECURITY${NC}"
    
    # Check SSL certificates
    echo "SSL Certificates:"
    if [ -f "/etc/ssl/ultimate-ai/certificate.crt" ]; then
        local expiry=$(openssl x509 -enddate -noout -in /etc/ssl/ultimate-ai/certificate.crt | cut -d= -f2)
        echo "  Expires: $expiry"
        
        local days_left=$(( ($(date -d "$expiry" +%s) - $(date +%s)) / 86400 ))
        if [ "$days_left" -lt 30 ]; then
            echo "  ⚠ Certificate expires in $days_left days"
        fi
    else
        echo "  ✗ No certificate found"
    fi
    
    # Check fail2ban
    if systemctl is-active fail2ban &>/dev/null; then
        echo "  Fail2ban: ✓ Active"
        echo "  Banned IPs: $(fail2ban-client status | grep -A 100 "Jail list" | tr ',' '\n' | wc -l)"
    fi
    
    # Check firewall
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        echo "  Firewall: ✓ Active"
    fi
}

check_performance() {
    echo -e "\n${YELLOW}8. PERFORMANCE${NC}"
    
    # Check Prometheus metrics if available
    if curl -s "http://localhost:9090/api/v1/query?query=up" >/dev/null 2>&1; then
        echo "Prometheus Metrics: ✓ Available"
        
        # Get request rate
        local rate=$(curl -s "http://localhost:9090/api/v1/query?query=rate(http_requests_total[5m])" | \
            jq -r '.data.result[0].value[1] // 0' 2>/dev/null || echo "0")
        echo "  Request Rate: ${rate} req/s"
        
        # Get error rate
        local errors=$(curl -s "http://localhost:9090/api/v1/query?query=rate(http_requests_total{status=~\"5..\"}[5m])" | \
            jq -r '.data.result[0].value[1] // 0' 2>/dev/null || echo "0")
        echo "  Error Rate: ${errors} errors/s"
        
        # Get response time
        local response=$(curl -s "http://localhost:9090/api/v1/query?query=histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))" | \
            jq -r '.data.result[0].value[1] // 0' 2>/dev/null || echo "0")
        echo "  95th Percentile Response: ${response}s"
    else
        echo "Prometheus: ✗ Not available"
    fi
}

show_logs() {
    local service="$1"
    local since="${2:-1 hour ago}"
    local tail_mode="${3:-false}"
    
    log "Showing logs for $service since $since"
    
    case "$service" in
        backend)
            if [ "$tail_mode" = "true" ]; then
                tail -f "$LOG_DIR/backend-error.log"
            else
                journalctl -u ultimate-ai-backend --since "$since" --no-pager
            fi
            ;;
        celery)
            if [ "$tail_mode" = "true" ]; then
                tail -f "$LOG_DIR/celery.log"
            else
                journalctl -u ultimate-ai-celery --since "$since" --no-pager
            fi
            ;;
        nginx)
            if [ "$tail_mode" = "true" ]; then
                tail -f /var/log/nginx/error.log
            else
                journalctl -u nginx --since "$since" --no-pager
            fi
            ;;
        postgresql)
            journalctl -u postgresql --since "$since" --no-pager | tail -50
            ;;
        redis)
            journalctl -u redis --since "$since" --no-pager | tail -50
            ;;
        all)
            for log_file in "$LOG_DIR"/*.log; do
                echo -e "\n${YELLOW}=== $(basename "$log_file") ===${NC}"
                tail -50 "$log_file"
            done
            ;;
        *)
            error "Unknown service: $service"
            return 1
            ;;
    esac
}

check_status() {
    local component="$1"
    
    case "$component" in
        database)
            check_database
            ;;
        redis)
            check_redis
            ;;
        api)
            check_application | grep -A 5 "Backend API"
            ;;
        services)
            check_services
            ;;
        all)
            check_services
            check_database
            check_redis
            check_application
            ;;
        *)
            error "Unknown component: $component"
            return 1
            ;;
    esac
}

run_tests() {
    log "Running connectivity tests..."
    
    echo -e "\n${YELLOW}CONNECTIVITY TESTS${NC}"
    
    # Test local services
    local tests=(
        "localhost:5432 PostgreSQL"
        "localhost:6379 Redis"
        "localhost:8000 Backend API"
        "localhost:3000 Frontend"
        "localhost:9090 Prometheus"
        "localhost:3001 Grafana"
    )
    
    for test in "${tests[@]}"; do
        local port=$(echo "$test" | cut -d: -f2 | cut -d' ' -f1)
        local service=$(echo "$test" | cut -d' ' -f2-)
        
        echo -n "Testing $service ($port): "
        if timeout 2 bash -c "echo > /dev/tcp/localhost/$port" 2>/dev/null; then
            echo "✓ Open"
        else
            echo "✗ Closed"
        fi
    done
    
    # Test external connectivity
    echo -n "Testing external connectivity (google.com): "
    if ping -c 1 -W 2 google.com &>/dev/null; then
        echo "✓ Reachable"
    else
        echo "✗ Unreachable"
    fi
    
    # Test DNS
    echo -n "Testing DNS resolution: "
    if nslookup google.com &>/dev/null; then
        echo "✓ Working"
    else
        echo "✗ Failed"
    fi
}

repair_issues() {
    local auto_fix="${1:-false}"
    
    log "Attempting to repair issues..."
    
    # Check root
    if ! check_root; then
        error "Repair requires root privileges"
        return 1
    fi
    
    # Create backup
    backup_before_troubleshoot
    
    # Check and fix services
    local services=(
        "ultimate-ai-backend"
        "ultimate-ai-celery"
        "nginx"
        "postgresql"
        "redis"
    )
    
    for service in "${services[@]}"; do
        if ! systemctl is-active "$service" &>/dev/null; then
            warning "$service is not running, attempting to start..."
            systemctl start "$service"
            
            # Wait and check
            sleep 2
            if systemctl is-active "$service" &>/dev/null; then
                success "$service started successfully"
            else
                error "Failed to start $service"
                journalctl -u "$service" --no-pager | tail -20
            fi
        fi
    done
    
    # Check disk space
    local disk_usage=$(df / --output=pcent | tail -1 | tr -d '% ')
    if [ "$disk_usage" -gt 90 ]; then
        warning "Disk usage is high ($disk_usage%), cleaning up..."
        
        # Clean docker images
        if command -v docker &>/dev/null; then
            docker system prune -f
        fi
        
        # Clean old logs
        find "$LOG_DIR" -name "*.log" -mtime +7 -delete
        journalctl --vacuum-time=7d
        
        # Clean apt cache
        apt-get clean
    fi
    
    # Check memory
    local mem_usage=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
    if [ "$(echo "$mem_usage > 90" | bc -l)" = "1" ]; then
        warning "Memory usage is high ($mem_usage%)"
        
        # Restart services to free memory
        systemctl restart ultimate-ai-backend
        systemctl restart ultimate-ai-celery
    fi
    
    # Check database connections
    if command -v psql &>/dev/null; then
        local connections=$(psql -h localhost -U postgres -c "SELECT count(*) FROM pg_stat_activity;" -t)
        local max_connections=$(psql -h localhost -U postgres -c "SHOW max_connections;" -t)
        
        if [ "$connections" -gt $((max_connections * 8 / 10)) ]; then
            warning "High database connections ($connections/$max_connections)"
            
            # Kill idle connections
            psql -h localhost -U postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle' AND pid <> pg_backend_pid();" || true
        fi
    fi
    
    success "Repair attempts completed"
}

generate_report() {
    log "Generating troubleshooting report..."
    
    local report_file="/tmp/ultimate-ai-troubleshoot-$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "Ultimate AI System - Troubleshooting Report"
        echo "Generated: $(date)"
        echo "Hostname: $(hostname)"
        echo "=========================================="
        echo ""
        
        # System info
        echo "SYSTEM INFORMATION"
        echo "------------------"
        uname -a
        echo ""
        lsb_release -a 2>/dev/null || cat /etc/os-release
        echo ""
        
        # Service status
        echo "SERVICE STATUS"
        echo "--------------"
        systemctl list-units --type=service --state=failed
        echo ""
        
        # Network
        echo "NETWORK INFORMATION"
        echo "-------------------"
        netstat -tulpn
        echo ""
        
        # Disk
        echo "DISK USAGE"
        echo "----------"
        df -h
        echo ""
        
        # Memory
        echo "MEMORY USAGE"
        echo "------------"
        free -h
        echo ""
        
        # Last errors
        echo "RECENT ERRORS"
        echo "-------------"
        journalctl --since "1 hour ago" --priority=err --no-pager
        echo ""
        
    } > "$report_file"
    
    success "Report generated: $report_file"
    echo "Report contents:"
    cat "$report_file" | tail -50
}

main() {
    local command="$1"
    shift
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    case "$command" in
        diagnose)
            run_diagnosis
            ;;
        logs)
            local service="backend"
            local since="1 hour ago"
            local tail_mode=false
            
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --service)
                        service="$2"
                        shift 2
                        ;;
                    --since)
                        since="$2"
                        shift 2
                        ;;
                    --tail)
                        tail_mode=true
                        shift
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            
            show_logs "$service" "$since" "$tail_mode"
            ;;
        status)
            local component="all"
            
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --component)
                        component="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            
            check_status "$component"
            ;;
        test)
            run_tests
            ;;
        repair)
            local auto_fix=false
            
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --fix)
                        auto_fix=true
                        shift
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            
            repair_issues "$auto_fix"
            ;;
        performance)
            check_performance
            ;;
        security)
            check_security
            ;;
        backup)
            backup_before_troubleshoot
            ;;
        report)
            generate_report
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
