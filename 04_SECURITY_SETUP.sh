#!/bin/bash

# Ultimate AI System - Security Hardening Script
# Version: 2.0.0

set -e
set -o pipefail

# Configuration
APP_DIR="/opt/ultimate-ai-system"
LOG_DIR="/var/log/ultimate-ai"
USER_NAME="ultimate-ai"
GROUP_NAME="ultimate-ai"

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

# Main security hardening function
harden_system() {
    log "Starting system security hardening..."
    
    # 1. System updates
    update_system
    
    # 2. SSH hardening
    harden_ssh
    
    # 3. Firewall configuration
    configure_firewall
    
    # 4. Fail2ban setup
    setup_fail2ban
    
    # 5. Audit configuration
    setup_audit
    
    # 6. File system security
    secure_filesystem
    
    # 7. Application security
    secure_application
    
    # 8. Database security
    secure_database
    
    # 9. Network security
    secure_network
    
    # 10. Monitoring setup
    setup_security_monitoring
    
    success "Security hardening completed!"
}

# Update system packages
update_system() {
    log "Updating system packages..."
    
    apt-get update
    apt-get upgrade -y
    apt-get dist-upgrade -y
    apt-get autoremove -y
    apt-get autoclean -y
    
    # Enable automatic security updates
    apt-get install -y unattended-upgrades
    dpkg-reconfigure -plow unattended-upgrades
    
    success "System updated"
}

# Harden SSH configuration
harden_ssh() {
    log "Hardening SSH configuration..."
    
    # Backup original config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
    # Configure secure SSH
    cat > /etc/ssh/sshd_config << 'EOF'
# Ultimate AI System - Secure SSH Configuration
Port 2222
Protocol 2
ListenAddress 0.0.0.0

# Authentication
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no

# Security
UsePAM yes
AllowUsers ${USER_NAME}
X11Forwarding no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 60

# Encryption
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256

# Logging
LogLevel VERBOSE
SyslogFacility AUTH

# Restrict access
AllowTcpForwarding no
AllowAgentForwarding no
GatewayPorts no
PermitTunnel no
EOF
    
    # Restart SSH
    systemctl restart sshd
    
    success "SSH hardened"
}

# Configure firewall
configure_firewall() {
    log "Configuring firewall..."
    
    # Install UFW if not present
    apt-get install -y ufw
    
    # Reset and configure
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow essential ports
    ufw allow 2222/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 8000/tcp comment 'Backend API'
    
    # Allow monitoring ports
    ufw allow 9090/tcp comment 'Prometheus'
    ufw allow 3001/tcp comment 'Grafana'
    ufw allow 9100/tcp comment 'Node Exporter'
    
    # Enable logging
    ufw logging on
    
    # Enable firewall
    ufw --force enable
    
    success "Firewall configured"
}

# Setup Fail2ban
setup_fail2ban() {
    log "Setting up Fail2ban..."
    
    apt-get install -y fail2ban
    
    # Create jail configuration
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd
destemail = admin@example.com
sender = fail2ban@ultimate-ai.com
action = %(action_mwl)s

[sshd]
enabled = true
port = 2222
filter = sshd
logpath = /var/log/auth.log
maxretry = 3

[ultimate-ai-backend]
enabled = true
port = http,https,8000
filter = ultimate-ai
logpath = /var/log/ultimate-ai/backend-error.log
maxretry = 10
findtime = 300
bantime = 86400

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3

[nginx-badbots]
enabled = true
port = http,https
filter = nginx-badbots
logpath = /var/log/nginx/access.log
maxretry = 2
bantime = 86400
EOF
    
    # Create custom filter for application
    cat > /etc/fail2ban/filter.d/ultimate-ai.conf << 'EOF'
[Definition]
failregex = ^.* Authentication failed for user .* from <HOST>$
            ^.* Invalid API key from <HOST>$
            ^.* Rate limit exceeded from <HOST>$
            ^.* SQL injection attempt from <HOST>$
ignoreregex =
EOF
    
    # Start and enable
    systemctl enable fail2ban
    systemctl start fail2ban
    
    success "Fail2ban configured"
}

