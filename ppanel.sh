#!/bin/bash
set -e

echo "🧭 请输入三个绑定的域名："
read -p "后台管理域名 (如 admin.example.com): " ADMIN_DOMAIN
read -p "API 接口域名 (如 api.example.com): " API_DOMAIN
read -p "用户前端域名 (如 user.example.com): " USER_DOMAIN

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

# ============ 4. 写入临时 Nginx 验证配置 ============
echo "📝 配置 Nginx 验证路径..."
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

# ============ 5. 申请证书 ============
echo "📜 正在申请 SSL 证书..."
mkdir -p /opt/ppanel/.well-known/acme-challenge
mkdir -p /opt/ppanel/certs

~/.acme.sh/acme.sh --issue --server letsencrypt \
  -d $ADMIN_DOMAIN -d $API_DOMAIN -d $USER_DOMAIN \
  -w /opt/ppanel

~/.acme.sh/acme.sh --install-cert -d $ADMIN_DOMAIN \
  --key-file       /opt/ppanel/certs/key.pem \
  --fullchain-file /opt/ppanel/certs/cert.pem \
  --reloadcmd      "systemctl reload nginx"

# ============ 6. 设置自动续期 ============
echo "⏰ 配置自动续期任务..."
echo "10 1 * * * root ~/.acme.sh/acme.sh --renew -d $ADMIN_DOMAIN -d $API_DOMAIN -d $USER_DOMAIN --force &> /dev/null" > /etc/cron.d/ppanel_domain
chmod +x /etc/cron.d/ppanel_domain

# ============ 7. 写入正式 Nginx HTTPS 配置 ============
echo "🔐 配置 Nginx HTTPS..."
cat > /etc/nginx/conf.d/ppanel.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $ADMIN_DOMAIN $USER_DOMAIN $API_DOMAIN;
    return 301 https://\$host\$request_uri;
}

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

# ============ 8. 部署 PPanel Docker 服务 ============
echo "🐳 启动 PPanel 服务..."
cd /opt/ppanel
git clone https://github.com/perfect-panel/ppanel-script.git || true
cd ppanel-script

# ============ 9. 写入自定义 docker-compose.yml ============
echo "📝 备份并覆盖 docker-compose.yml ..."
cp /opt/ppanel/ppanel-script/docker-compose.yml{,.bak} || true
cat > /opt/ppanel/ppanel-script/docker-compose.yml <<EOF
services:
  ppanel-server:
    image: ppanel/ppanel-server:beta
    container_name: ppanel-server-beta
    ports:
      - '8080:8080'
    volumes:
      - ./config/ppanel.yaml:/opt/ppanel/ppanel-script/config/ppanel.yaml
    restart: always
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - ppanel-network
  mysql:
    image: mysql:8.0.23
    container_name: mysql_db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: my_database
      MYSQL_USER: user
      MYSQL_PASSWORD: userpassword
    ports:
      - "3306:3306"
    volumes:
      - ./docker/mysql:/var/lib/mysql
    command: --default-authentication-plugin=mysql_native_password --bind-address=0.0.0.0
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot","-prootpassword"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - ppanel-network
  redis:
    image: redis:7
    container_name: redis_cache
    restart: always
    ports:
      - "6379:6379"
    volumes:
      - ./docker/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - ppanel-network
  ppanel-admin-web:
    image: ppanel/ppanel-admin-web:latest
    container_name: ppanel-admin-web
    ports:
      - '3000:3000'
    environment:
      NEXT_PUBLIC_API_URL: https://$API_DOMAIN

  ppanel-user-web:
    image: ppanel/ppanel-user-web:latest
    container_name: ppanel-user-web
    ports:
      - '3001:3000'
    environment:
      NEXT_PUBLIC_API_URL: https://$API_DOMAIN
      
networks:
  ppanel-network:
    driver: bridge
EOF

# ============ 10. 修改 config/ppanel.yaml 数据库用户名密码 ============
echo "🔧 更新 ppanel.yaml 中的数据库用户名与密码 ..."
if [ -f /opt/ppanel/ppanel-script/config/ppanel.yaml ]; then
  sed -i "s/^\\s*Username:.*/  Username: user/" /opt/ppanel/ppanel-script/config/ppanel.yaml
  sed -i "s/^\\s*Password:.*/  Password: aws123456/" /opt/ppanel/ppanel-script/config/ppanel.yaml
else
  echo "⚠️ 未找到 /opt/ppanel/ppanel-script/config/ppanel.yaml，跳过修改"
fi

# ============ 11. 启动服务 ============
docker compose up -d

# ...安装与启动容器的代码...

echo ""
echo "✅ 安装完成！"
echo ""
echo "📍 后台管理地址: https://$ADMIN_DOMAIN"
echo "📍 初始化地址（API 页面）: https://$API_DOMAIN/init"
echo ""
echo "🚀 初始化页面填写参考（复制用）："
echo ""
echo "🛢 MySQL 配置"
echo "数据库主机: mysql_db"
echo "数据库端口: 3306"
echo "数据库用户: user"
echo "数据库密码: aws123456"
echo "数据库名称: my_database"
echo ""
echo "🔁 Redis 配置"
echo "Redis 主机: redis_cache"
echo "Redis 端口: 6379"
echo "Redis 密码: （留空）"
echo "---------------------------------------------"
echo ""
echo "✨ 请在浏览器访问上述初始化页面，填入以上信息后完成首次配置。"
echo ""
