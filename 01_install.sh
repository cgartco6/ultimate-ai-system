#!/bin/bash

# Ultimate AI System - Complete Installation Script
# Version: 2.0.0
# Author: AI System Team

set -e  # Exit on error
set -o pipefail  # Exit on pipeline failure

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

# Variables
INSTALL_DIR="/opt/ultimate-ai-system"
BACKUP_DIR="/var/backups/ultimate-ai"
LOG_DIR="/var/log/ultimate-ai"
CONFIG_DIR="/etc/ultimate-ai"
USER_NAME="ultimate-ai"
GROUP_NAME="ultimate-ai"
ENVIRONMENT="production"  # Default environment

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --environment|-e)
                ENVIRONMENT="$2"
                shift 2
                ;;
            --install-dir|-i)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Ultimate AI System - Installation Script

Usage: $0 [OPTIONS]

Options:
  -e, --environment    Set environment (production, staging, development)
  -i, --install-dir    Set installation directory
  -h, --help          Show this help message

Examples:
  $0 --environment production
  $0 --install-dir /opt/ai-system
EOF
}

# Main installation function
main() {
    log_info "Starting Ultimate AI System Installation"
    log_info "Environment: $ENVIRONMENT"
    log_info "Install Directory: $INSTALL_DIR"
    
    check_root
    parse_args "$@"
    
    # Create installation directory structure
    create_directories
    
    # Install prerequisites
    install_prerequisites
    
    # Setup system user
    setup_system_user
    
    # Install Docker and Docker Compose
    install_docker
    
    # Install Python dependencies
    install_python
    
    # Install Node.js
    install_nodejs
    
    # Setup PostgreSQL
    setup_postgresql
    
    # Setup Redis
    setup_redis
    
    # Setup monitoring stack
    setup_monitoring
    
    # Clone or copy application files
    setup_application
    
    # Configure environment
    configure_environment
    
    # Setup SSL certificates
    setup_ssl
    
    # Configure firewall
    configure_firewall
    
    # Setup systemd services
    setup_systemd
    
    # Setup cron jobs
    setup_cron
    
    # Initialize database
    initialize_database
    
    # Download AI models
    download_ai_models
    
    # Final configuration
    final_configuration
    
    log_success "Installation completed successfully!"
    
    # Show next steps
    show_next_steps
}

# Create directory structure
create_directories() {
    log_info "Creating directory structure..."
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$INSTALL_DIR/scripts"
    mkdir -p "$INSTALL_DIR/configs"
    mkdir -p "$INSTALL_DIR/ssl"
    mkdir -p "$INSTALL_DIR/data"
    mkdir -p "$INSTALL_DIR/data/postgres"
    mkdir -p "$INSTALL_DIR/data/redis"
    mkdir -p "$INSTALL_DIR/data/grafana"
    mkdir -p "$INSTALL_DIR/data/prometheus"
    mkdir -p "$INSTALL_DIR/logs/nginx"
    mkdir -p "$INSTALL_DIR/logs/app"
    mkdir -p "$INSTALL_DIR/logs/celery"
    
    chmod 755 "$INSTALL_DIR"
    chmod 750 "$BACKUP_DIR"
    chmod 755 "$LOG_DIR"
}

# Install system prerequisites
install_prerequisites() {
    log_info "Installing system prerequisites..."
    
    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS"
        exit 1
    fi
    
    case $OS in
        ubuntu|debian)
            apt-get update
            apt-get install -y \
                curl \
                wget \
                git \
                gnupg \
                lsb-release \
                ca-certificates \
                apt-transport-https \
                software-properties-common \
                build-essential \
                python3-pip \
                python3-venv \
                libpq-dev \
                postgresql-client \
                nginx \
                ufw \
                fail2ban \
                certbot \
                python3-certbot-nginx \
                jq \
                htop \
                net-tools \
                telnet \
                dnsutils \
                tree \
                unzip \
                zip \
                bc \
                sysstat \
                iotop \
                iftop \
                nethogs \
                lsof \
                ncdu \
                rsync \
                tar \
                gzip \
                bzip2 \
                pv \
                cron \
                logrotate \
                supervisor \
                haveged
            
            # Add PostgreSQL repo for latest version
            if [ "$OS" = "ubuntu" ]; then
                sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
                wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
                apt-get update
            fi
            ;;
        
        centos|rhel|fedora|amazon)
            yum install -y \
                epel-release \
                yum-utils \
                device-mapper-persistent-data \
                lvm2 \
                curl \
                wget \
                git \
                gcc \
                gcc-c++ \
                make \
                python3-devel \
                postgresql-devel \
                nginx \
                firewalld \
                fail2ban \
                certbot \
                python3-certbot-nginx \
                jq \
                htop \
                net-tools \
                bind-utils \
                tree \
                unzip \
                zip \
                bc \
                sysstat \
                iotop \
                iftop \
                nethogs \
                lsof \
                ncdu \
                rsync \
                tar \
                gzip \
                bzip2 \
                pv \
                cronie \
                logrotate \
                supervisor \
                haveged
            ;;
        
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac
    
    log_success "System prerequisites installed"
}

