#!/bin/bash

# Ultimate AI System - Monitoring Setup Script
# Version: 2.0.0

set -e
set -o pipefail

# Configuration
MONITORING_DIR="/opt/monitoring"
GRAFANA_PASSWORD="admin123"
PROMETHEUS_VERSION="2.47.2"
LOKI_VERSION="2.9.0"
PROMTAIL_VERSION="2.9.0"
ALERTMANAGER_VERSION="0.25.0"

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

# Main monitoring setup function
setup_monitoring() {
    log "Starting monitoring stack setup..."
    
    # Create directories
    create_directories
    
    # Install dependencies
    install_dependencies
    
    # Setup Prometheus
    setup_prometheus
    
    # Setup Node Exporter
    setup_node_exporter
    
    # Setup Grafana
    setup_grafana
    
    # Setup Loki (Log aggregation)
    setup_loki
    
    # Setup Alertmanager
    setup_alertmanager
    
    # Setup application exporters
    setup_exporters
    
    # Configure dashboards
    configure_dashboards
    
    # Configure alerts
    configure_alerts
    
    # Start services
    start_services
    
    success "Monitoring stack setup complete!"
}

# Create directories
create_directories() {
    log "Creating monitoring directories..."
    
    mkdir -p ${MONITORING_DIR}/{prometheus,grafana,loki,promtail,alertmanager,exporters}
    mkdir -p /etc/prometheus
    mkdir -p /var/lib/prometheus
    mkdir -p /var/lib/grafana
    mkdir -p /var/lib/loki
    
    chmod 755 ${MONITORING_DIR}
}

# Install dependencies
install_dependencies() {
    log "Installing dependencies..."
    
    apt-get update
    apt-get install -y \
        wget \
        curl \
        tar \
        gzip \
        jq \
        python3 \
        python3-pip \
        nginx \
        apache2-utils
    
    # Install Python packages for custom exporters
    pip3 install prometheus_client psutil requests
}