# Setup audit system
setup_audit() {
    log "Setting up audit system..."
    
    apt-get install -y auditd audispd-plugins
    
    # Configure audit rules
    cat > /etc/audit/rules.d/ultimate-ai.rules << 'EOF'
# Monitor system calls
-a always,exit -F arch=b64 -S execve -k exec
-a always,exit -F arch=b32 -S execve -k exec

# Monitor file modifications
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k identity

# Monitor application files
-w /opt/ultimate-ai-system/.env -p wa -k app_config
-w /opt/ultimate-ai-system/backend -p wa -k app_code
-w /var/log/ultimate-ai -p wa -k app_logs

# Monitor database files
-w /var/lib/postgresql -p wa -k database
-w /var/lib/redis -p wa -k redis

# Monitor SSL certificates
-w /etc/ssl/ultimate-ai -p wa -k ssl_certs

# Monitor cron jobs
-w /etc/cron.d -p wa -k cron
-w /etc/crontab -p wa -k cron

# Monitor system binaries
-w /bin -p wa -k system_binaries
-w /usr/bin -p wa -k system_binaries
-w /sbin -p wa -k system_binaries
-w /usr/sbin -p wa -k system_binaries
EOF
    
    # Restart audit service
    systemctl restart auditd
    
    success "Audit system configured"
}

# Secure filesystem
secure_filesystem() {
    log "Securing filesystem..."
    
    # Secure /tmp and /var/tmp
    cat >> /etc/fstab << 'EOF'
tmpfs /tmp tmpfs defaults,noexec,nosuid,nodev 0 0
tmpfs /var/tmp tmpfs defaults,noexec,nosuid,nodev 0 0
EOF
    
    mount -o remount /tmp
    mount -o remount /var/tmp
    
    # Set secure umask
    echo "umask 027" >> /etc/profile
    echo "umask 027" >> /etc/bash.bashrc
    
    # Disable core dumps
    echo "* hard core 0" >> /etc/security/limits.conf
    echo "fs.suid_dumpable = 0" >> /etc/sysctl.conf
    
    # Disable unused filesystems
    cat >> /etc/modprobe.d/blacklist.conf << 'EOF'
blacklist usb-storage
blacklist firewire-core
blacklist thunderbolt
EOF
    
    success "Filesystem secured"
}

# Secure application
secure_application() {
    log "Securing application..."
    
    # Set proper permissions
    chown -R ${USER_NAME}:${GROUP_NAME} ${APP_DIR}
    chmod -R 750 ${APP_DIR}
    chmod 640 ${APP_DIR}/.env
    
    # Secure logs
    chown -R ${USER_NAME}:${GROUP_NAME} ${LOG_DIR}
    chmod -R 750 ${LOG_DIR}
    
    # Create application user with limited privileges
    usermod -s /bin/false ${USER_NAME}
    
    # Set resource limits
    cat >> /etc/security/limits.d/ultimate-ai.conf << EOF
${USER_NAME} soft nofile 65536
${USER_NAME} hard nofile 65536
${USER_NAME} soft nproc 65536
${USER_NAME} hard nproc 65536
EOF
    
    # Create systemd service restrictions
    for service in ultimate-ai-backend ultimate-ai-celery ultimate-ai-celery-beat; do
        systemctl edit ${service} << 'EOF'
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/log/ultimate-ai /opt/ultimate-ai-system/data
InaccessiblePaths=/boot /etc/ssh
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
EOF
    done
    
    success "Application secured"
}

# Secure database
secure_database() {
    log "Securing database..."
    
    # PostgreSQL security
    cat >> /etc/postgresql/15/main/postgresql.conf << 'EOF'
# Security settings
ssl = on
ssl_cert_file = '/etc/ssl/ultimate-ai/certificate.crt'
ssl_key_file = '/etc/ssl/ultimate-ai/private.key'
ssl_ca_file = '/etc/ssl/ultimate-ai/ca.crt'
ssl_prefer_server_ciphers = on
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL'
password_encryption = scram-sha-256
log_connections = on
log_disconnections = on
log_hostname = on
log_line_prefix = '%m [%p] %q%u@%d '
log_statement = 'ddl'
log_temp_files = 0
EOF
    
    # Redis security
    cat >> /etc/redis/redis.conf << 'EOF'
# Security settings
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command CONFIG ""
rename-command SHUTDOWN ""
rename-command DEBUG ""
rename-command MONITOR ""
rename-command SLAVEOF ""
rename-command REPLICAOF ""
rename-command KEYS ""
EOF
    
    # Restart services
    systemctl restart postgresql
    systemctl restart redis
    
    success "Database secured"
}

# Secure network
secure_network() {
    log "Securing network..."
    
    # Configure sysctl for network security
    cat > /etc/sysctl.d/99-ultimate-ai-security.conf << 'EOF'
# Network security
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# ARP security
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.all.arp_notify = 1

# TCP security
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_max_orphans = 65536
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_tw_reuse = 1

# Memory and connection limits
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 5000
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_mem = 786432 1048576 1572864
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# Security limits
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
kernel.core_uses_pid = 1
kernel.kptr_restrict = 2
kernel.sysrq = 0
kernel.yama.ptrace_scope = 1
EOF
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-ultimate-ai-security.conf
    
    # Install and configure TCP wrappers
    apt-get install -y tcpd
    
    cat > /etc/hosts.allow << 'EOF'
# Allow localhost
ALL: LOCAL @localhost

# Allow SSH from specific networks
sshd: 10.0.0.0/8, 192.168.0.0/16, 172.16.0.0/12

# Allow application
ultimate-ai-backend: ALL
nginx: ALL
EOF
    
    cat > /etc/hosts.deny << 'EOF'
# Deny all by default
ALL: ALL
EOF
    
    success "Network secured"
}

