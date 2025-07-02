#!/bin/bash

# ➤ Usage:
# wget -O setup.sh https://raw.githubusercontent.com/manojbmgr/script/refs/heads/main/proxy_setup.sh
# chmod +x setup.sh
# sudo ./setup.sh livestream.bmgdigital.in 127.0.0.1:81 admin@bmgdigital.in

set -e

# ───────────────────────────────────────────────────────────────
# 🔐 Input validation
# ───────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root"
  exit 1
fi

if [ $# -ne 3 ]; then
  echo "❌ Usage: $0 <domain> <upstream> <email>"
  exit 1
fi

DOMAIN="$1"
UPSTREAM="$2"
EMAIL="$3"

echo "==========================================="
echo "🔧 Setting up reverse proxy for $DOMAIN"
echo "→ Proxying to: $UPSTREAM"
echo "→ SSL email:   $EMAIL"
echo "==========================================="

# ───────────────────────────────────────────────────────────────
# 🧱 Install Nginx
# ───────────────────────────────────────────────────────────────
echo "➤ Installing Nginx..."
apt update
apt install nginx -y

# ───────────────────────────────────────────────────────────────
# 🔥 Configure UFW
# ───────────────────────────────────────────────────────────────
echo "➤ Configuring firewall (UFW)..."
ufw allow 'Nginx Full'
ufw allow OpenSSH
ufw --force enable
echo "➤ Allowing ports 8000–8500 via UFW..."
ufw allow 8000:8500/tcp
# ───────────────────────────────────────────────────────────────
# 🛠 Temporary config for Certbot challenge
# ───────────────────────────────────────────────────────────────
CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

echo "➤ Creating temporary Nginx config..."
cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location / {
        return 200 'Certbot verification';
    }
}
EOF

ln -sf "$CONFIG_PATH" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx

# ───────────────────────────────────────────────────────────────
# 🔐 Install Certbot and fetch SSL cert
# ───────────────────────────────────────────────────────────────
echo "➤ Installing Certbot..."
apt install certbot python3-certbot-nginx -y

echo "➤ Requesting SSL certificate..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

# ───────────────────────────────────────────────────────────────
# ♻ Replace Nginx config with full reverse proxy + security
# ───────────────────────────────────────────────────────────────
echo "➤ Applying secure proxy config with hotlink protection..."

cp "$CONFIG_PATH" "$CONFIG_PATH.bak"

cat > "$CONFIG_PATH" <<EOF
server {
    server_name $DOMAIN;
    listen [::]:443 ssl ipv6only=on; # managed by Certbot
    listen 443 ssl;

    # Hotlink protection for HLS playlist
    location ~ \.m3u8\$ {
        valid_referers none blocked radioindialive.com *.radioindialive.com vividhbharati.in *.vividhbharati.in livestream.bmgdigital.in *.livestream.bmgdigital.in;
        if (\$invalid_referer) {
            return 403;
        }
        proxy_pass http://$UPSTREAM;
    }

    # Optional: Protect .ts video chunks
    location ~ \.ts\$ {
        valid_referers none blocked radioindialive.com *.radioindialive.com vividhbharati.in *.vividhbharati.in livestream.bmgdigital.in *.livestream.bmgdigital.in;
        if (\$invalid_referer) {
            return 403;
        }
        proxy_pass http://$UPSTREAM;
    }

    # General proxy config
    location / {
        proxy_pass http://$UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

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

    # Timeouts & uploads
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    send_timeout 600s;
    client_max_body_size 100M;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    if (\$host = $DOMAIN) {
        return 301 https://\$host\$request_uri;
    }
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 404;
}
EOF

nginx -t && systemctl reload nginx

# ───────────────────────────────────────────────────────────────
# 🔄 Setup Certbot auto-renew
# ───────────────────────────────────────────────────────────────
echo "➤ Scheduling SSL auto-renewal..."
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet") | crontab -

# ───────────────────────────────────────────────────────────────
# ✅ Done
# ───────────────────────────────────────────────────────────────
echo ""
echo "✅ Reverse proxy setup complete!"
echo "🔗 Visit:        https://$DOMAIN"
echo "🎯 Proxy target: $UPSTREAM"
echo "📁 SSL path:     /etc/letsencrypt/live/$DOMAIN"
echo ""