# Setup system user
setup_system_user() {
    log_info "Setting up system user..."
    
    if ! id "$USER_NAME" &>/dev/null; then
        useradd -r -s /bin/bash -d "$INSTALL_DIR" -m "$USER_NAME"
        log_success "Created user: $USER_NAME"
    fi
    
    if ! getent group "$GROUP_NAME" &>/dev/null; then
        groupadd "$GROUP_NAME"
        log_success "Created group: $GROUP_NAME"
    fi
    
    usermod -aG "$GROUP_NAME" "$USER_NAME"
    usermod -aG docker "$USER_NAME" 2>/dev/null || true
    
    # Set permissions
    chown -R "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR"
    chown -R "$USER_NAME:$GROUP_NAME" "$LOG_DIR"
    chmod -R 750 "$INSTALL_DIR"
    
    log_success "System user configured"
}

# Install Docker and Docker Compose
install_docker() {
    log_info "Installing Docker and Docker Compose..."
    
    # Check if Docker is already installed
    if command -v docker &>/dev/null; then
        log_warning "Docker is already installed"
    else
        # Install Docker
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        
        # Start and enable Docker
        systemctl start docker
        systemctl enable docker
        
        log_success "Docker installed"
    fi
    
    # Check if Docker Compose is installed
    if command -v docker-compose &>/dev/null; then
        log_warning "Docker Compose is already installed"
    else
        # Install Docker Compose v2
        DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d'"' -f4)
        curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        
        # Create symlink
        ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
        
        log_success "Docker Compose installed"
    fi
    
    # Test installations
    docker --version
    docker-compose --version
}

# Install Python and dependencies
install_python() {
    log_info "Installing Python and dependencies..."
    
    # Create Python virtual environment
    sudo -u "$USER_NAME" python3 -m venv "$INSTALL_DIR/venv"
    
    # Install Python packages
    "$INSTALL_DIR/venv/bin/pip" install --upgrade pip setuptools wheel
    
    # Create requirements.txt
    cat > "$INSTALL_DIR/requirements.txt" << 'EOF'
# Core dependencies
fastapi==0.104.1
uvicorn[standard]==0.24.0
gunicorn==21.2.0
python-multipart==0.0.6
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
python-dotenv==1.0.0
pydantic==2.5.0
pydantic-settings==2.1.0
email-validator==2.1.0

# Database
sqlalchemy==2.0.23
alembic==1.12.1
psycopg2-binary==2.9.9
asyncpg==0.29.0
redis==5.0.1
aioredis==2.0.1

# Async & Task Queue
celery==5.3.4
flower==2.0.1
celery-redbeat==2.0.0

# Data processing
pandas==2.1.3
numpy==1.24.3
scikit-learn==1.3.2
scipy==1.11.4

# Machine Learning
tensorflow==2.15.0
torch==2.1.0
transformers==4.36.0
sentence-transformers==2.2.2
langchain==0.0.340
langchain-community==0.0.10
openai==1.3.0
cohere==4.34
anthropic==0.7.7

# Trading & Finance
ccxt==4.1.39
yfinance==0.2.33
alpha-vantage==3.0.1
ta-lib==0.4.28
backtrader==1.9.78.123
pandas-ta==0.3.14b0
vectorbt==0.25.4

# Vector Databases
pinecone-client==2.2.4
qdrant-client==1.6.7
chromadb==0.4.22

# APIs & Web
httpx==0.25.1
websockets==12.0
aiohttp==3.9.1
requests==2.31.0
beautifulsoup4==4.12.2

# Monitoring & Logging
prometheus-client==0.19.0
structlog==23.2.0
loguru==0.7.2
sentry-sdk==1.38.0

# Utils
python-dateutil==2.8.2
pytz==2023.3.post1
tzlocal==5.2
colorama==0.4.6
tqdm==4.66.1
click==8.1.7

# Testing & Development
pytest==7.4.3
pytest-asyncio==0.21.1
pytest-cov==4.1.0
black==23.11.0
flake8==6.1.0
mypy==1.7.1
isort==5.12.0
pre-commit==3.5.0

# Documentation
mkdocs==1.5.3
mkdocs-material==9.4.1
pdoc==13.1.0

# Performance
uvloop==0.19.0
httptools==0.6.0
python-rapidjson==1.10
orjson==3.9.10

# Security
cryptography==41.0.7
bcrypt==4.1.2
argon2-cffi==23.1.0
bandit==1.7.5
safety==2.3.5
EOF
    
    # Install requirements
    "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"
    
    log_success "Python dependencies installed"
}