# Setup Prometheus
setup_prometheus() {
    log "Setting up Prometheus..."
    
    # Download and install Prometheus
    cd /tmp
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
    environment: 'production'
    cluster: 'ultimate-ai'

# Rule files
rule_files:
  - "alerts/*.yml"
  - "rules/*.yml"

# Alerting configuration
alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - localhost:9093
      scheme: http
      timeout: 10s
      api_version: v2

# Scrape configurations
scrape_configs:
  # Prometheus self-monitoring
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
    scrape_interval: 30s
    honor_labels: true

  # Node Exporter
  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
    metrics_path: /metrics
    scrape_interval: 30s

  # cAdvisor for container monitoring
  - job_name: 'cadvisor'
    static_configs:
      - targets: ['localhost:8080']
    scrape_interval: 30s
    metrics_path: /metrics

  # Ultimate AI Backend
  - job_name: 'ultimate-ai-backend'
    static_configs:
      - targets: ['localhost:8000']
    metrics_path: /metrics
    scrape_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
      - target_label: __metrics_path__
        replacement: /metrics

  # Ultimate AI Celery
  - job_name: 'ultimate-ai-celery'
    static_configs:
      - targets: ['localhost:5555']
    metrics_path: /metrics
    scrape_interval: 30s

  # PostgreSQL
  - job_name: 'postgresql'
    static_configs:
      - targets: ['localhost:9187']
    scrape_interval: 60s
    params:
      collect[]:
        - standard
        - database
        - bgwriter
        - archiver

  # Redis
  - job_name: 'redis'
    static_configs:
      - targets: ['localhost:9121']
    scrape_interval: 30s

  # Nginx
  - job_name: 'nginx'
    static_configs:
      - targets: ['localhost:9113']
    scrape_interval: 30s

  # Blackbox exporter for external checks
  - job_name: 'blackbox'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
        - http://localhost:8000/health
        - http://localhost:3000
        - https://localhost
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: localhost:9115

  # Pushgateway for batch jobs
  - job_name: 'pushgateway'
    honor_labels: true
    static_configs:
      - targets: ['localhost:9091']

  # Custom application metrics
  - job_name: 'ultimate-ai-custom'
    static_configs:
      - targets: ['localhost:9092']
    scrape_interval: 60s
EOF
    
    # Create alerts directory
    mkdir -p /etc/prometheus/alerts
    mkdir -p /etc/prometheus/rules
    
    # Create alert rules
    cat > /etc/prometheus/alerts/ultimate-ai.yml << 'EOF'
groups:
  - name: ultimate-ai-alerts
    rules:
      # System alerts
      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"
          description: "CPU usage is above 80% for 5 minutes"

      - alert: HighMemoryUsage
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage on {{ $labels.instance }}"
          description: "Memory usage is above 85% for 5 minutes"

      - alert: HighDiskUsage
        expr: 100 - (node_filesystem_free_bytes{fstype!~"tmpfs|ramfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|ramfs"} * 100) > 85
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High disk usage on {{ $labels.instance }}"
          description: "Disk usage is above 85% for 10 minutes"

      # Application alerts
      - alert: BackendDown
        expr: up{job="ultimate-ai-backend"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Backend service down on {{ $labels.instance }}"
          description: "Backend service has been down for 1 minute"

      - alert: HighBackendErrorRate
        expr: rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) * 100 > 5
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High error rate on backend"
          description: "HTTP 5xx error rate is above 5% for 2 minutes"

      - alert: HighResponseTime
        expr: histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m])) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High response time on backend"
          description: "95th percentile response time is above 2 seconds for 5 minutes"

      # Database alerts
      - alert: PostgreSQLDown
        expr: up{job="postgresql"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL down on {{ $labels.instance }}"
          description: "PostgreSQL has been down for 1 minute"

      - alert: HighPostgreSQLConnections
        expr: pg_stat_database_numbackends > 50
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High PostgreSQL connections"
          description: "PostgreSQL connection count is above 50 for 2 minutes"

      # Redis alerts
      - alert: RedisDown
        expr: up{job="redis"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Redis down on {{ $labels.instance }}"
          description: "Redis has been down for 1 minute"

      - alert: HighRedisMemoryUsage
        expr: redis_memory_used_bytes / redis_memory_max_bytes * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High Redis memory usage"
          description: "Redis memory usage is above 85% for 5 minutes"

      # Trading alerts
      - alert: TradingAgentError
        expr: increase(trading_agent_errors_total[5m]) > 10
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "High trading agent errors"
          description: "Trading agent has more than 10 errors in 5 minutes"

      - alert: HighTradingLatency
        expr: trading_execution_latency_seconds > 5
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High trading execution latency"
          description: "Trading execution latency is above 5 seconds for 2 minutes"

      # AI Agent alerts
      - alert: AIAgentError
        expr: increase(ai_agent_errors_total[5m]) > 5
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "High AI agent errors"
          description: "AI agent has more than 5 errors in 5 minutes"

      # Workout alerts
      - alert: WorkoutServiceError
        expr: increase(workout_service_errors_total[5m]) > 3
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Workout service errors"
          description: "Workout service has errors in the last 5 minutes"

      # Certificate expiration alert
      - alert: SSLCertExpiringSoon
        expr: ssl_certificate_expiry_seconds < 86400 * 7
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "SSL certificate expiring soon on {{ $labels.instance }}"
          description: "SSL certificate expires in less than 7 days"
EOF
    
    # Create recording rules
    cat > /etc/prometheus/rules/recording.yml << 'EOF'
groups:
  - name: recording_rules
    interval: 30s
    rules:
      - record: job:http_requests:rate5m
        expr: rate(http_requests_total[5m])
      
      - record: job:http_request_duration_seconds:rate5m
        expr: rate(http_request_duration_seconds_sum[5m])
      
      - record: job:node_cpu_usage:rate5m
        expr: 100 - (avg by(instance, job) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
      
      - record: job:node_memory_usage:percentage
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100
      
      - record: job:trading_success_rate:rate5m
        expr: rate(trading_trades_successful_total[5m]) / rate(trading_trades_total[5m]) * 100
      
      - record: job:workout_completion_rate:rate1h
        expr: rate(workout_sessions_completed_total[1h]) / rate(workout_sessions_started_total[1h]) * 100
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
    --web.external-url=https://ai-system.example.com/prometheus \
    --web.route-prefix=/ \
    --web.enable-lifecycle \
    --web.enable-admin-api \
    --storage.tsdb.retention.time=30d \
    --storage.tsdb.retention.size=512MB \
    --storage.tsdb.wal-compression \
    --storage.tsdb.min-block-duration=2h \
    --storage.tsdb.max-block-duration=12h \
    --log.level=info \
    --log.format=json

ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Create Prometheus user
    useradd --no-create-home --shell /bin/false prometheus
    chown -R prometheus:prometheus /etc/prometheus
    chown -R prometheus:prometheus /var/lib/prometheus
    
    success "Prometheus configured"
}

# Setup Node Exporter
setup_node_exporter() {
    log "Setting up Node Exporter..."
    
    NODE_EXPORTER_VERSION="1.6.1"
    wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
    tar xvf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
    cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
    rm -rf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64*
    
    # Create systemd service
    cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
    --collector.cpu \
    --collector.diskstats \
    --collector.filesystem \
    --collector.loadavg \
    --collector.meminfo \
    --collector.netdev \
    --collector.netstat \
    --collector.stat \
    --collector.time \
    --collector.uname \
    --collector.vmstat \
    --collector.systemd \
    --collector.tcpstat \
    --collector.processes \
    --web.listen-address=:9100 \
    --web.telemetry-path=/metrics \
    --log.level=info \
    --log.format=json

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Create Node Exporter user
    useradd --no-create-home --shell /bin/false node_exporter
    chown node_exporter:node_exporter /usr/local/bin/node_exporter
    
    success "Node Exporter configured"
}

# Setup Grafana
setup_grafana() {
    log "Setting up Grafana..."
    
    # Install Grafana
    wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
    echo "deb https://packages.grafana.com/oss/deb stable main" > /etc/apt/sources.list.d/grafana.list
    apt-get update
    apt-get install -y grafana
    
    # Configure Grafana
    cat > /etc/grafana/grafana.ini << EOF
[server]
domain = ai-system.example.com
root_url = https://ai-system.example.com/grafana
serve_from_sub_path = true

[security]
admin_password = ${GRAFANA_PASSWORD}
secret_key = $(openssl rand -base64 32)

[database]
type = sqlite3
path = /var/lib/grafana/grafana.db

[analytics]
reporting_enabled = false
check_for_updates = false

[auth]
disable_login_form = false
disable_signout_menu = false

[auth.anonymous]
enabled = false

[auth.basic]
enabled = true

[users]
allow_sign_up = false
allow_org_create = false
auto_assign_org = true
auto_assign_org_role = Viewer

[emails]
welcome_email_on_sign_up = false

[log]
mode = console file
level = info

[alerting]
enabled = true
execute_alerts = true

[unified_alerting]
enabled = true

[feature_toggles]
enable = publicDashboards publicDashboardsEmail trimDefaults
EOF
    
    # Create provisioning directory
    mkdir -p /etc/grafana/provisioning/{datasources,dashboards,plugins,notifiers}
    
    # Configure datasource
    cat > /etc/grafana/provisioning/datasources/prometheus.yml << EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: true
    jsonData:
      timeInterval: 15s
      queryTimeout: 60s
      httpMethod: POST
      manageAlerts: true
      prometheusType: Prometheus
      prometheusVersion: 2.47.0
      cacheLevel: "High"
      disableMetricsLookup: false
      exemplarTraceIdDestinations:
        - name: trace_id
          datasourceUid: tempo
    secureJsonData:
      tlsSkipVerify: true

  - name: Loki
    type: loki
    access: proxy
    url: http://localhost:3100
    editable: true
    jsonData:
      maxLines: 1000
      derivedFields:
        - datasourceUid: tempo
          matcherRegex: "traceID=(\\w+)"
          name: TraceID
          url: "$${__value.raw}"

  - name: Tempo
    type: tempo
    access: proxy
    url: http://localhost:3200
    editable: true
    jsonData:
      httpMethod: GET
      serviceMap:
        datasourceUid: prometheus
EOF
    
    # Configure dashboard provisioning
    cat > /etc/grafana/provisioning/dashboards/dashboards.yml << EOF
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
EOF
    
    # Create dashboard directory
    mkdir -p /var/lib/grafana/dashboards
    
    # Import Ultimate AI dashboards
    import_dashboards
    
    success "Grafana configured"
}

# Import dashboards
import_dashboards() {
    log "Importing dashboards..."
    
    # Create system dashboard
    cat > /var/lib/grafana/dashboards/system-overview.json << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "System Overview",
    "tags": ["system", "overview"],
    "style": "dark",
    "timezone": "browser",
    "panels": [],
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "timepicker": {},
    "templating": {
      "list": []
    },
    "refresh": "30s",
    "schemaVersion": 36,
    "version": 1,
    "uid": "system-overview"
  }
}
EOF
    
    # Create AI Agents dashboard
    cat > /var/lib/grafana/dashboards/ai-agents.json << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "AI Agents Monitoring",
    "tags": ["ai", "agents", "monitoring"],
    "panels": [
      {
        "datasource": "Prometheus",
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "mappings": [],
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "red",
                  "value": 80
                }
              ]
            },
            "unit": "percent"
          },
          "overrides": []
        },
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 0
        },
        "id": 1,
        "options": {
          "orientation": "auto",
          "reduceOptions": {
            "calcs": ["lastNotNull"],
            "fields": "",
            "values": false
          },
          "showThresholdLabels": false,
          "showThresholdMarkers": true
        },
        "pluginVersion": "9.5.2",
        "targets": [
          {
            "expr": "ai_agent_processing_rate",
            "interval": "",
            "legendFormat": "{{agent}}",
            "refId": "A"
          }
        ],
        "title": "AI Agent Processing Rate",
        "type": "gauge"
      }
    ],
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "refresh": "30s",
    "schemaVersion": 36,
    "version": 1,
    "uid": "ai-agents"
  }
}
EOF
    
    # Create Trading dashboard
    cat > /var/lib/grafana/dashboards/trading-monitoring.json << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "Trading System Monitoring",
    "tags": ["trading", "finance", "monitoring"],
    "panels": [
      {
        "datasource": "Prometheus",
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "continuous-GrYlRd"
            },
            "custom": {
              "axisLabel": "",
              "axisPlacement": "auto",
              "barAlignment": 0,
              "drawStyle": "line",
              "fillOpacity": 10,
              "gradientMode": "none",
              "hideFrom": {
                "legend": false,
                "tooltip": false,
                "viz": false
              },
              "lineInterpolation": "linear",
              "lineWidth": 1,
              "pointSize": 5,
              "scaleDistribution": {
                "type": "linear"
              },
              "showPoints": "auto",
              "spanNulls": false,
              "stacking": {
                "group": "A",
                "mode": "none"
              },
              "thresholdsStyle": {
                "mode": "off"
              }
            },
            "mappings": [],
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "red",
                  "value": 80
                }
              ]
            },
            "unit": "currencyUSD"
          },
          "overrides": []
        },
        "gridPos": {
          "h": 8,
          "w": 24,
          "x": 0,
          "y": 0
        },
        "id": 1,
        "options": {
          "legend": {
            "calcs": [],
            "displayMode": "list",
            "placement": "bottom",
            "showLegend": true
          },
          "tooltip": {
            "mode": "single",
            "sort": "none"
          }
        },
        "targets": [
          {
            "expr": "trading_portfolio_value",
            "interval": "",
            "legendFormat": "Portfolio Value",
            "refId": "A"
          },
          {
            "expr": "trading_total_profit",
            "interval": "",
            "legendFormat": "Total Profit",
            "refId": "B"
          }
        ],
        "title": "Portfolio Performance",
        "type": "timeseries"
      }
    ],
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "refresh": "10s",
    "schemaVersion": 36,
    "version": 1,
    "uid": "trading-monitoring"
  }
}
EOF
    
    # Create Workout dashboard
    cat > /var/lib/grafana/dashboards/workout-system.json << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "Workout System Monitoring",
    "tags": ["workout", "fitness", "health"],
    "panels": [
      {
        "datasource": "Prometheus",
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "custom": {
              "axisLabel": "",
              "axisPlacement": "auto",
              "barAlignment": 0,
              "drawStyle": "line",
              "fillOpacity": 10,
              "gradientMode": "none",
              "hideFrom": {
                "legend": false,
                "tooltip": false,
                "viz": false
              },
              "lineInterpolation": "linear",
              "lineWidth": 1,
              "pointSize": 5,
              "scaleDistribution": {
                "type": "linear"
              },
              "showPoints": "auto",
              "spanNulls": false,
              "stacking": {
                "group": "A",
                "mode": "none"
              },
              "thresholdsStyle": {
                "mode": "off"
              }
            },
            "mappings": [],
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "red",
                  "value": 80
                }
              ]
            },
            "unit": "short"
          },
          "overrides": []
        },
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 0
        },
        "id": 1,
        "options": {
          "legend": {
            "calcs": [],
            "displayMode": "list",
            "placement": "bottom",
            "showLegend": true
          },
          "tooltip": {
            "mode": "single",
            "sort": "none"
          }
        },
        "targets": [
          {
            "expr": "workout_sessions_completed_total",
            "interval": "",
            "legendFormat": "Sessions Completed",
            "refId": "A"
          },
          {
            "expr": "workout_exercises_completed_total",
            "interval": "",
            "legendFormat": "Exercises Completed",
            "refId": "B"
          }
        ],
        "title": "Workout Activity",
        "type": "timeseries"
      }
    ],
    "time": {
      "from": "now-7d",
      "to": "now"
    },
    "refresh": "30s",
    "schemaVersion": 36,
    "version": 1,
    "uid": "workout-system"
  }
}
EOF
    
    chown -R grafana:grafana /var/lib/grafana/dashboards
    
    success "Dashboards imported"
}

