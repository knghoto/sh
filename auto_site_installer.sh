#!/bin/bash

# Перевірка на права root
if [ "$EUID" -ne 0 ]; then
  echo "Цей скрипт має бути запущений від root!" 
  exit 1
fi

# Налаштування змінних
SITE_DIR="/opt/auto_site"
API_PORT="3000"
BACKEND_DIR="$SITE_DIR/backend"
NGINX_DIR="/etc/nginx/sites-available"
SSL_DIR="/etc/ssl/localcerts"
CREDENTIALS_FILE="/root/auto_site_credentials.txt"

# Функція для встановлення необхідних пакетів
install_packages() {
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y \
    nginx \
    docker.io \
    docker-compose \
    nodejs \
    npm \
    pm2 \
    openjdk-17-jre-headless \
    git \
    jq \
    ufw \
    curl \
    && apt clean
}

# Створення самопідписаних SSL сертифікатів
generate_ssl_certificates() {
  mkdir -p $SSL_DIR
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout $SSL_DIR/selfsigned.key \
    -out $SSL_DIR/selfsigned.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"
}

# Генерація JWT секрету та пароля для користувача admin
generate_credentials() {
  ADMIN_PASSWORD=$(openssl rand -base64 32)
  JWT_SECRET=$(openssl rand -base64 64)
  echo -e "Admin Password: $ADMIN_PASSWORD\nJWT Secret: $JWT_SECRET" > $CREDENTIALS_FILE
  chmod 600 $CREDENTIALS_FILE
}

# Створення Node.js бекенду
setup_backend() {
  mkdir -p $BACKEND_DIR
  cd $BACKEND_DIR
  git clone https://github.com/your-username/auto-site-backend.git .
  npm install
  # Налаштування pm2 для автозапуску
  pm2 start app.js --name "auto_site_backend"
  pm2 startup
  pm2 save
}

# Налаштування Nginx
setup_nginx() {
  # Створення конфігурацій для піддоменів
  cat > $NGINX_DIR/main_site <<EOF
server {
  listen 80;
  server_name localhost $(hostname -I | awk '{print $1}');
  root /var/www/html;
  index index.html;
  location / {
    try_files \$uri \$uri/ =404;
  }
}
EOF

  cat > $NGINX_DIR/minecraft <<EOF
server {
  listen 80;
  server_name minecraft.local;
  location / {
    proxy_pass http://localhost:$API_PORT/minecraft;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host \$host;
    proxy_cache_bypass \$http_upgrade;
  }
}
EOF

  cat > $NGINX_DIR/vps <<EOF
server {
  listen 80;
  server_name vps.local;
  location / {
    proxy_pass http://localhost:$API_PORT/vps;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host \$host;
    proxy_cache_bypass \$http_upgrade;
  }
}
EOF

  # Створення редиректу на HTTPS
  cat > $NGINX_DIR/redirect_https <<EOF
server {
  listen 80;
  server_name minecraft.local vps.local;
  return 301 https://\$server_name\$request_uri;
}
EOF

  ln -s $NGINX_DIR/main_site /etc/nginx/sites-enabled/
  ln -s $NGINX_DIR/minecraft /etc/nginx/sites-enabled/
  ln -s $NGINX_DIR/vps /etc/nginx/sites-enabled/
  ln -s $NGINX_DIR/redirect_https /etc/nginx/sites-enabled/
  
  nginx -t && systemctl restart nginx
}

# Налаштування firewall
setup_firewall() {
  ufw allow 22
  ufw allow 80
  ufw allow 443
  ufw enable
}

# Створення допоміжних скриптів
create_helper_scripts() {
  cat > /usr/local/bin/create_minecraft.sh <<'EOF'
#!/bin/bash
# Логіка створення Minecraft сервера
EOF
  chmod +x /usr/local/bin/create_minecraft.sh

  cat > /usr/local/bin/create_vps.sh <<'EOF'
#!/bin/bash
# Логіка створення VPS контейнера
EOF
  chmod +x /usr/local/bin/create_vps.sh
}

# Виведення інструкцій після встановлення
display_instructions() {
  echo "✅ Установка завершена!"
  echo "Основний сайт: http://$(hostname -I | awk '{print $1}') або http://localhost"
  echo "Minecraft Dashboard: https://minecraft.local"
  echo "VPS Manager: https://vps.local"
  echo "Логін: admin"
  echo "Пароль: $(cat $CREDENTIALS_FILE | grep 'Admin Password' | cut -d' ' -f3)"
  echo "JWT Secret: $(cat $CREDENTIALS_FILE | grep 'JWT Secret' | cut -d' ' -f3)"
}

# Основна логіка виконання
install_packages
generate_ssl_certificates
generate_credentials
setup_backend
setup_nginx
setup_firewall
create_helper_scripts
display_instructions
