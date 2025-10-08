#!/usr/bin/env bash
# auto_site_installer_local.sh
# Один файл — повна автоматична інсталяція мінімалістичного сайту + Minecraft dashboard + VPS manager (Docker)
# Призначено для локальної мережі (emulated subdomains: minecraft.local, vps.local)
# Працює на Ubuntu 22.04 / 24.04
set -euo pipefail
IFS=$'\n\t'

###########################
# Конфігурація (редагуй за потреби)
###########################
MAIN_HOSTNAME="${1:-localhost}"   # для локалки: localhost або IP (в UI виводимо LAN IP)
MC_HOST="minecraft.local"
VPS_HOST="vps.local"
APP_DIR="/opt/auto_site"
BIN_DIR="${APP_DIR}/bin"
CRED_FILE="/root/auto_site_credentials.txt"
NODE_PORT=3000
PM2_NAME="auto-site-backend"
MINECRAFT_USER="minecraft"
SRV_MINECRAFT_ROOT="/srv/minecraft"
SRV_VPS_ROOT="/srv/vps"
SSL_DIR="/etc/ssl/localcerts"
###########################

# require root
if [[ $EUID -ne 0 ]]; then
  echo "Запустіть скрипт від root (sudo)."
  exit 1
fi

echo "=== Auto deploy: minimal local site + minecraft & vps managers ==="

export DEBIAN_FRONTEND=noninteractive

# Helper: generate random password
randpass() {
  head /dev/urandom | tr -dc 'A-Za-z0-9!@%+-_' | head -c 20 || echo "pass$(date +%s)"
}

# Determine LAN IP (best-effort)
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')"
if [[ -z "$LAN_IP" ]]; then
  LAN_IP="$(hostname -I | awk '{print $1}')"
fi
if [[ -z "$LAN_IP" ]]; then
  LAN_IP="127.0.0.1"
fi
echo "Detected LAN IP: ${LAN_IP}"

# Create directories
mkdir -p "${APP_DIR}"
mkdir -p "${BIN_DIR}"
mkdir -p "${SRV_MINECRAFT_ROOT}"
mkdir -p "${SRV_VPS_ROOT}"
mkdir -p "${SSL_DIR}"

# Update + install base packages
apt-get update -y
apt-get upgrade -y

# Install utilities and required packages
apt-get install -y curl wget gnupg2 ca-certificates lsb-release software-properties-common \
  build-essential jq git ufw

# Node.js (setup NodeSource LTS 20)
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

# npm global pm2
if ! command -v pm2 >/dev/null 2>&1; then
  npm install -g pm2@latest || true
fi

# Java for PaperMC
apt-get install -y openjdk-17-jre-headless

# nginx
apt-get install -y nginx

# docker
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

# docker-compose plugin (compose v2)
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin
fi

# jq, git already installed above
apt-get install -y jq

# certbot optional (we use self-signed for local)
apt-get install -y certbot python3-certbot-nginx || true

# ufw
apt-get install -y ufw

# Ensure ufw basic rules
ufw --force allow OpenSSH || true
ufw --force allow 80/tcp || true
ufw --force allow 443/tcp || true
ufw --force enable || true

# Create credentials (idempotent)
if [[ -f "${CRED_FILE}" ]]; then
  echo "Credentials file exists, reading..."
  ADMIN_USER="$(grep '^Admin user:' -m1 "${CRED_FILE}" | awk -F': ' '{print $2}' || echo "admin")"
  ADMIN_PASSWORD="$(grep '^Admin password:' -m1 "${CRED_FILE}" | awk -F': ' '{print $2}' || randpass)"
  JWT_SECRET="$(grep '^JWT secret:' -m1 "${CRED_FILE}" | awk -F': ' '{print $2}' || randpass)"