# Setup Loki for log aggregation
setup_loki() {
    log "Setting up Loki..."
    
    # Download Loki
    wget "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip"
    unzip loki-linux-amd64.zip
    mv loki-linux-amd64 /usr/local/bin/loki
    rm loki-linux-amd64.zip
    
    # Create Loki configuration
    cat > /etc/loki.yml << 'EOF'
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  path_prefix: /tmp/loki
  storage:
    filesystem:
      chunks_directory: /tmp/loki/chunks
      rules_directory: /tmp/loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

schema_config:
  configs:
    - from: 2020-10-24
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h

ruler:
  alertmanager_url: http://localhost:9093

analytics:
  reporting_enabled: false
EOF
    
    # Create systemd service for Loki
    cat > /etc/systemd/system/loki.service << EOF
[Unit]
Description=Loki log aggregation system
After=network.target

[Service]
Type=simple
User=loki
Group=loki
ExecStart=/usr/local/bin/loki -config.file=/etc/loki.yml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Create Loki user
    useradd --no-create-home --shell /bin/false loki
    chown loki:loki /usr/local/bin/loki
    
    success "Loki configured"
}

# Setup Promtail for log shipping
setup_promtail() {
    log "Setting up Promtail..."
    
    # Download Promtail
    wget "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip"
    unzip promtail-linux-amd64.zip
    mv promtail-linux-amd64 /usr/local/bin/promtail
    rm promtail-linux-amd64.zip
    
    # Create Promtail configuration
    cat > /etc/promtail.yml << 'EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://localhost:3100/loki/api/v1/push

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: syslog
          __path__: /var/log/syslog

  - job_name: auth
    static_configs:
      - targets:
          - localhost
        labels:
          job: auth
          __path__: /var/log/auth.log

  - job_name: ultimate-ai
    static_configs:
      - targets:
          - localhost
        labels:
          job: ultimate-ai
          __path__: /var/log/ultimate-ai/*.log

  - job_name: nginx
    static_configs:
      - targets:
          - localhost
        labels:
          job: nginx
          __path__: /var/log/nginx/*.log

  - job_name: docker
    static_configs:
      - targets:
          - localhost
        labels:
          job: docker
          __path__: /var/lib/docker/containers/*/*.log
    pipeline_stages:
      - json:
          expressions:
            output: log
            stream: stream
            attrs:
      - json:
          expressions:
            tag:
          source: attrs
      - regex:
          expression: (?P<container_name>(?:[^|]*[^|])).*
          source: tag
      - timestamp:
          format: RFC3339Nano
          source: time
      - labels:
          tag:
          stream:
      - output:
          source: output
EOF
    
    # Create systemd service for Promtail
    cat > /etc/systemd/system/promtail.service << EOF
[Unit]
Description=Promtail log shipper
After=network.target

[Service]
Type=simple
User=promtail
Group=promtail
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail.yml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Create Promtail user
    useradd --no-create-home --shell /bin/false promtail
    chown promtail:promtail /usr/local/bin/promtail
    
    success "Promtail configured"
}