# Install Node.js and npm
install_nodejs() {
    log_info "Installing Node.js..."
    
    # Check OS
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        # Install Node.js 18
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        apt-get install -y nodejs
        
        # Install global npm packages
        npm install -g npm@latest
        npm install -g yarn
        npm install -g pm2
        npm install -g typescript
        npm install -g @angular/cli
        npm install -g react-scripts
        
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ]; then
        # Install Node.js 18
        curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
        yum install -y nodejs
        
        # Install global npm packages
        npm install -g npm@latest
        npm install -g yarn
        npm install -g pm2
        npm install -g typescript
        npm install -g @angular/cli
        npm install -g react-scripts
    fi
    
    # Verify installation
    node --version
    npm --version
    
    log_success "Node.js installed"
}

# Setup PostgreSQL
setup_postgresql() {
    log_info "Setting up PostgreSQL..."
    
    # Install PostgreSQL
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        apt-get install -y postgresql-15 postgresql-contrib-15 postgresql-client-15
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
        yum install -y postgresql15-server postgresql15-contrib
    fi
    
    # Initialize database
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        systemctl start postgresql
        systemctl enable postgresql
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
        /usr/pgsql-15/bin/postgresql-15-setup initdb
        systemctl start postgresql-15
        systemctl enable postgresql-15
    fi
    
    # Configure PostgreSQL
    configure_postgresql
    
    log_success "PostgreSQL configured"
}

configure_postgresql() {
    # Backup original configs
    cp /etc/postgresql/15/main/postgresql.conf /etc/postgresql/15/main/postgresql.conf.backup 2>/dev/null || true
    cp /etc/postgresql/15/main/pg_hba.conf /etc/postgresql/15/main/pg_hba.conf.backup 2>/dev/null || true
    
    # Optimize PostgreSQL configuration
    cat > /etc/postgresql/15/main/postgresql.conf << 'EOF'
# PostgreSQL Configuration for Ultimate AI System
data_directory = '/var/lib/postgresql/15/main'
hba_file = '/etc/postgresql/15/main/pg_hba.conf'
ident_file = '/etc/postgresql/15/main/pg_ident.conf'

listen_addresses = 'localhost'
port = 5432
max_connections = 200
superuser_reserved_connections = 3

shared_buffers = 2GB
work_mem = 16MB
maintenance_work_mem = 512MB
dynamic_shared_memory_type = posix

max_wal_size = 2GB
min_wal_size = 1GB
checkpoint_completion_target = 0.9
wal_buffers = 16MB

default_statistics_target = 100
random_page_cost = 1.1
effective_cache_size = 6GB

logging_collector = on
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0

datestyle = 'iso, mdy'
timezone = 'UTC'
lc_messages = 'en_US.UTF-8'
lc_monetary = 'en_US.UTF-8'
lc_numeric = 'en_US.UTF-8'
lc_time = 'en_US.UTF-8'
default_text_search_config = 'pg_catalog.english'

# AI System specific
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
pg_stat_statements.max = 10000
track_activity_query_size = 2048
EOF
    
    # Configure authentication
    cat > /etc/postgresql/15/main/pg_hba.conf << 'EOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     md5
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5

# Replication
local   replication     all                                     peer
host    replication     all             127.0.0.1/32            md5
host    replication     all             ::1/128                 md5
EOF
    
    # Create database and user
    sudo -u postgres psql <<EOF
CREATE DATABASE ultimate_ai;
CREATE USER ultimate_ai_user WITH ENCRYPTED PASSWORD '$(openssl rand -base64 32)';
GRANT ALL PRIVILEGES ON DATABASE ultimate_ai TO ultimate_ai_user;
ALTER DATABASE ultimate_ai SET timezone TO 'UTC';
ALTER DATABASE ultimate_ai SET search_path TO public;
\c ultimate_ai
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";
GRANT ALL ON SCHEMA public TO ultimate_ai_user;
EOF
    
    # Restart PostgreSQL
    systemctl restart postgresql
}

# Setup Redis
setup_redis() {
    log_info "Setting up Redis..."
    
    # Install Redis
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        apt-get install -y redis-server
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
        yum install -y redis
    fi
    
    # Configure Redis
    configure_redis
    
    # Enable and start Redis
    systemctl enable redis
    systemctl start redis
    
    log_success "Redis configured"
}