else
  ADMIN_USER="admin"
  ADMIN_PASSWORD="$(randpass)"
  JWT_SECRET="$(randpass)"
  {
    echo "Generated on: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "LAN IP: ${LAN_IP}"
    echo "Admin user: ${ADMIN_USER}"
    echo "Admin password: ${ADMIN_PASSWORD}"
    echo "JWT secret: ${JWT_SECRET}"
  } > "${CRED_FILE}"
  chmod 600 "${CRED_FILE}"
fi

# Add /etc/hosts entries for local hostnames (idempotent)
if ! grep -q "${MC_HOST}" /etc/hosts; then
  echo "Adding ${MC_HOST} to /etc/hosts -> ${LAN_IP}"
  echo "${LAN_IP}    ${MC_HOST} ${MC_HOST}.local" >> /etc/hosts
fi
if ! grep -q "${VPS_HOST}" /etc/hosts; then
  echo "Adding ${VPS_HOST} to /etc/hosts -> ${LAN_IP}"
  echo "${LAN_IP}    ${VPS_HOST} ${VPS_HOST}.local" >> /etc/hosts
fi
# Ensure MAIN_HOSTNAME maps too if it's not localhost
if [[ "${MAIN_HOSTNAME}" != "localhost" && ! $(grep -q "${MAIN_HOSTNAME}" /etc/hosts || true) ]]; then
  echo "${LAN_IP}    ${MAIN_HOSTNAME}" >> /etc/hosts
fi

###########################
# Helper scripts
###########################

# create_minecraft.sh
cat > "${BIN_DIR}/create_minecraft.sh" <<'MC_SH'
#!/usr/bin/env bash
set -euo pipefail
name="${1:-}"
ram_mb="${2:-2048}"
port="${3:-25565}"
srv_root="/srv/minecraft"
user="minecraft"

if [[ -z "$name" ]]; then
  echo '{"error":"name required"}'
  exit 1
fi

# create minecraft user if not exists
if ! id -u "$user" >/dev/null 2>&1; then
  useradd -m -r -s /usr/sbin/nologin "$user"
fi

mkdir -p "${srv_root}/${name}"
installdir="${srv_root}/${name}"
chown -R ${user}:${user} "${installdir}"

cd "${installdir}"

# fetch latest PaperMC version
if ! command -v jq >/dev/null 2>&1; then apt-get update -y && apt-get install -y jq; fi
versions_json=$(curl -s "https://api.papermc.io/v2/projects/paper")
version=$(echo "$versions_json" | jq -r '.versions | last')
builds_json=$(curl -s "https://api.papermc.io/v2/projects/paper/versions/${version}/builds")
build_id=$(echo "$builds_json" | jq -r '.builds | last | .build')
jar_name="paper-${version}-${build_id}.jar"
jar_url="https://api.papermc.io/v2/projects/paper/versions/${version}/builds/${build_id}/downloads/${jar_name}"

if [[ ! -f paper.jar ]]; then
  echo "Downloading PaperMC ${version} build ${build_id}..."
  curl -L --fail -o paper.jar "$jar_url" || { echo '{"error":"failed to download paper.jar"}'; exit 1; }
fi

# eula and server.properties
echo "eula=true" > eula.txt
cat > server.properties <<EOF
server-port=${port}
motd=Auto-deployed PaperMC
online-mode=true
EOF

# start script
cat > start.sh <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
exec /usr/bin/java -Xmx${RAM}M -Xms128M -jar paper.jar nogui
EOF
# Replace placeholder RAM with actual value
sed -i "s/\${RAM}/${ram_mb}/g" start.sh
chmod +x start.sh
chown ${user}:${user} start.sh paper.jar eula.txt server.properties

# systemd unit
service_name="minecraft-${name}.service"
cat > /etc/systemd/system/${service_name} <<EOF
[Unit]
Description=Minecraft PaperMC server ${name}
After=network.target

[Service]
User=${user}
WorkingDirectory=${installdir}
ExecStart=/bin/bash ${installdir}/start.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${service_name}"

