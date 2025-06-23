#!/bin/bash

# --------------------------------------------
# Ubuntu Server Setup Script
# Installs: SSH, Nginx, Node.js, SSL, FTP, FFmpeg
# Configures: streams.bmdigital.in with logging
# --------------------------------------------

# Enable error handling and logging
set -ex
LOG_FILE="/var/log/setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ===== 1. System Update =====
export DEBIAN_FRONTEND=noninteractive
sudo apt update -y
sudo apt upgrade -y

# ===== 2. Install and Secure SSH Server =====
sudo apt install -y openssh-server

# Backup original config
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Configure secure SSH
sudo tee /etc/ssh/sshd_config > /dev/null <<EOF
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

# Restart SSH service
sudo systemctl restart ssh || sudo systemctl restart sshd

# ===== 3. Install FFmpeg =====
sudo apt install -y software-properties-common
sudo add-apt-repository universe -y
sudo apt update -y
sudo apt install -y ffmpeg

# Verify installation
ffmpeg -version | head -n 1

# ===== 4. Install Nginx =====
sudo apt install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx

# ===== 5. Install Node.js (LTS) =====
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pm2

# ===== 6. Configure Domain =====
DOMAIN="streams.bmdigital.in"
WEB_ROOT="/var/www/$DOMAIN"
FTP_USER="streams_ftp"
FTP_PASS=$(openssl rand -base64 12)
SSH_USER="streams_admin"
SSH_PASS=$(openssl rand -base64 12)

# Create system user for SSH/SFTP
sudo useradd -m -d $WEB_ROOT -s /bin/bash $SSH_USER
echo "$SSH_USER:$SSH_PASS" | sudo chpasswd

# Create site directory
sudo mkdir -p $WEB_ROOT
sudo chown -R $SSH_USER:$SSH_USER $WEB_ROOT
sudo chmod -R 755 $WEB_ROOT

# Create sample index.html
sudo tee $WEB_ROOT/index.html > /dev/null <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to $DOMAIN</title>
</head>
<body>
    <h1>Success! $DOMAIN is working!</h1>
    <p>FTP User: $FTP_USER</p>
    <p>SSH/SFTP User: $SSH_USER</p>
    <p>FFmpeg Version: $(ffmpeg -version | head -n 1 | awk '{print $3}')</p>
</body>
</html>
EOF

# ===== 7. Nginx Configuration =====
CONFIG_FILE="/etc/nginx/sites-available/$DOMAIN"

sudo tee $CONFIG_FILE > /dev/null <<EOF
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

# Enable the site
sudo ln -sf $CONFIG_FILE /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# ===== 8. Install SSL (Let's Encrypt) =====
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos --email admin@bmdigital.in

# Auto-renewal setup
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet") | crontab -

# ===== 9. Configure Log Rotation =====
sudo tee /etc/logrotate.d/nginx-custom > /dev/null <<EOF
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

# ===== 10. FTP Server Setup =====
sudo apt install -y vsftpd

# Backup original config
sudo cp /etc/vsftpd.conf /etc/vsftpd.conf.bak

# Configure vsftpd
sudo tee /etc/vsftpd.conf > /dev/null <<EOF
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

# Create FTP user
sudo useradd -m -d $WEB_ROOT -s /bin/bash $FTP_USER
echo "$FTP_USER:$FTP_PASS" | sudo chpasswd
echo "$FTP_USER" | sudo tee -a /etc/vsftpd.userlist

# Restart FTP service
sudo systemctl restart vsftpd

# ===== 11. Firewall Configuration =====
sudo ufw allow 'Nginx Full'
sudo ufw allow 'OpenSSH'
sudo ufw allow 21/tcp  # FTP
sudo ufw allow 20/tcp  # FTP data
sudo ufw allow 990/tcp  # FTP SSL
sudo ufw allow 40000:45000/tcp  # Passive FTP ports
sudo ufw allow 8000:8100/tcp  # Custom port range
echo "y" | sudo ufw enable

# ===== 12. Verify FFmpeg =====
echo "Testing FFmpeg installation..."
ffmpeg -hide_banner -f lavfi -i sine=frequency=1000:duration=5 -c:a libmp3lame test.mp3 && {
    echo "FFmpeg test successful - audio file created"
    rm test.mp3
} || echo "FFmpeg test failed or not installed"

# ===== 13. Final Output =====
echo "=========================================="
echo " Setup Complete! "
echo "=========================================="
echo " Domain: https://$DOMAIN"
echo " Web Root: $WEB_ROOT"
echo " SSH/SFTP User: $SSH_USER"
echo " SSH Pass: $SSH_PASS"
echo " FTP User: $FTP_USER"
echo " FTP Pass: $FTP_PASS"
echo " FFmpeg Version: $(ffmpeg -version | head -n 1 | awk '{print $3}')"
echo " Node.js: $(node -v)"
echo " NPM: $(npm -v)"
echo " Open Ports: 21,22,8000-8100,40000-45000"
echo "=========================================="
PUBLIC_IP=$(curl -s https://api64.ipify.org || echo "unknown")
echo " SSH Access: ssh $SSH_USER@$PUBLIC_IP"
echo "=========================================="