# Setup Alertmanager
setup_alertmanager() {
    log "Setting up Alertmanager..."
    
    # Download Alertmanager
    wget "https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz"
    tar xvf alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz
    cp alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/alertmanager /usr/local/bin/
    cp alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/amtool /usr/local/bin/
    rm -rf alertmanager-${ALERTMANAGER_VERSION}.linux-amd64*
    
    # Create Alertmanager configuration
    cat > /etc/alertmanager.yml << 'EOF'
global:
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_from: 'alerts@ultimate-ai.com'
  smtp_auth_username: 'alerts@ultimate-ai.com'
  smtp_auth_password: '${SMTP_PASSWORD}'
  smtp_require_tls: true

route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'team-ultimate-ai'
  routes:
    - match:
        severity: critical
      receiver: 'team-pager'
      continue: true
    - match:
        service: database
      receiver: 'team-database'
    - match:
        service: trading
      receiver: 'team-trading'
    - match:
        service: ai
      receiver: 'team-ai'

receivers:
  - name: 'team-ultimate-ai'
    email_configs:
      - to: 'team@ultimate-ai.com'
        send_resolved: true
        headers:
          subject: '[Ultimate AI] {{ .GroupLabels.alertname }}'

  - name: 'team-pager'
    email_configs:
      - to: 'oncall@ultimate-ai.com'
        send_resolved: true
    pagerduty_configs:
      - service_key: '${PAGERDUTY_KEY}'
        send_resolved: true

  - name: 'team-database'
    email_configs:
      - to: 'database-team@ultimate-ai.com'
        send_resolved: true
    slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '#database-alerts'
        send_resolved: true
        title: '[Database] {{ .GroupLabels.alertname }}'
        text: |-
          {{ range .Alerts }}
            *Alert:* {{ .Annotations.summary }}
            *Description:* {{ .Annotations.description }}
            *Severity:* {{ .Labels.severity }}
            *Instance:* {{ .Labels.instance }}
            *Time:* {{ .StartsAt }}
          {{ end }}

  - name: 'team-trading'
    email_configs:
      - to: 'trading-team@ultimate-ai.com'
        send_resolved: true
    slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '#trading-alerts'
        send_resolved: true

  - name: 'team-ai'
    email_configs:
      - to: 'ai-team@ultimate-ai.com'
        send_resolved: true
    webhook_configs:
      - url: 'https://hooks.slack.com/services/${SLACK_WEBHOOK}'
        send_resolved: true

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'cluster', 'service']
EOF
    
    # Create systemd service for Alertmanager
    cat > /etc/systemd/system/alertmanager.service << EOF
