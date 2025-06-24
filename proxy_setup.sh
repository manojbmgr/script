#!/bin/bash

# Optimized Nginx Reverse Proxy Setup with SSL
# Usage: setup-reverse-proxy.sh <domain> <upstream> <email>
# Example: setup-reverse-proxy.sh livestream.bmgdigital.in 127.0.0.1:81 admin@bmgdigital.in

# Exit on error
set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Check arguments
if [ $# -ne 3 ]; then
    echo "Usage: $0 <domain> <upstream> <email>"
    exit 1
fi

DOMAIN="$1"
UPSTREAM="$2"
EMAIL="$3"

echo "➤ Starting reverse proxy setup for $DOMAIN..."
echo "• Proxy target: $UPSTREAM"
echo "• Email: $EMAIL"

# Install Nginx
echo "➤ Installing Nginx..."
apt update
apt install nginx -y

# Configure firewall
echo "➤ Configuring firewall..."
ufw allow 'Nginx Full'
ufw allow OpenSSH
ufw --force enable

# Create minimal Nginx config for Certbot
echo "➤ Creating temporary Nginx configuration..."
cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location / {
        return 200 'Certbot setup page';
    }
}
EOF

# Enable site
echo "➤ Enabling temporary site..."
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# Install Certbot
echo "➤ Installing Certbot..."
apt install certbot python3-certbot-nginx -y

# Obtain SSL certificate
echo "➤ Obtaining SSL certificate..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

# Configure auto-renewal
echo "➤ Configuring auto-renewal..."
(crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -

# Modify Certbot's config with our proxy settings
echo "➤ Configuring reverse proxy..."
CONFIG_FILE="/etc/nginx/sites-available/$DOMAIN"

# Backup original config
cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

# Modify the SSL server block
sed -i '/listen 443 ssl;/r /dev/stdin' "$CONFIG_FILE" <<EOF

    # Reverse proxy configuration
    location / {
        proxy_pass http://$UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_buffering off;
        proxy_request_buffering off;
    }

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    
    # Increase timeouts
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    send_timeout 600s;
    
    # File upload size
    client_max_body_size 100M;
EOF

# Remove the temporary root location
sed -i '/location \/ {/,/}/d' "$CONFIG_FILE"

# Apply config
echo "➤ Applying final configuration..."
nginx -t
systemctl reload nginx

echo "✅ Setup completed successfully!"
echo "================================="
echo "Domain: https://$DOMAIN"
echo "Proxying to: $UPSTREAM"
echo "SSL Certificate: /etc/letsencrypt/live/$DOMAIN/"
echo "================================="