configure_redis() {
    # Backup original config
    cp /etc/redis/redis.conf /etc/redis/redis.conf.backup
    
    # Optimize Redis configuration
    cat > /etc/redis/redis.conf << 'EOF'
# Redis Configuration for Ultimate AI System
bind 127.0.0.1 ::1
protected-mode yes
port 6379
tcp-backlog 511
timeout 0
tcp-keepalive 300

daemonize no
supervised systemd
pidfile /var/run/redis/redis-server.pid
loglevel notice
logfile /var/log/redis/redis-server.log

databases 16
always-show-logo no

save 900 1
save 300 10
save 60 10000

stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /var/lib/redis

replica-serve-stale-data yes
replica-read-only yes
repl-diskless-sync no
repl-diskless-sync-delay 5
repl-disable-tcp-nodelay no
replica-priority 100

requirepass $(openssl rand -base64 32)

maxclients 10000
maxmemory 4gb
maxmemory-policy allkeys-lru
maxmemory-samples 5

appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-load-truncated yes
aof-use-rdb-preamble yes

lua-time-limit 5000

slowlog-log-slower-than 10000
slowlog-max-len 128

latency-monitor-threshold 0

notify-keyspace-events ""

hash-max-ziplist-entries 512
hash-max-ziplist-value 64
list-max-ziplist-size -2
list-compress-depth 0
set-max-intset-entries 512
zset-max-ziplist-entries 128
zset-max-ziplist-value 64
hll-sparse-max-bytes 3000
stream-node-max-bytes 4096
stream-node-max-entries 100

activerehashing yes
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60

hz 10
dynamic-hz yes
aof-rewrite-incremental-fsync yes
rdb-save-incremental-fsync yes
EOF
    
    # Set proper permissions
    chown redis:redis /etc/redis/redis.conf
    chmod 640 /etc/redis/redis.conf
}

# Setup monitoring stack
setup_monitoring() {
    log_info "Setting up monitoring stack..."
    
    # Create directories
    mkdir -p /etc/prometheus
    mkdir -p /var/lib/prometheus
    mkdir -p /etc/grafana/provisioning
    
    # Download and install Prometheus
    PROMETHEUS_VERSION="2.47.2"
    wget "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
    tar xvf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
    cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/
    cp prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/
    cp -r prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles /etc/prometheus/
    cp -r prometheus-${PROMETHEUS_VERSION}.linux-amd64/console_libraries /etc/prometheus/
    rm -rf prometheus-${PROMETHEUS_VERSION}.linux-amd64*
    
    # Create Prometheus configuration
    cat > /etc/prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    monitor: 'ultimate-ai'

rule_files:
  - "alert_rules.yml"

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'postgresql'
    static_configs:
      - targets: ['localhost:9187']

  - job_name: 'redis'
    static_configs:
      - targets: ['localhost:9121']

  - job_name: 'nginx'
    static_configs:
      - targets: ['localhost:9113']

  - job_name: 'ultimate-ai-backend'
    static_configs:
      - targets: ['localhost:8000']
    metrics_path: '/metrics'

  - job_name: 'ultimate-ai-celery'
    static_configs:
      - targets: ['localhost:5555']

  - job_name: 'cadvisor'
    static_configs:
      - targets: ['localhost:8080']

  - job_name: 'blackbox'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
        - http://localhost:3000
        - http://localhost:8000
        - http://localhost:9090
        - http://localhost:3001
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: localhost:9115
EOF
    
    # Create systemd service for Prometheus
    cat > /etc/systemd/system/prometheus.service << EOF
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus/ \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries \
    --web.listen-address=0.0.0.0:9090 \
    --web.external-url=

[Install]
WantedBy=multi-user.target
EOF
    
    # Create Prometheus user
    useradd --no-create-home --shell /bin/false prometheus
    chown -R prometheus:prometheus /etc/prometheus
    chown -R prometheus:prometheus /var/lib/prometheus
    
    # Download and install Node Exporter
    NODE_EXPORTER_VERSION="1.6.1"
    wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
    tar xvf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
    cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
    rm -rf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64*
    
    # Create systemd service for Node Exporter
    cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF
    
    # Create Node Exporter user
    useradd --no-create-home --shell /bin/false node_exporter
    chown node_exporter:node_exporter /usr/local/bin/node_exporter
    
    # Start monitoring services
    systemctl daemon-reload
    systemctl enable prometheus node_exporter
    systemctl start prometheus node_exporter
    
    log_success "Monitoring stack installed"
}