echo "{\"ok\":true,\"service\":\"${service_name}\",\"path\":\"${installdir}\",\"port\":${port}}"
MC_SH
chmod +x "${BIN_DIR}/create_minecraft.sh"
ln -sf "${BIN_DIR}/create_minecraft.sh" /usr/local/bin/create_minecraft.sh

# create_vps.sh
cat > "${BIN_DIR}/create_vps.sh" <<'VPS_SH'
#!/usr/bin/env bash
set -euo pipefail
name="${1:-}"
host_ssh_port="${2:-0}"
root_pass="${3:-}"

srv_root="/srv/vps"
img_tag="local/ubuntu-sshd:latest"
build_dir="/tmp/auto_vps_build_${name}"

if [[ -z "$name" ]]; then
  echo '{"error":"name required"}'
  exit 1
fi
mkdir -p "${srv_root}/${name}"

# Build image once (idempotent)
if ! docker image inspect "${img_tag}" >/dev/null 2>&1; then
  rm -rf "${build_dir}"
  mkdir -p "${build_dir}"
  cat > "${build_dir}/Dockerfile" <<EOF
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y openssh-server passwd sudo && \\
    mkdir /var/run/sshd && \\
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config || true
EXPOSE 22
CMD ["/usr/sbin/sshd","-D"]
EOF
  docker build -t "${img_tag}" "${build_dir}"
fi

container_name="vps_${name}"

# remove existing container with same name
if docker ps -a --format '{{.Names}}' | grep -x "${container_name}" >/dev/null 2>&1; then
  echo "Container ${container_name} exists, removing..."
  docker rm -f "${container_name}" || true
fi

# choose host port
if [[ "${host_ssh_port}" -eq 0 ]]; then
  host_ssh_port=$(( 30000 + (RANDOM % 10000) ))
fi

docker run -d --name "${container_name}" -v "${srv_root}/${name}":/root -p "${host_ssh_port}":22 "${img_tag}"

# set root password if provided
if [[ -n "${root_pass}" ]]; then
  docker exec -i "${container_name}" bash -c "echo 'root:${root_pass}' | chpasswd" || true
else
  # generate random and set
  rp=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 12)
  docker exec -i "${container_name}" bash -c "echo 'root:${rp}' | chpasswd" || true
  root_pass="${rp}"
fi

echo "{\"ok\":true,\"container\":\"${container_name}\",\"host_ssh_port\":${host_ssh_port},\"root_pass\":\"${root_pass}\"}"
VPS_SH
chmod +x "${BIN_DIR}/create_vps.sh"
ln -sf "${BIN_DIR}/create_vps.sh" /usr/local/bin/create_vps.sh

###########################
# Node.js app (Express) + static UI — all in one
###########################
mkdir -p "${APP_DIR}/app"
cd "${APP_DIR}/app"

# package.json
cat > package.json <<'PKG'
{
  "name": "auto-site-backend",
  "version": "1.0.0",
  "main": "app.js",
  "dependencies": {
    "express": "^4.18.2",
    "bcrypt": "^5.1.0",
    "jsonwebtoken": "^9.0.0",
    "body-parser": "^1.20.2"
  }
}
PKG

# .env
cat > .env <<ENV
ADMIN_USER=${ADMIN_USER}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
JWT_SECRET=${JWT_SECRET}
PORT=${NODE_PORT}
ENV
chmod 600 .env

# app.js
cat > app.js <<'APPJS'
const express = require('express');
const fs = require('fs');
const path = require('path');
const { execFile, exec } = require('child_process');
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const bodyParser = require('body-parser');

require('dotenv').config({ path: path.join(__dirname, '.env') });

const ADMIN_USER = process.env.ADMIN_USER || 'admin';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || '';
const JWT_SECRET = process.env.JWT_SECRET || 'secret';
const PORT = process.env.PORT || 3000;

const app = express();
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, 'static')));

// Pre-hash admin password at startup
let adminHash = null;
(async () => {
  const salt = await bcrypt