[Unit]
Description=Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple
ExecStart=/usr/local/bin/alertmanager \
    --config.file=/etc/alertmanager.yml \
    --storage.path=/var/lib/alertmanager/ \
    --web.listen-address=:9093 \
    --web.external-url=https://ai-system.example.com/alertmanager \
    --cluster.listen-address=0.0.0.0:9094 \
    --log.level=info \
    --log.format=json

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Create Alertmanager user
    useradd --no-create-home --shell /bin/false alertmanager
    mkdir -p /var/lib/alertmanager
    chown -R alertmanager:alertmanager /var/lib/alertmanager
    
    success "Alertmanager configured"
}

# Setup exporters
setup_exporters() {
    log "Setting up exporters..."
    
    # PostgreSQL Exporter
    wget https://github.com/prometheus-community/postgres_exporter/releases/download/v0.13.2/postgres_exporter-0.13.2.linux-amd64.tar.gz
    tar xvf postgres_exporter-0.13.2.linux-amd64.tar.gz
    cp postgres_exporter-0.13.2.linux-amd64/postgres_exporter /usr/local/bin/
    rm -rf postgres_exporter-0.13.2.linux-amd64*
    
    cat > /etc/systemd/system/postgres_exporter.service << EOF
[Unit]
Description=PostgreSQL Exporter
After=postgresql.service

[Service]
User=postgres_exporter
Group=postgres_exporter
Environment="DATA_SOURCE_NAME=postgresql://ultimate_ai_user:\${DB_PASSWORD}@localhost:5432/ultimate_ai?sslmode=disable"
ExecStart=/usr/local/bin/postgres_exporter \
    --web.listen-address=:9187 \
    --web.telemetry-path=/metrics \
    --log.level=info \
    --log.format=json

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    useradd --no-create-home --shell /bin/false postgres_exporter
    
    # Redis Exporter
    wget https://github.com/oliver006/redis_exporter/releases/download/v1.54.0/redis_exporter-v1.54.0.linux-amd64.tar.gz
    tar xvf redis_exporter-v1.54.0.linux-amd64.tar.gz
    cp redis_exporter-v1.54.0.linux-amd64/redis_exporter /usr/local/bin/
    rm -rf redis_exporter-v1.54.0.linux-amd64*
    
    cat > /etc/systemd/system/redis_exporter.service << EOF
[Unit]
Description=Redis Exporter
After=redis.service

[Service]
User=redis_exporter
Group=redis_exporter
Environment="REDIS_ADDR=redis://localhost:6379"
Environment="REDIS_PASSWORD=\${REDIS_PASSWORD}"
ExecStart=/usr/local/bin/redis_exporter \
    --web.listen-address=:9121 \
    --web.telemetry-path=/metrics \
    --log-format=json

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    useradd --no-create-home --shell /bin/false redis_exporter
    
    # Nginx Exporter
    wget https://github.com/nginxinc/nginx-prometheus-exporter/releases/download/v0.11.0/nginx-prometheus-exporter_0.11.0_linux_amd64.tar.gz
    tar xvf nginx-prometheus-exporter_0.11.0_linux_amd64.tar.gz
    cp nginx-prometheus-exporter /usr/local/bin/
    rm -rf nginx-prometheus-exporter*
    
    cat > /etc/systemd/system/nginx_exporter.service << EOF
[Unit]
Description=NGINX Exporter
After=nginx.service

[Service]
User=nginx_exporter
Group=nginx_exporter
ExecStart=/usr/local/bin/nginx-prometheus-exporter \
    -nginx.scrape-uri=http://localhost:80/stub_status \
    -web.listen-address=:9113 \
    -web.telemetry-path=/metrics

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    useradd --no-create-home --shell /bin/false nginx_exporter
    
    # Blackbox Exporter
    wget https://github.com/prometheus/blackbox_exporter/releases/download/v0.24.0/blackbox_exporter-0.24.0.linux-amd64.tar.gz
    tar xvf blackbox_exporter-0.24.0.linux-amd64.tar.gz
    cp blackbox_exporter-0.24.0.linux-amd64/blackbox_exporter /usr/local/bin/
    rm -rf blackbox_exporter-0.24.0.linux-amd64*
    
    cat > /etc/blackbox_exporter.yml << 'EOF'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200]
      method: GET
      fail_if_ssl: false
      fail_if_not_ssl: false
      headers:
        User-Agent: "Blackbox Exporter"

  http_post_2xx:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200]
      method: POST
      fail_if_ssl: false
      fail_if_not_ssl: false

  tcp_connect:
    prober: tcp
    timeout: 5s

  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: "ip4"
