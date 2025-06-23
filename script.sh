#!/bin/bash

# --------------------------------------------
# Ubuntu Server Setup Script
# Installs: SSH, Nginx, Node.js, SSL, FTP, FFmpeg
# Configures: streams.bmdigital.in with logging
# --------------------------------------------

# Print commands and continue on errors
set -x

# ===== 1. System Update =====
sudo apt update -y || echo "APT update failed - continuing..."
sudo apt upgrade -y || echo "APT upgrade failed - continuing..."

# ===== 2. Install and Secure SSH Server =====
{
    sudo apt install -y openssh-server || echo "SSH install failed - continuing..."
    
    # Backup original config
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true
    
    # Configure secure SSH
    sudo tee /etc/ssh/sshd_config >/dev/null <<EOF
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
KexAlgorithms curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com
LoginGraceTime 60
PermitRootLogin no
StrictModes yes
MaxAuthTries 3
MaxSessions 3
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
    
    # Handle different SSH service names
    if systemctl list-unit-files | grep -q ssh.service; then
        sudo systemctl restart ssh || echo "SSH restart failed - continuing..."
    elif systemctl list-unit-files | grep -q sshd.service; then
        sudo systemctl restart sshd || echo "SSHD restart failed - continuing..."
    fi
} >/dev/null 2>&1

# ===== 3. Install FFmpeg =====
{
    sudo apt install -y software-properties-common || true
    sudo add-apt-repository universe -y || true
    sudo apt update -y || true
    sudo apt install -y ffmpeg || echo "FFmpeg install failed - continuing..."
    ffmpeg -version | head -n 1 || true
} >/dev/null 2>&1

# ===== 4. Install Nginx =====
{
    sudo apt install -y nginx || echo "Nginx install failed - continuing..."
    sudo systemctl enable nginx || true
    sudo systemctl start nginx || true
} >/dev/null 2>&1

# ===== 5. Install Node.js (LTS) =====
{
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - || true
    sudo apt install -y nodejs || echo "Node.js install failed - continuing..."
    sudo npm install -g pm2 || true
} >/dev/null 2>&1

# ===== 6. Configure Domain =====
DOMAIN="streams.bmdigital.in"
WEB_ROOT="/var/www/$DOMAIN"
FTP_USER="streams_ftp"
FTP_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
SSH_USER="streams_admin"
SSH_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

{
    # Create system user for SSH/SFTP
    sudo useradd -m -d $WEB_ROOT -s /bin/bash $SSH_USER 2>/dev/null || true
    echo "$SSH_USER:$SSH_PASS" | sudo chpasswd || true
    
    # Create site directory
    sudo mkdir -p $WEB_ROOT || true
    sudo chown -R $SSH_USER:$SSH_USER $WEB_ROOT || true
    sudo chmod -R 755 $WEB_ROOT || true
    
    # Create sample index.html
    sudo tee $WEB_ROOT/index.html >/dev/null <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to $DOMAIN</title>
</head>
<body>
    <h1>Success! $DOMAIN is working!</h1>
    <p>FTP User: $FTP_USER</p>
    <p>SSH/SFTP User: $SSH_USER</p>
    <p>FFmpeg Version: $(ffmpeg -version | head -n 1 | awk '{print $3}' 2>/dev/null || echo "Not installed")</p>
</body>
</html>
EOF
} >/dev/null 2>&1

# ===== 7. Nginx Configuration =====
CONFIG_FILE="/etc/nginx/sites-available/$DOMAIN"

{
    sudo tee $CONFIG_FILE >/dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    access_log /var/log/nginx/$DOMAIN.access.log;
    error_log /var/log/nginx/$DOMAIN.error.log;

    root $WEB_ROOT;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    
    sudo ln -sf $CONFIG_FILE /etc/nginx/sites-enabled/ || true
    sudo nginx -t && sudo systemctl reload nginx || true
} >/dev/null 2>&1

# ===== 8. Install SSL (Let's Encrypt) =====
{
    sudo apt install -y certbot python3-certbot-nginx || true
    sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos --email admin@bmdigital.in || true
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet") | crontab - || true
} >/dev/null 2>&1

# ===== 9. Configure Log Rotation =====
{
    sudo tee /etc/logrotate.d/nginx-custom >/dev/null <<EOF
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        /usr/sbin/nginx -s reload
    endscript
}
EOF
} >/dev/null 2>&1

# ===== 10. FTP Server Setup =====
{
    sudo apt install -y vsftpd || true
    
    # Backup original config
    sudo cp /etc/vsftpd.conf /etc/vsftpd.conf.bak 2>/dev/null || true
    
    # Configure vsftpd
    sudo tee /etc/vsftpd.conf >/dev/null <<EOF
listen=YES
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
pasv_min_port=40000
pasv_max_port=45000
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
EOF
    
    sudo useradd -m -d $WEB_ROOT -s /bin/bash $FTP_USER 2>/dev/null || true
    echo "$FTP_USER:$FTP_PASS" | sudo chpasswd || true
    echo "$FTP_USER" | sudo tee -a /etc/vsftpd.userlist >/dev/null || true
    sudo systemctl restart vsftpd || true
} >/dev/null 2>&1

# ===== 11. Firewall Configuration =====
{
    sudo ufw allow 'Nginx Full' || true
    sudo ufw allow 'OpenSSH' || true
    sudo ufw allow 21/tcp || true  # FTP
    sudo ufw allow 20/tcp || true  # FTP data
    sudo ufw allow 990/tcp || true  # FTP SSL
    sudo ufw allow 40000:45000/tcp || true  # Passive FTP ports
    sudo ufw allow 8000:8100/tcp || true  # Custom port range
    echo "y" | sudo ufw enable || true
} >/dev/null 2>&1

# ===== 12. Verify FFmpeg =====
{
    echo "Testing FFmpeg installation..."
    ffmpeg -hide_banner -f lavfi -i sine=frequency=1000:duration=5 -c:a libmp3lame test.mp3 2>/dev/null && {
        echo "FFmpeg test successful - audio file created"
        rm test.mp3 2>/dev/null || true
    } || echo "FFmpeg test failed or not installed"
} >/dev/null 2>&1

# ===== 13. Final Output =====
echo "=========================================="
echo " Setup Complete (Partial failures ignored) "
echo "=========================================="
echo " Domain: https://$DOMAIN"
echo " Web Root: $WEB_ROOT"
[ -n "$SSH_USER" ] && echo " SSH/SFTP User: $SSH_USER"
[ -n "$SSH_PASS" ] && echo " SSH Pass: $SSH_PASS"
[ -n "$FTP_USER" ] && echo " FTP User: $FTP_USER"
[ -n "$FTP_PASS" ] && echo " FTP Pass: $FTP_PASS"
echo " FFmpeg Version: $(ffmpeg -version | head -n 1 | awk '{print $3}' 2>/dev/null || echo "Not installed")"
echo " Node.js: $(node -v 2>/dev/null || echo "Not installed")"
echo " NPM: $(npm -v 2>/dev/null || echo "Not installed")"
echo " Open Ports: 21,22,8000-8100,40000-45000"
echo "=========================================="
PUBLIC_IP=$(curl -s ifconfig.me || echo "unknown")
[ -n "$SSH_USER" ] && echo " SSH Access: ssh $SSH_USER@$PUBLIC_IP"
echo "=========================================="