# Setup application files
setup_application() {
    log_info "Setting up application files..."
    
    # Clone repository or copy files
    if [ -d ".git" ]; then
        log_info "Git repository detected, updating..."
        git pull origin main
    else
        log_info "Copying application files..."
        
        # Copy backend
        cp -r backend "$INSTALL_DIR/"
        cp -r frontend "$INSTALL_DIR/"
        cp -r ml_models "$INSTALL_DIR/"
        cp -r scripts "$INSTALL_DIR/"
        cp -r configs "$INSTALL_DIR/"
        cp -r docs "$INSTALL_DIR/"
        cp -r tests "$INSTALL_DIR/"
        
        # Copy configuration files
        cp docker-compose.yml "$INSTALL_DIR/"
        cp docker-compose.prod.yml "$INSTALL_DIR/"
        cp nginx.conf "$INSTALL_DIR/"
        cp .env.example "$INSTALL_DIR/.env"
    fi
    
    # Set permissions
    chown -R "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR"
    chmod -R 750 "$INSTALL_DIR"
    
    log_success "Application files setup complete"
}

# Configure environment
configure_environment() {
    log_info "Configuring environment..."
    
    # Create .env file
    cat > "$INSTALL_DIR/.env" << EOF
# Ultimate AI System Environment Configuration
# Generated: $(date)

# Application
APP_NAME="Ultimate AI System"
APP_ENV=${ENVIRONMENT}
APP_DEBUG=false
APP_URL=https://ai-system.example.com
APP_TIMEZONE=UTC

# Security
APP_KEY=$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -base64 64)
ENCRYPTION_KEY=$(openssl rand -base64 32)

# Database
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=ultimate_ai
DB_USERNAME=ultimate_ai_user
DB_PASSWORD=$(openssl rand -base64 32)

# Redis
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=$(openssl rand -base64 32)
REDIS_CACHE_DB=0
REDIS_QUEUE_DB=1
REDIS_SESSION_DB=2

# Cache
CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis

# Trading APIs
ALPHA_VANTAGE_API_KEY=your_alpha_vantage_key
POLYGON_API_KEY=your_polygon_key
BINANCE_API_KEY=your_binance_key
BINANCE_SECRET_KEY=your_binance_secret
COINBASE_API_KEY=your_coinbase_key
COINBASE_SECRET_KEY=your_coinbase_secret

# AI Services
OPENAI_API_KEY=your_openai_key
ANTHROPIC_API_KEY=your_anthropic_key
COHERE_API_KEY=your_cohere_key
HUGGINGFACE_TOKEN=your_huggingface_token

# Vector Databases
PINECONE_API_KEY=your_pinecone_key
PINECONE_ENVIRONMENT=us-east-1
QDRANT_URL=http://localhost:6333
CHROMA_PERSIST_DIR=/app/data/chroma

# Monitoring
SENTRY_DSN=your_sentry_dsn
LOG_LEVEL=info
METRICS_PORT=9091

# Email
MAIL_MAILER=smtp
MAIL_HOST=smtp.gmail.com
MAIL_PORT=587
MAIL_USERNAME=your_email@gmail.com
MAIL_PASSWORD=your_app_password
MAIL_ENCRYPTION=tls
MAIL_FROM_ADDRESS=noreply@ai-system.com
MAIL_FROM_NAME="Ultimate AI System"

# File Storage
FILESYSTEM_DISK=local
AWS_ACCESS_KEY_ID=your_aws_key
AWS_SECRET_ACCESS_KEY=your_aws_secret
AWS_DEFAULT_REGION=us-east-1
AWS_BUCKET=ultimate-ai-files

# Frontend
NEXT_PUBLIC_API_URL=/api
NEXT_PUBLIC_WS_URL=wss://ai-system.example.com/ws

# Worker
WORKER_CONCURRENCY=4
WORKER_MAX_TASKS_PER_CHILD=1000
WORKER_PREFETCH_MULTIPLIER=4
EOF
    
    # Set secure permissions
    chmod 640 "$INSTALL_DIR/.env"
    chown "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR/.env"
    
    log_success "Environment configured"
}