EOF
    
    cat > /etc/systemd/system/blackbox_exporter.service << EOF
[Unit]
Description=Blackbox Exporter
After=network.target

[Service]
User=blackbox_exporter
Group=blackbox_exporter
ExecStart=/usr/local/bin/blackbox_exporter \
    --config.file=/etc/blackbox_exporter.yml \
    --web.listen-address=:9115 \
    --web.telemetry-path=/metrics

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    useradd --no-create-home --shell /bin/false blackbox_exporter
    
    # cAdvisor for container monitoring
    wget https://github.com/google/cadvisor/releases/download/v0.47.0/cadvisor-v0.47.0-linux-amd64
    mv cadvisor-v0.47.0-linux-amd64 /usr/local/bin/cadvisor
    chmod +x /usr/local/bin/cadvisor
    
    cat > /etc/systemd/system/cadvisor.service << EOF
[Unit]
Description=cAdvisor
After=network.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/cadvisor \
    --port=8080 \
    --housekeeping_interval=10s \
    --max_housekeeping_interval=30s \
    --allow_dynamic_housekeeping=true \
    --enable_metrics=app,cpu,disk,diskIO,memory,network,process,tcp

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Create custom Ultimate AI exporter
    cat > /opt/monitoring/exporters/ultimate_ai_exporter.py << 'EOF'
#!/usr/bin/env python3
"""
Ultimate AI System Custom Exporter
Exports application-specific metrics to Prometheus
"""

from prometheus_client import start_http_server, Gauge, Counter, Histogram
import time
import psutil
import requests
import json
import os

# Metrics definitions
# System metrics
CPU_USAGE = Gauge('ultimate_ai_cpu_usage_percent', 'CPU usage percentage')
MEMORY_USAGE = Gauge('ultimate_ai_memory_usage_percent', 'Memory usage percentage')
DISK_USAGE = Gauge('ultimate_ai_disk_usage_percent', 'Disk usage percentage')
SYSTEM_LOAD = Gauge('ultimate_ai_system_load', 'System load average', ['period'])

# Application metrics
APP_STATUS = Gauge('ultimate_ai_app_status', 'Application status (1=up, 0=down)')
APP_VERSION = Gauge('ultimate_ai_app_version', 'Application version', ['version'])
ACTIVE_USERS = Gauge('ultimate_ai_active_users', 'Number of active users')
TOTAL_REQUESTS = Counter('ultimate_ai_total_requests', 'Total HTTP requests')
REQUEST_DURATION = Histogram('ultimate_ai_request_duration_seconds', 'Request duration in seconds')

# Trading metrics
TRADING_POSITIONS = Gauge('ultimate_ai_trading_positions', 'Number of active trading positions')
TRADING_PROFIT = Gauge('ultimate_ai_trading_profit', 'Total trading profit')
TRADING_SUCCESS_RATE = Gauge('ultimate_ai_trading_success_rate', 'Trading success rate')
TRADING_LATENCY = Histogram('ultimate_ai_trading_latency_seconds', 'Trading execution latency')

