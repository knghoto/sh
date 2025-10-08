#!/bin/bash

# Перевірка на права root
if [ "$EUID" -ne 0 ]; then
  echo "Будь ласка, запустіть цей скрипт як root."
  exit 1
fi

# Перемикаємо на non-interactive режим
export DEBIAN_FRONTEND=noninteractive

# Оновлення системи
apt update -y && apt upgrade -y

# Встановлення необхідних пакетів
apt install -y nginx docker.io docker-compose nodejs npm pm2 openjdk-17-jre-headless git jq ufw

# Створення користувача admin та збереження пароля
ADMIN_PASSWORD=$(openssl rand -base64 12)
HASHED_PASSWORD=$(echo "$ADMIN_PASSWORD" | bcrypt)
echo "admin:$HASHED_PASSWORD" > /root/auto_site_credentials.txt
chmod 600 /root/auto_site_credentials.txt

# Генерація JWT ключа
JWT_SECRET=$(openssl rand -base64 32)

# Створення директорії для сайту
mkdir -p /opt/auto_site
cd /opt/auto_site

# Створення файлів для Node.js бекенду
cat <<EOL > /opt/auto_site/server.js
const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const app = express();
const port = 3000;

const users = { 'admin': '$HASHED_PASSWORD' };
const JWT_SECRET = '$JWT_SECRET';

app.use(express.json());

app.get('/', (req, res) => res.send('Welcome to the Auto Site Dashboard'));

app.post('/login', (req, res) => {
  const { username, password } = req.body;
  if (users[username] && bcrypt.compareSync(password, users[username])) {
    const token = jwt.sign({ username }, JWT_SECRET, { expiresIn: '1h' });
    res.json({ token });
  } else {
    res.status(401).send('Unauthorized');
  }
});

// Define routes for Minecraft and VPS management APIs

app.listen(port, () => {
  console.log(`Server running at http://localhost:${port}`);
});
EOL

# Створення простого HTML для головної сторінки
cat <<EOL > /opt/auto_site/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Auto Site</title>
  <style>
    body { font-family: Arial, sans-serif; text-align: center; margin-top: 50px; }
    button { margin: 10px; padding: 10px 20px; font-size: 18px; }
  </style>
</head>
<body>
  <h1>Welcome to the Auto Site Dashboard</h1>
  <button onclick="window.location.href='https://minecraft.local'">Minecraft Dashboard</button>
  <button onclick="window.location.href='https://vps.local'">VPS Manager</button>
</body>
</html>
EOL

# Створення сервісу для Node.js через pm2
pm2 start /opt/auto_site/server.js --name auto_site --watch
pm2 startup
pm2 save

# Створення допоміжних скриптів для Minecraft і VPS
cat <<EOL > /usr/local/bin/create_minecraft.sh
#!/bin/bash
NAME=\$1
RAM=\$2
PORT=\$3
USER=minecraft

if [ ! -d "/home/\$USER/\$NAME" ]; then
  mkdir -p /home/\$USER/\$NAME
  cd /home/\$USER/\$NAME
  wget https://api.papermc.io/v2/projects/paper/versions/latest/builds/latest/downloads/paper-\$PORT.jar -O paper.jar
  echo "eula=true" > eula.txt
  echo "server-port=\$PORT" > server.properties
  useradd -m -d /home/\$USER/\$NAME -s /bin/bash \$USER
  echo "\$USER ALL=(ALL) NOPASSWD: /usr/bin/java" > /etc/sudoers.d/\$USER
  echo "[Unit]
Description=Minecraft Server for \$NAME
After=network.target

[Service]
WorkingDirectory=/home/\$USER/\$NAME
ExecStart=/usr/bin/java -Xmx\$RAM -Xms\$RAM -jar paper.jar nogui
User=\$USER
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/minecraft-\$NAME.service
  systemctl enable minecraft-\$NAME.service
  systemctl start minecraft-\$NAME.service
  echo "Minecraft server \$NAME created successfully!"
else
  echo "Minecraft server \$NAME already exists!"
fi
EOL

cat <<EOL > /usr/local/bin/create_vps.sh
#!/bin/bash
NAME=\$1
SSH_PORT=\$2
PASSWORD=\$3

if [ ! -d "/srv/vps/\$NAME" ]; then
  mkdir -p /srv/vps/\$NAME
  docker run -d -p \$SSH_PORT:22 --name \$NAME ubuntu:latest
  docker exec \$NAME bash -c "apt update && apt install -y openssh-server"
  docker exec \$NAME bash -c "echo 'root:\$PASSWORD' | chpasswd"
  echo "VPS \$NAME created successfully on port \$SSH_PORT"
  ufw allow \$SSH_PORT
else
  echo "VPS \$NAME already exists!"
fi
EOL

chmod +x /usr/local/bin/create_minecraft.sh
chmod +x /usr/local/bin/create_vps.sh

# Створення Nginx конфігурацій
mkdir -p /etc/ssl/localcerts
openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/ssl/localcerts/selfsigned.key -out /etc/ssl/localcerts/selfsigned.crt -days 365 -subj "/CN=localhost"
cat <<EOL > /etc/nginx/sites-available/default
server {
    listen 80;
    server_name localhost;

    location / {
        root /opt/auto_site;
        index index.html;
    }

    location /minecraft {
        proxy_pass http://localhost:3000;
    }

    location /vps {
        proxy_pass http://localhost:3000;
    }

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name localhost;

    ssl_certificate /etc/ssl/localcerts/selfsigned.crt;
    ssl_certificate_key /etc/ssl/localcerts/selfsigned.key;

    location / {
        root /opt/auto_site;
        index index.html;
    }

    location /minecraft {
        proxy_pass http://localhost:3000;
    }

    location /vps {
        proxy_pass http://localhost:3000;
    }
}
EOL

# Налаштування UFW
ufw allow 22
ufw allow 80
ufw allow 443
ufw enable

# Запуск Nginx
systemctl restart nginx

# Підсумок
echo "✅ Установка завершена!"
echo "Головна сторінка: http://<LAN-IP> або http://localhost"
echo "Minecraft Dashboard: https://minecraft.local"
echo "VPS Manager: https://vps.local"
echo "Логін: admin"
echo "Пароль: (див. /root/auto_site_credentials.txt)"

# Інструкція
echo "Як змінити пароль: редагуйте /root/auto_site_credentials.txt"
echo "Як видалити Minecraft сервер: systemctl stop minecraft-<name>.service && systemctl disable minecraft-<name>.service"
echo "Як видалити VPS: docker rm -f <name>"
echo "Як вимкнути pm2-сервіс: pm2 stop auto_site"
echo "Рекомендується: встановити 2FA для SSH, обмежити доступ за IP."
