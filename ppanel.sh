#!/bin/bash
set -e

# ============ 1. 系统准备 ============
echo "🛠️ 正在更新系统并安装依赖..."
apt update && apt install -y git curl wget vim socat nginx

systemctl enable --now nginx

# ============ 2. 安装 Docker & Compose ============
echo "🐳 安装 Docker 和 Docker Compose..."
git clone https://github.com/slobys/docker.git /tmp/docker
chmod +x /tmp/docker/docker.sh
/tmp/docker/docker.sh
systemctl enable --now docker

# ============ 3. 安装 acme.sh ============
echo "🔐 安装 acme.sh..."
curl https://get.acme.sh | sh -s
export PATH="$HOME/.acme.sh:$PATH"

# ============ 4. 设置域名变量 ============
ADMIN_DOMAIN=admin.youdomain.com
API_DOMAIN=api.youdomain.com
USER_DOMAIN=user.youdomain.com

# ============ 5. 写入 Nginx 临时验证配置 ============
echo "📝 配置 Nginx 验证..."
mkdir -p /etc/nginx/conf.d/
cat > /etc/nginx/conf.d/ppanel.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $ADMIN_DOMAIN $API_DOMAIN $USER_DOMAIN;

    location /.well-known/acme-challenge {
        root /opt/ppanel;
    }
}
EOF

nginx -t && nginx -s reload

# ============ 6. 申请证书 ============
echo "📜 申请 SSL 证书..."
mkdir -p /opt/ppanel/.well-known/acme-challenge
mkdir -p /opt/ppanel/certs

~/.acme.sh/acme.sh --issue --server letsencrypt \
  -d $ADMIN_DOMAIN -d $API_DOMAIN -d $USER_DOMAIN \
  -w /opt/ppanel

~/.acme.sh/acme.sh --install-cert -d $ADMIN_DOMAIN \
  --key-file /opt/ppanel/certs/key.pem \
  --fullchain-file /opt/ppanel/certs/cert.pem \
  --reloadcmd "systemctl reload nginx"

# ============ 7. 设置自动续期 ============
echo "⏰ 设置自动续期任务..."
echo "10 1 * * * root ~/.acme.sh/acme.sh --renew -d $ADMIN_DOMAIN -d $API_DOMAIN -d $USER_DOMAIN --force &> /dev/null" > /etc/cron.d/ppanel_domain
chmod +x /etc/cron.d/ppanel_domain

# ============ 8. 写入正式 Nginx HTTPS 配置 ============
echo "🔐 配置 Nginx HTTPS..."
cat > /etc/nginx/conf.d/ppanel.conf <<EOF
# HTTP 重定向
server {
    listen 80;
    listen [::]:80;
    server_name $ADMIN_DOMAIN $USER_DOMAIN $API_DOMAIN;
    return 301 https://\$host\$request_uri;
}

# Admin 面板
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $ADMIN_DOMAIN;

    ssl_certificate /opt/ppanel/certs/cert.pem;
    ssl_certificate_key /opt/ppanel/certs/key.pem;

    location /.well-known/acme-challenge {
        root /opt/ppanel;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# API 服务
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $API_DOMAIN;

    ssl_certificate /opt/ppanel/certs/cert.pem;
    ssl_certificate_key /opt/ppanel/certs/key.pem;

    location /.well-known/acme-challenge {
        root /opt/ppanel;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# 用户页面
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $USER_DOMAIN;

    ssl_certificate /opt/ppanel/certs/cert.pem;
    ssl_certificate_key /opt/ppanel/certs/key.pem;

    location /.well-known/acme-challenge {
        root /opt/ppanel;
    }

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

nginx -t && nginx -s reload

# ============ 9. 部署 PPanel 容器 ============
echo "🐳 拉取并部署 PPanel Docker 服务..."
cd /opt/ppanel
git clone https://github.com/perfect-panel/ppanel-script.git
cd ppanel-script
cp docker-compose.yml{,.bak}

# 修改 docker-compose.yml 的 API 地址等建议手动完成，或你告诉我是否自动写入

# 启动服务
docker compose up -d

echo "✅ 安装完成！请访问：https://$ADMIN_DOMAIN"