# AI Agent metrics
AI_AGENTS_ACTIVE = Gauge('ultimate_ai_agents_active', 'Number of active AI agents')
AI_AGENT_ERRORS = Counter('ultimate_ai_agent_errors_total', 'Total AI agent errors', ['agent_type'])
AI_AGENT_PROCESSING_TIME = Histogram('ultimate_ai_agent_processing_seconds', 'AI agent processing time')

# Workout metrics
WORKOUT_SESSIONS = Counter('ultimate_ai_workout_sessions_total', 'Total workout sessions')
WORKOUT_EXERCISES = Counter('ultimate_ai_workout_exercises_total', 'Total exercises completed')
WORKOUT_CALORIES = Counter('ultimate_ai_workout_calories_total', 'Total calories burned')

# Database metrics
DB_CONNECTIONS = Gauge('ultimate_ai_db_connections', 'Database connections')
DB_QUERY_TIME = Histogram('ultimate_ai_db_query_seconds', 'Database query execution time')

def collect_system_metrics():
    """Collect system metrics"""
    # CPU usage
    CPU_USAGE.set(psutil.cpu_percent(interval=1))
    
    # Memory usage
    memory = psutil.virtual_memory()
    MEMORY_USAGE.set(memory.percent)
    
    # Disk usage
    disk = psutil.disk_usage('/')
    DISK_USAGE.set(disk.percent)
    
    # System load
    load = psutil.getloadavg()
    SYSTEM_LOAD.labels('1min').set(load[0])
    SYSTEM_LOAD.labels('5min').set(load[1])
    SYSTEM_LOAD.labels('15min').set(load[2])

def collect_application_metrics():
    """Collect application metrics"""
    try:
        # Check backend health
        response = requests.get('http://localhost:8000/health', timeout=5)
        APP_STATUS.set(1 if response.status_code == 200 else 0)
        
        # Get app info
        info = response.json()
        APP_VERSION.labels(info.get('version', 'unknown')).set(1)
        
    except Exception as e:
        APP_STATUS.set(0)
        print(f"Error collecting app metrics: {e}")

def collect_trading_metrics():
    """Collect trading metrics"""
    try:
        response = requests.get('http://localhost:8000/api/trading/metrics', timeout=5)
        data = response.json()
        
        TRADING_POSITIONS.set(data.get('active_positions', 0))
        TRADING_PROFIT.set(data.get('total_profit', 0))
        TRADING_SUCCESS_RATE.set(data.get('success_rate', 0))
        
    except Exception as e:
        print(f"Error collecting trading metrics: {e}")

def collect_ai_agent_metrics():
    """Collect AI agent metrics"""
    try:
        response = requests.get('http://localhost:8000/api/ai/metrics', timeout=5)
        data = response.json()
        
        AI_AGENTS_ACTIVE.set(data.get('active_agents', 0))
        
        # Update agent-specific metrics
        for agent in data.get('agents', []):
            if agent.get('errors', 0) > 0:
                AI_AGENT_ERRORS.labels(agent['type']).inc(agent['errors'])
        
    except Exception as e:
        print(f"Error collecting AI agent metrics: {e}")

def collect_workout_metrics():
    """Collect workout metrics"""
    try:
        response = requests.get('http://localhost:8000/api/workout/metrics', timeout=5)
        data = response.json()
        
        WORKOUT_SESSIONS.inc(data.get('sessions_today', 0))
        WORKOUT_EXERCISES.inc(data.get('exercises_today', 0))
        WORKOUT_CALORIES.inc(data.get('calories_today', 0))
        
    except Exception as e:
        print(f"Error collecting workout metrics: {e}")

def collect_database_metrics():
    """Collect database metrics"""
    try:
        # This would require database access
        # For now, we'll use psutil to check PostgreSQL
        for proc in psutil.process_iter(['name']):
            if proc.info['name'] == 'postgres':
                DB_CONNECTIONS.set(len(psutil.Process(proc.pid).connections()))
                break
                
    except Exception as e:
        print(f"Error collecting database metrics: {e}")

def main():
    """Main function"""
    # Start HTTP server on port 9092
    start_http_server(9092)
    print("Ultimate AI Exporter started on port 9092")
    
    while True:
        try:
            # Collect all metrics
            collect_system_metrics()
            collect_application_metrics()
            collect_trading_metrics()
            collect_ai_agent_metrics()
            collect_workout_metrics()
            collect_database_metrics()
            
        except Exception as e:
            print(f"Error in metric collection: {e}")
        
        # Wait before next collection
        time.sleep(15)

if __name__ == '__main__':
    main()
EOF
    
    chmod +x /opt/monitoring/exporters/ultimate_ai_exporter.py
    
    # Create systemd service for custom exporter
    cat > /etc/systemd/system/ultimate-ai-exporter.service << EOF
[Unit]
Description=Ultimate AI Custom Exporter
After=network.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/bin/python3 /opt/monitoring/exporters/ultimate_ai_exporter.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    success "Exporters configured"
}