# Setup SSL certificates
setup_ssl() {
    log_info "Setting up SSL certificates..."
    
    # Check if certbot is installed
    if ! command -v certbot &>/dev/null; then
        log_warning "Certbot not found, installing..."
        apt-get install -y certbot python3-certbot-nginx
    fi
    
    # Create SSL directory
    mkdir -p /etc/ssl/ultimate-ai
    chmod 750 /etc/ssl/ultimate-ai
    
    # Generate self-signed certificate for development
    if [ "$ENVIRONMENT" = "development" ]; then
        log_info "Generating self-signed SSL certificate..."
        
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /etc/ssl/ultimate-ai/private.key \
            -out /etc/ssl/ultimate-ai/certificate.crt \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=ai-system.local"
        
        chmod 600 /etc/ssl/ultimate-ai/private.key
        chmod 644 /etc/ssl/ultimate-ai/certificate.crt
        
    else
        log_info "Please run certbot after DNS is configured:"
        echo "sudo certbot --nginx -d ai-system.example.com"
    fi
    
    log_success "SSL setup complete"
}

# Configure firewall
configure_firewall() {
    log_info "Configuring firewall..."
    
    # Check if UFW is available
    if command -v ufw &>/dev/null; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        
        # Allow SSH
        ufw allow 22/tcp
        
        # Allow HTTP/HTTPS
        ufw allow 80/tcp
        ufw allow 443/tcp
        
        # Allow monitoring ports
        ufw allow 9090/tcp  # Prometheus
        ufw allow 3001/tcp  # Grafana
        ufw allow 9100/tcp  # Node Exporter
        
        # Enable firewall
        ufw --force enable
        
    elif command -v firewall-cmd &>/dev/null; then
        # For CentOS/RHEL
        systemctl start firewalld
        systemctl enable firewalld
        
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --permanent --add-port=9090/tcp
        firewall-cmd --permanent --add-port=3001/tcp
        firewall-cmd --permanent --add-port=9100/tcp
        
        firewall-cmd --reload
        
    else
        log_warning "No supported firewall found"
    fi
    
    log_success "Firewall configured"
}

# Setup systemd services
setup_systemd() {
    log_info "Setting up systemd services..."
    
    # Backend service
    cat > /etc/systemd/system/ultimate-ai-backend.service << EOF
[Unit]
Description=Ultimate AI System Backend
After=network.target postgresql.service redis.service
Requires=postgresql.service redis.service

[Service]
Type=simple
User=${USER_NAME}
Group=${GROUP_NAME}
WorkingDirectory=${INSTALL_DIR}/backend
Environment="PATH=${INSTALL_DIR}/venv/bin:/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=${INSTALL_DIR}/.env

ExecStart=${INSTALL_DIR}/venv/bin/gunicorn \
    --worker-class uvicorn.workers.UvicornWorker \
    --workers 4 \
    --bind 0.0.0.0:8000 \
    --timeout 120 \
    --keepalive 5 \
    --max-requests 10000 \
    --max-requests-jitter 1000 \
    --log-level info \
    --access-logfile ${LOG_DIR}/backend-access.log \
    --error-logfile ${LOG_DIR}/backend-error.log \
    app.main:app

Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=ultimate-ai-backend

# Security
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${LOG_DIR} ${INSTALL_DIR}/data
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes

# Resource limits
LimitNOFILE=65536
LimitNPROC=65536
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    # Celery worker service
    cat > /etc/systemd/system/ultimate-ai-celery.service << EOF
[Unit]
Description=Ultimate AI System Celery Worker
After=network.target redis.service
Requires=redis.service

[Service]
Type=simple
User=${USER_NAME}
Group=${GROUP_NAME}
WorkingDirectory=${INSTALL_DIR}/backend
Environment="PATH=${INSTALL_DIR}/venv/bin:/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=${INSTALL_DIR}/.env

ExecStart=${INSTALL_DIR}/venv/bin/celery \
    -A app.tasks.celery_app worker \
    --loglevel=info \
    --concurrency=4 \
    --max-tasks-per-child=1000 \
    --prefetch-multiplier=4 \
    --queues=default,high_priority,low_priority

Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=ultimate-ai-celery

# Security
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${LOG_DIR} ${INSTALL_DIR}/data
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
    
    # Celery beat service
    cat > /etc/systemd/system/ultimate-ai-celery-beat.service << EOF
[Unit]
Description=Ultimate AI System Celery Beat
After=network.target redis.service
Requires=redis.service

[Service]
Type=simple
User=${USER_NAME}
Group=${GROUP_NAME}
WorkingDirectory=${INSTALL_DIR}/backend
Environment="PATH=${INSTALL_DIR}/venv/bin:/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=${INSTALL_DIR}/.env

ExecStart=${INSTALL_DIR}/venv/bin/celery \
    -A app.tasks.celery_app beat \
    --loglevel=info \
    --scheduler=redbeat.RedBeatScheduler

Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=ultimate-ai-celery-beat

# Security
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${LOG_DIR} ${INSTALL_DIR}/data
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
    
    # Flower monitoring service
    cat > /etc/systemd/system/ultimate-ai-flower.service << EOF
[Unit]
Description=Ultimate AI System Flower Monitor
After=network.target redis.service
Requires=redis.service

[Service]
Type=simple
User=${USER_NAME}
Group=${GROUP_NAME}
WorkingDirectory=${INSTALL_DIR}/backend
Environment="PATH=${INSTALL_DIR}/venv/bin:/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=${INSTALL_DIR}/.env

ExecStart=${INSTALL_DIR}/venv/bin/celery \
    -A app.tasks.celery_app flower \
    --port=5555 \
    --basic_auth=admin:$(openssl rand -base64 16) \
    --url_prefix=flower

Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=ultimate-ai-flower

# Security
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${LOG_DIR} ${INSTALL_DIR}/data
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
    
    # Frontend service (using PM2)
    cat > /etc/systemd/system/ultimate-ai-frontend.service << EOF
[Unit]
Description=Ultimate AI System Frontend
After=network.target

[Service]
Type=simple
User=${USER_NAME}
Group=${GROUP_NAME}
WorkingDirectory=${INSTALL_DIR}/frontend
Environment="PATH=/usr/bin:/bin:/usr/local/bin"
Environment="NODE_ENV=${ENVIRONMENT}"

ExecStart=/usr/bin/npm run start
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=ultimate-ai-frontend

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable services
    systemctl enable ultimate-ai-backend
    systemctl enable ultimate-ai-celery
    systemctl enable ultimate-ai-celery-beat
    systemctl enable ultimate-ai-flower
    
    log_success "Systemd services configured"
}