# Setup security monitoring
setup_security_monitoring() {
    log "Setting up security monitoring..."
    
    # Install security tools
    apt-get install -y \
        aide \
        rkhunter \
        chkrootkit \
        lynis \
        logwatch \
        tripwire
    
    # Initialize AIDE (Advanced Intrusion Detection Environment)
    aideinit
    
    # Configure rkhunter
    rkhunter --propupd
    rkhunter --check --sk
    
    # Configure lynis
    lynis audit system
    
    # Set up log monitoring
    cat > /etc/logwatch/conf/logwatch.conf << 'EOF'
# Logwatch configuration for Ultimate AI System
LogDir = /var/log
TmpDir = /tmp
MailTo = admin@example.com
MailFrom = logwatch@ultimate-ai.com
Detail = High
Service = "-zz-network"
Service = "-zz-sys"
Service = All
Range = yesterday
EOF
    
    # Create daily security report cron
    cat > /etc/cron.daily/security-report << 'EOF'
#!/bin/bash

# Generate daily security report
REPORT_DIR="/var/log/security-reports"
DATE=$(date +%Y%m%d)

mkdir -p $REPORT_DIR

# Run security checks
rkhunter --check --report-warnings-only > $REPORT_DIR/rkhunter-$DATE.log
chkrootkit > $REPORT_DIR/chkrootkit-$DATE.log
lynis audit system --quick > $REPORT_DIR/lynis-$DATE.log

# Check for failed login attempts
grep "Failed password" /var/log/auth.log > $REPORT_DIR/failed-logins-$DATE.log

# Check for suspicious processes
ps auxf > $REPORT_DIR/processes-$DATE.log

# Check network connections
netstat -tulpn > $REPORT_DIR/network-$DATE.log

# Compress old reports
find $REPORT_DIR -name "*.log" -mtime +30 -exec gzip {} \;
EOF
    
    chmod +x /etc/cron.daily/security-report
    
    success "Security monitoring configured"
}

# Run security hardening
main() {
    check_root
    
    log "Starting Ultimate AI System Security Hardening"
    
    # Create backup of critical files
    log "Creating backup of critical files..."
    BACKUP_DIR="/root/security-backup-$(date +%Y%m%d)"
    mkdir -p "$BACKUP_DIR"
    
    cp -r /etc/ssh "$BACKUP_DIR/"
    cp -r /etc/postgresql "$BACKUP_DIR/"
    cp -r /etc/redis "$BACKUP_DIR/"
    cp /etc/fail2ban/jail.local "$BACKUP_DIR/" 2>/dev/null || true
    
    # Run hardening
    harden_system
    
    # Final checks
    log "Running final security checks..."
    
    # Check for open ports
    log "Checking open ports..."
    ss -tulpn | grep LISTEN
    
    # Check user privileges
    log "Checking user privileges..."
    id ${USER_NAME}
    
    # Check file permissions
    log "Checking file permissions..."
    ls -la ${APP_DIR}/.env
    ls -la ${LOG_DIR}
    
    success "Security hardening completed successfully!"
    
    cat << EOF

===============================================================================
🔒 SECURITY HARDENING COMPLETE
===============================================================================

IMPORTANT NEXT STEPS:

1. TEST SSH CONNECTION:
   ssh -p 2222 ${USER_NAME}@$(hostname -I | awk '{print $1}')

2. VERIFY FIREWALL:
   sudo ufw status verbose

3. CHECK FAIL2BAN:
   sudo fail2ban-client status

4. REVIEW AUDIT LOGS:
   sudo ausearch -k app_config

5. SETUP REGULAR SECURITY SCANS:
   - Schedule daily rkhunter scans
   - Weekly lynis audits
   - Monthly full system scans

6. MONITOR LOGS:
   - /var/log/auth.log (SSH attempts)
   - /var/log/fail2ban.log (banned IPs)
   - ${LOG_DIR}/ (application logs)

7. IMPLEMENT ADDITIONAL SECURITY:
   - Consider installing WAF (ModSecurity)
   - Setup intrusion detection (OSSEC)
   - Configure VPN for admin access

BACKUP FILES: ${BACKUP_DIR}

===============================================================================
EOF
}

# Run main function
main "$@"