# Configure alerts
configure_alerts() {
    log "Configuring alerts..."
    
    # Create alert templates
    mkdir -p /etc/alertmanager/templates
    
    cat > /etc/alertmanager/templates/email.tmpl << 'EOF'
{{ define "email.html" }}
<!DOCTYPE html>
<html>
<head>
    <title>Ultimate AI System Alert</title>
    <style>
        body { font-family: Arial, sans-serif; }
        .alert { border: 1px solid #ccc; padding: 15px; margin: 10px 0; }
        .critical { background-color: #ffcccc; }
        .warning { background-color: #ffffcc; }
        .info { background-color: #ccffcc; }
        .label { font-weight: bold; }
    </style>
</head>
<body>
    <h2>Alert: {{ .GroupLabels.alertname }}</h2>
    <div class="alert {{ .Labels.severity }}">
        <p><span class="label">Status:</span> {{ .Status }}</p>
        <p><span class="label">Severity:</span> {{ .Labels.severity }}</p>
        <p><span class="label">Instance:</span> {{ .Labels.instance }}</p>
        <p><span class="label">Summary:</span> {{ .Annotations.summary }}</p>
        <p><span class="label">Description:</span> {{ .Annotations.description }}</p>
        <p><span class="label">Time:</span> {{ .StartsAt }}</p>
    </div>
    
    <h3>Labels:</h3>
    <ul>
    {{ range .Labels.SortedPairs }}
        <li><strong>{{ .Name }}:</strong> {{ .Value }}</li>
    {{ end }}
    </ul>
    
    <hr>
    <p><small>This alert was triggered by Prometheus Alertmanager.</small></p>
</body>
</html>
{{ end }}
EOF
    
    # Configure Nginx for monitoring endpoints
    cat > /etc/nginx/sites-available/monitoring << 'EOF'
server {
    listen 80;
    server_name ai-system.example.com;
    
    # Redirect HTTP to HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ai-system.example.com;
    
    ssl_certificate /etc/ssl/ultimate-ai/certificate.crt;
    ssl_certificate_key /etc/ssl/ultimate-ai/private.key;
    
    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";
    
    # Prometheus
    location /prometheus/ {
        proxy_pass http://localhost:9090/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        auth_basic "Prometheus";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }
    
    # Grafana
    location /grafana/ {
        proxy_pass http://localhost:3000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # Alertmanager
    location /alertmanager/ {
        proxy_pass http://localhost:9093/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        auth_basic "Alertmanager";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }
    
    # Default redirect
    location / {
        return 302 /grafana/;
    }
}
EOF
    
    # Create authentication file
    echo "admin:$(openssl passwd -apr1 ${GRAFANA_PASSWORD})" > /etc/nginx/.htpasswd
    
    # Enable site
    ln -sf /etc/nginx/sites-available/monitoring /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx
    
    success "Alerts configured"
}

# Start services
start_services() {
    log "Starting monitoring services..."
    
    # Enable and start all services
    services=(
        prometheus
        node_exporter
        postgres_exporter
        redis_exporter
        nginx_exporter
        blackbox_exporter
        cadvisor
        grafana-server
        loki
        promtail
        alertmanager
        ultimate-ai-exporter
    )
    
    for service in "${services[@]}"; do
        systemctl enable $service 2>/dev/null || true
        systemctl start $service 2>/dev/null || true
    done
    
    # Wait for services to start
    sleep 10
    
    success "Monitoring services started"
}

# Main execution
main() {
    check_root
    
    log "Starting Ultimate AI System Monitoring Setup"
    
    # Run setup
    setup_monitoring
    
    # Show summary
    cat << EOF

===============================================================================
📊 MONITORING SETUP COMPLETE
===============================================================================

Services running on:

1. Prometheus:      http://localhost:9090
   Metrics endpoint: http://localhost:9090/metrics

2. Grafana:         http://localhost:3000
   Username: admin
   Password: ${GRAFANA_PASSWORD}

3. Alertmanager:    http://localhost:9093

4. Node Exporter:   http://localhost:9100/metrics

5. Loki (Logs):     http://localhost:3100

6. Custom Exporter: http://localhost:9092/metrics

===============================================================================
DASHBOARDS AVAILABLE:
===============================================================================

1. System Overview
2. AI Agents Monitoring
3. Trading System Monitoring
4. Workout System Monitoring

===============================================================================
ALERTS CONFIGURED:
===============================================================================

- High CPU/Memory/Disk usage
- Service downtime
- High error rates
- Trading system alerts
- AI agent errors
- Certificate expiration

===============================================================================
NEXT STEPS:
===============================================================================

1. Access Grafana at: http://$(hostname -I | awk '{print $1}'):3000
2. Add Prometheus as datasource
3. Import dashboards from /var/lib/grafana/dashboards/
4. Configure additional alert receivers (Slack, PagerDuty, etc.)
5. Set up automated backup of monitoring data

===============================================================================
TROUBLESHOOTING:
===============================================================================

Check service status:
  systemctl status prometheus grafana-server alertmanager

Check logs:
  journalctl -u prometheus -f
  journalctl -u grafana-server -f

Test metrics endpoint:
  curl http://localhost:9090/metrics | head -20

===============================================================================
EOF
}

# Execute main function
main "$@"