# Setup cron jobs
setup_cron() {
    log_info "Setting up cron jobs..."
    
    # Create cron directory
    mkdir -p /etc/cron.d/ultimate-ai
    
    # Database backup cron
    cat > /etc/cron.d/ultimate-ai-backup << EOF
# Ultimate AI System - Database Backup
0 2 * * * ${USER_NAME} ${INSTALL_DIR}/scripts/utils/database_backup.sh >> ${LOG_DIR}/backup.log 2>&1

# Log rotation
0 3 * * * ${USER_NAME} ${INSTALL_DIR}/scripts/utils/logs_cleanup.sh >> ${LOG_DIR}/cleanup.log 2>&1

# SSL certificate renewal check
0 5 * * * root certbot renew --quiet --post-hook "systemctl reload nginx"

# Monitoring data cleanup
0 4 * * 0 ${USER_NAME} ${INSTALL_DIR}/scripts/utils/cleanup_monitoring.sh >> ${LOG_DIR}/monitoring-cleanup.log 2>&1
EOF
    
    # Set permissions
    chmod 644 /etc/cron.d/ultimate-ai-backup
    
    log_success "Cron jobs configured"
}

# Initialize database
initialize_database() {
    log_info "Initializing database..."
    
    # Run migrations as application user
    sudo -u "$USER_NAME" bash -c "cd $INSTALL_DIR/backend && $INSTALL_DIR/venv/bin/alembic upgrade head"
    
    # Load initial data
    sudo -u "$USER_NAME" bash -c "cd $INSTALL_DIR/backend && $INSTALL_DIR/venv/bin/python -m app.utils.seed_data"
    
    log_success "Database initialized"
}

# Download AI models
download_ai_models() {
    log_info "Downloading AI models..."
    
    # Create models directory
    mkdir -p "$INSTALL_DIR/ml_models"
    
    # Download trading models
    sudo -u "$USER_NAME" bash -c "cd $INSTALL_DIR && python3 -m app.ai_agents.download_models"
    
    log_success "AI models downloaded"
}

# Final configuration
final_configuration() {
    log_info "Finalizing configuration..."
    
    # Create health check script
    cat > "$INSTALL_DIR/scripts/health_check.sh" << 'EOF'
#!/bin/bash

# Health check script for Ultimate AI System

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_service() {
    local service=$1
    if systemctl is-active --quiet "$service"; then
        echo -e "${GREEN}✓${NC} $service is running"
        return 0
    else
        echo -e "${RED}✗${NC} $service is not running"
        return 1
    fi
}

check_port() {
    local port=$1
    if netstat -tuln | grep -q ":$port "; then
        echo -e "${GREEN}✓${NC} Port $port is listening"
        return 0
    else
        echo -e "${RED}✗${NC} Port $port is not listening"
        return 1
    fi
}

check_database() {
    if pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} PostgreSQL is accessible"
        return 0
    else
        echo -e "${RED}✗${NC} PostgreSQL is not accessible"
        return 1
    fi
}

check_redis() {
    if redis-cli ping | grep -q PONG; then
        echo -e "${GREEN}✓${NC} Redis is accessible"
        return 0
    else
        echo -e "${RED}✗${NC} Redis is not accessible"
        return 1
    fi
}

echo "=== Ultimate AI System Health Check ==="
echo "Time: $(date)"
echo ""

# Check services
echo "Checking services..."
check_service postgresql
check_service redis
check_service ultimate-ai-backend
check_service ultimate-ai-celery
check_service nginx
check_service prometheus
check_service node_exporter

echo ""

# Check ports
echo "Checking ports..."
check_port 80
check_port 443
check_port 8000
check_port 5432
check_port 6379
check_port 9090
check_port 3001

echo ""

# Check databases
echo "Checking databases..."
check_database
check_redis

echo ""

# Disk space
echo "Checking disk space..."
df -h / | tail -1

echo ""

# Memory usage
echo "Checking memory usage..."
free -h

echo ""
echo "=== Health Check Complete ==="
EOF
    
    chmod +x "$INSTALL_DIR/scripts/health_check.sh"
    
    # Create update script
    cat > "$INSTALL_DIR/scripts/update_system.sh" << 'EOF'
#!/bin/bash

# Update script for Ultimate AI System

set -e

echo "Updating Ultimate AI System..."

# Update system packages
apt-get update
apt-get upgrade -y

# Update Python packages
cd /opt/ultimate-ai-system/backend
../venv/bin/pip install --upgrade -r requirements.txt

# Update Node.js packages
cd /opt/ultimate-ai-system/frontend
npm update
npm audit fix

# Restart services
systemctl restart ultimate-ai-backend
systemctl restart ultimate-ai-celery
systemctl restart ultimate-ai-frontend

echo "Update complete!"
EOF
    
    chmod +x "$INSTALL_DIR/scripts/update_system.sh"
    
    log_success "Final configuration complete"
}

# Show next steps
show_next_steps() {
    cat << EOF

===============================================================================
🎉 ULTIMATE AI SYSTEM INSTALLATION COMPLETE!
===============================================================================

Your system has been successfully installed!

📁 Installation Directory: $INSTALL_DIR
👤 System User: $USER_NAME
🌐 Environment: $ENVIRONMENT

===============================================================================
NEXT STEPS:
===============================================================================

1. CONFIGURE DOMAIN AND SSL:
   - Update your DNS to point to this server
   - Run SSL certificate setup:
     sudo certbot --nginx -d your-domain.com

2. START THE APPLICATION:
   sudo systemctl start ultimate-ai-backend
   sudo systemctl start ultimate-ai-celery
   sudo systemctl start ultimate-ai-frontend
   sudo systemctl start nginx

3. ACCESS THE SYSTEM:
   - Frontend: https://your-domain.com
   - Backend API: https://your-domain.com/api
   - API Documentation: https://your-domain.com/docs
   - Monitoring: https://your-domain.com:3001
   - Flower (Celery Monitoring): https://your-domain.com:5555

4. DEFAULT CREDENTIALS:
   - Admin Panel: admin / $(openssl rand -base64 12 | head -c 16)
   - PostgreSQL: ultimate_ai_user / $(grep DB_PASSWORD $INSTALL_DIR/.env | cut -d= -f2)
   - Redis: password / $(grep REDIS_PASSWORD $INSTALL_DIR/.env | cut -d= -f2)

5. IMPORTANT FILES:
   - Configuration: $INSTALL_DIR/.env
   - Logs: $LOG_DIR/
   - Backups: $BACKUP_DIR/
   - SSL Certificates: /etc/ssl/ultimate-ai/

6. MONITORING:
   - Prometheus: http://localhost:9090
   - Grafana: http://localhost:3001 (admin/admin)
   - System Health Check: $INSTALL_DIR/scripts/health_check.sh

7. MAINTENANCE SCRIPTS:
   - Backup Database: $INSTALL_DIR/scripts/utils/database_backup.sh
   - Update System: $INSTALL_DIR/scripts/update_system.sh
   - Health Check: $INSTALL_DIR/scripts/health_check.sh

===============================================================================
SECURITY NOTES:
===============================================================================

1. CHANGE DEFAULT PASSWORDS immediately!
2. Configure firewall rules for your specific needs
3. Set up proper backup strategy
4. Monitor system logs regularly
5. Keep system updated with security patches

===============================================================================
SUPPORT:
===============================================================================

For issues and support, check:
- Documentation: $INSTALL_DIR/docs/
- Logs: $LOG_DIR/
- GitHub Issues: https://github.com/your-repo/issues

===============================================================================
EOF
}

# Run main function
main "$@"
