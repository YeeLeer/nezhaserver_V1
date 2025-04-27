#!/bin/bash

# 首次运行时执行以下流程，再次运行时存在 /etc/supervisor/conf.d/damon.conf 文件，直接到最后一步
if [ ! -s /etc/supervisor/conf.d/damon.conf ]; then
  export GH_PROXY="${GH_PROXY}"
  export GRPC_PROXY_PORT=${GRPC_PROXY_PORT:-'443'}
  export GRPC_PORT=${GRPC_PORT:-'8008'}
  export WEB_PORT=${WEB_PORT:-'80'} # 和F佬隧道设置一样
  export WORK_DIR=/dashboard

  export DASHBOARD_VERSION="${DASHBOARD_VERSION}"
  export AGENT_VERSION="${AGENT_VERSION}"
  export REVERSE_PROXY_MODE=${REVERSE_PROXY_MODE:-'caddy'} # caddy 或 nginx 二选一

  export runx=${runx:-'0'}  # runx为1时运行app，默认不运行

  # oauth2设置，选择其中之一即可
  # github 带有备份还原
  export GH_USER="${GH_USER}"
  export GH_CLIENTID="${GH_CLIENTID}"
  export GH_CLIENTSECRET="${GH_CLIENTSECRET}"
  # gitlab
  export GL_CLIENTID="${GL_CLIENTID}"
  export GL_CLIENTSECRET="${GL_CLIENTSECRET}"
  # gitee
  export GT_CLIENTID="${GT_CLIENTID}"
  export GT_CLIENTSECRET="${GT_CLIENTSECRET}"
  # Cloudflare
  export CF_CLIENTID="${CF_CLIENTID}"
  export CF_CLIENTSECRET="${CF_CLIENTSECRET}"
  export CF_AUTHURL="${CF_AUTHURL}"
  export CF_TOKENUR="${CF_TOKENUR}"
  export CF_USERINFOURL="${CF_USERINFOURL}"

  export UUID="${UUID}"  # LOCAL_TOKEN
  export agentsecretkey="${agentsecretkey}"  # nezhav1 key

  # 如不分离备份的 github 账户，默认与哪吒登陆的 github 账户一致
  GH_BACKUP_USER=${GH_BACKUP_USER:-$GH_USER}

  error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
  info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
  hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色

  # 如参数不齐全，容器退出，另外处理某些环境变量填错后的处理
  [[ -z "$GH_USER" || -z "$GH_CLIENTID" || -z "$GH_CLIENTSECRET" || -z "$ARGO_AUTH" || -z "$ARGO_DOMAIN" ]] && error " There are variables that are not set. "
  [[ "$ARGO_AUTH" =~ TunnelSecret ]] && grep -qv '"' <<< "$ARGO_AUTH" && ARGO_AUTH=$(sed 's@{@{"@g;s@[,:]@"\0"@g;s@}@"}@g' <<< "$ARGO_AUTH")  # Json 时，没有了"的处理
  [[ "$ARGO_AUTH" =~ ey[A-Z0-9a-z=]{120,250}$ ]] && ARGO_AUTH=$(awk '{print $NF}' <<< "$ARGO_AUTH") # Token 复制全部，只取最后的 ey 开始的
  [ -n "$GH_REPO" ] && grep -q '/' <<< "$GH_REPO" && GH_REPO=$(awk -F '/' '{print $NF}' <<< "$GH_REPO")  # 填了项目全路径的处理

  # 检测是否需要启用 Github CDN，如能直接连通，则不使用
  [ -n "$GH_PROXY" ] && wget --server-response --quiet --output-document=/dev/null --no-check-certificate --tries=2 --timeout=3 https://raw.githubusercontent.com/YeeLeer/nezhaserver_V1/refs/heads/main/README.md >/dev/null 2>&1 && unset GH_PROXY

  # 设置 DNS
  echo -e "nameserver 127.0.0.11\nnameserver 8.8.4.4\nnameserver 223.5.5.5\nnameserver 2001:4860:4860::8844\nnameserver 2400:3200::1\n" > /etc/resolv.conf

  # 设置 +8 时区 (北京时间)
  ln -fs /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  dpkg-reconfigure -f noninteractive tzdata

  # 判断处理器架构
  case "$(uname -m)" in
    aarch64|arm64 )
      ARCH=arm64
      ;;
    x86_64|amd64 )
      ARCH=amd64
      ;;
    * ) echo "Unsupported systems!"
  esac

  if [ ! -d "$WORK_DIR" ]; then
    mkdir -p "$WORK_DIR"
  fi

  # 下载需要的应用
  [ ! -d data ] && mkdir data

  # 用户选择使用gRPC反代方式: Nginx/Caddy
  case "$REVERSE_PROXY_MODE" in
    "caddy" )
      if [ ! -f $WORK_DIR/caddy ]; then
        # CADDY_LATEST=$(wget -qO- "${GH_PROXY}https://api.github.com/repos/caddyserver/caddy/releases/latest" | awk -F [v\"] '/"tag_name"/{print $5}' || echo '2.8.4')
        CADDY_LATEST=$(curl -sSL "${GH_PROXY}https://api.github.com/repos/caddyserver/caddy/releases/latest" | awk -F [v\"] '/"tag_name"/{print $5}' || echo '2.8.4')
        # wget -c ${GH_PROXY}https://github.com/caddyserver/caddy/releases/download/v${CADDY_LATEST}/caddy_${CADDY_LATEST}_linux_${ARCH}.tar.gz -qO- | tar xz -C $WORK_DIR caddy
        curl -sSL "${GH_PROXY}https://github.com/caddyserver/caddy/releases/download/v${CADDY_LATEST}/caddy_${CADDY_LATEST}_linux_${ARCH}.tar.gz" | tar xz -C $WORK_DIR caddy
      fi

      GRPC_PROXY_RUN="$WORK_DIR/caddy run --config $WORK_DIR/Caddyfile --watch"
      cat > $WORK_DIR/Caddyfile << EOF
:$WEB_PORT {
    reverse_proxy /* 127.0.0.1:$GRPC_PORT
}

:$GRPC_PROXY_PORT {
    reverse_proxy /proto.NezhaService/* h2c://127.0.0.1:$GRPC_PORT
    tls $WORK_DIR/nezha.pem $WORK_DIR/nezha.key
}
EOF
      ;;
    "nginx" )
      GRPC_PROXY_RUN='nginx -g "daemon off;"'
    cat > /etc/nginx/nginx.conf  << EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events {
        worker_connections 768;
        # multi_accept on;
}
http {
  upstream dashboard {
    server 127.0.0.1:$GRPC_PORT;
    keepalive 512;
  }
  server {
    listen 127.0.0.1:$GRPC_PROXY_PORT ssl http2;
    server_name $ARGO_DOMAIN;
    ssl_certificate          $WORK_DIR/nezha.pem;
    ssl_certificate_key      $WORK_DIR/nezha.key;
    ssl_stapling on;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m; # 如果与其他配置冲突，请注释此项
    ssl_protocols TLSv1.2 TLSv1.3;

    underscores_in_headers on;
    # grpc 相关
    location ^~ /proto.NezhaService/ {
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_buffer_size 4m;
        grpc_pass grpc://dashboard;
    }
    # websocket 相关
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:$GRPC_PROXY_PORT;
    }
    # web
    location / {
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_max_temp_file_size 0;
        proxy_pass http://127.0.0.1:$WEB_PORT;
    }
    access_log  /dev/null;
    error_log   /dev/null;
  }
}
EOF
      ;;
  esac

  if [ ! -f $WORK_DIR/dashboard ]; then
    if [ -n "${DASHBOARD_VERSION}" ]; then
      DASHBOARD_LATEST="${DASHBOARD_VERSION}"
    else
      DASHBOARD_LATEST=$(curl -sSL "${GH_PROXY}https://api.github.com/repos/naiba/nezha/releases/latest" | awk -F '"' '/"tag_name"/{print $4}')
    fi
    # wget -O $WORK_DIR/dashboard.zip ${GH_PROXY}https://github.com/naiba/nezha/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip
    curl -sSL ${GH_PROXY}https://github.com/naiba/nezha/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip -o $WORK_DIR/dashboard.zip
    unzip $WORK_DIR/dashboard.zip -d $WORK_DIR > /dev/null
    mv -f $WORK_DIR/dashboard-linux-$ARCH $WORK_DIR/dashboard
    rm -rf $WORK_DIR/dashboard.zip
    chmod +x $WORK_DIR/dashboard
  fi

  if [ ! -f $WORK_DIR/cloudflared ]; then
    wget -qO cloudflared ${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH
    # curl -sSL ${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH -o $WORK_DIR/cloudflared
    chmod +x $WORK_DIR/cloudflared
  fi

  if [ ! -f $WORK_DIR/nezha-agent ]; then
    if [ -n "${AGENT_VERSION}" ]; then
      AGENT_LATEST="${AGENT_VERSION}"
    else
      # AGENT_LATEST=$(wget -qO- "${GH_PROXY}https://api.github.com/repos/nezhahq/agent/releases/latest" | awk -F '"' '/"tag_name"/{print $4}')
      AGENT_LATEST=$(curl -sSL "${GH_PROXY}https://api.github.com/repos/nezhahq/agent/releases/latest" | awk -F '"' '/"tag_name"/{print $4}')
    fi
    # wget -O $WORK_DIR/nezha-agent.zip https://github.com/nezhahq/agent/releases/download/$AGENT_LATEST/nezha-agent_linux_$ARCH.zip
    curl -sSL ${GH_PROXY}https://github.com/nezhahq/agent/releases/download/$AGENT_LATEST/nezha-agent_linux_$ARCH.zip -o $WORK_DIR/nezha-agent.zip
    unzip $WORK_DIR/nezha-agent.zip -d $WORK_DIR > /dev/null
    rm -rf $WORK_DIR/nezha-agent.zip
    chmod +x $WORK_DIR/nezha-agent
  fi

  case "$runx" in
    "1" )
      if [ ! -f $WORK_DIR/app ]; then
        # wget -q -O $WORK_DIR/app ${GH_PROXY}https://github.com/kahunama/myfile/releases/download/xraymini/web_$ARCH
        curl -sSL ${GH_PROXY}https://github.com/kahunama/myfile/releases/download/xraymini/web_$ARCH -o $WORK_DIR/app
        chmod +x $WORK_DIR/app
      fi
      ;;
  esac

  # 根据参数生成哪吒服务端配置文件
  cat > ./data/config.yaml << EOF
debug: false
realipheader: ""
language: zh-CN
sitename: Nazha Probe
user_template: user-dist
admin_template: admin-dist
jwt_secret_key: $jwtsecretkey
jwt_timeout: 1
agent_secret_key: $agentsecretkey
avg_ping_count: 2
cover: 1
https: {}
listenport: $GRPC_PORT
installhost: $ARGO_DOMAIN:$GRPC_PROXY_PORT
tls: true
location: Asia/Shanghai
oauth2:
  GitHub:
    clientid: "$GH_CLIENTID"
    clientsecret: "$GH_CLIENTSECRET"
    endpoint:
      authurl: "https://github.com/login/oauth/authorize"
      tokenurl: "https://github.com/login/oauth/access_token"
    userinfourl: "https://api.github.com/user"
    useridpath: "id"
  GitLab:
    clientid: "$GL_CLIENTID"
    clientsecret: "$GL_CLIENTSECRET"
    endpoint:
      authurl: "https://gitlab.com/oauth/authorize"
      tokenurl: "https://gitlab.com/oauth/token"
    scopes:
      - read_user
    userinfourl: "https://gitlab.com/api/v4/user"
    useridpath: "id"
  Gitee:
    clientid: "$GT_CLIENTID"
    clientsecret: "$GT_CLIENTSECRET"
    endpoint:
      authurl: "https://gitee.com/oauth/authorize"
      tokenurl: "https://gitee.com/oauth/token"
    scopes:
      - user_info
    userinfourl: "https://gitee.com/api/v5/user"
    useridpath: "id"
  Cloudflare:
    clientid: "$CF_CLIENTID"
    clientsecret: "$CF_CLIENTSECRET"
    endpoint:
      authurl: "$CF_AUTHURL"
      tokenurl: "$CF_TOKENUR"
    scopes:
      - openid
      - profile
    userinfourl: "$CF_USERINFOURL"
    useridpath: "sub"
EOF

  cat > $WORK_DIR/config.yml << EOF
client_secret: $agentsecretkey
debug: false
disable_auto_update: false
disable_command_execute: false
disable_force_update: false
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 4
server: 127.0.0.1:$GRPC_PORT
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: false
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $UUID
EOF

  # SSH path 与 GH_CLIENTSECRET 一样
  echo root:"$GH_CLIENTSECRET" | chpasswd root
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g;s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  service ssh restart

  # 判断 ARGO_AUTH 为 json 还是 token
  # 如为 json 将生成 argo.json 和 argo.yml 文件
  if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
    ARGO_RUN="$WORK_DIR/cloudflared --edge-ip-version auto --config $WORK_DIR/argo.yml run"

    echo "$ARGO_AUTH" > $WORK_DIR/argo.json

    cat > $WORK_DIR/argo.yml << EOF
tunnel: $(cut -d '"' -f12 <<< "$ARGO_AUTH")
credentials-file: $WORK_DIR/argo.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: https://localhost:$GRPC_PROXY_PORT
    path: /proto.NezhaService/*
    originRequest:
      http2Origin: true
      noTLSVerify: true
  - hostname: $ARGO_DOMAIN
    service: ssh://localhost:22
    path: /$GH_CLIENTID/*
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$WEB_PORT
  - service: http_status:404
EOF

  # 如为 token 时
  elif [[ "$ARGO_AUTH" =~ ^ey[A-Z0-9a-z=]{120,250}$ ]]; then
    ARGO_RUN="$WORK_DIR/cloudflared tunnel --edge-ip-version auto --protocol http2 run --token ${ARGO_AUTH}"
  fi

  # 生成自签署SSL证书
  openssl genrsa -out $WORK_DIR/nezha.key 2048 > /dev/null 2>&1
  openssl req -new -subj "/CN=$ARGO_DOMAIN" -key $WORK_DIR/nezha.key -out $WORK_DIR/nezha.csr > /dev/null 2>&1
  openssl x509 -req -days 36500 -in $WORK_DIR/nezha.csr -signkey $WORK_DIR/nezha.key -out $WORK_DIR/nezha.pem > /dev/null 2>&1

  # 生成 backup.sh 文件的步骤1 - 设置环境变量
  cat > $WORK_DIR/backup.sh << EOF
#!/usr/bin/env bash

# backup.sh 传参 a 自动还原； 传参 m 手动还原； 传参 f 强制更新面板 app 文件及 cloudflared 文件，并备份数据至成备份库

GH_PROXY=$GH_PROXY
GH_PAT=$GH_PAT
GH_BACKUP_USER=$GH_BACKUP_USER
GH_EMAIL=$GH_EMAIL
GH_REPO=$GH_REPO
ARCH=$ARCH
WORK_DIR=$WORK_DIR
DAYS=5
IS_DOCKER=1
DASHBOARD_VERSION=$DASHBOARD_VERSION

########
EOF

  # 生成 backup.sh 文件的步骤2 - 在线获取 template/bakcup.sh 模板生成完整 backup.sh 文件
  # wget -qO- ${GH_PROXY}https://raw.githubusercontent.com/YeeLeer/nezhaserver_V1/refs/heads/main/template/backup.sh | sed '1,/^########/d' >> $WORK_DIR/backup.sh
  curl -sSL ${GH_PROXY}https://raw.githubusercontent.com/YeeLeer/nezhaserver_V1/refs/heads/main/template/backup.sh | sed '1,/^########/d' >> $WORK_DIR/backup.sh

  if [[ -n "$GH_BACKUP_USER" && -n "$GH_EMAIL" && -n "$GH_REPO" && -n "$GH_PAT" ]]; then
    # 生成 restore.sh 文件的步骤1 - 设置环境变量
    cat > $WORK_DIR/restore.sh << EOF
#!/usr/bin/env bash

# restore.sh 传参 a 自动还原 README.md 记录的文件，当本地与远程记录文件一样时不还原； 传参 f 不管本地记录文件，强制还原成备份库里 README.md 记录的文件； 传参 dashboard-***.tar.gz 还原成备份库里的该文件；不带参数则要求选择备份库里的文件名

GH_PROXY=$GH_PROXY
GH_PAT=$GH_PAT
GH_BACKUP_USER=$GH_BACKUP_USER
GH_REPO=$GH_REPO
WORK_DIR=$WORK_DIR
TEMP_DIR=/tmp/restore_temp
NO_ACTION_FLAG=/tmp/flag
IS_DOCKER=1

########
EOF

    # 生成 restore.sh 文件的步骤2 - 在线获取 template/restore.sh 模板生成完整 restore.sh 文件
    # wget -qO- ${GH_PROXY}https://raw.githubusercontent.com/YeeLeer/nezhaserver_V1/refs/heads/main/template/restore.sh | sed '1,/^########/d' >> $WORK_DIR/restore.sh
    curl -sSL ${GH_PROXY}https://raw.githubusercontent.com/YeeLeer/nezhaserver_V1/refs/heads/main/template/restore.sh | sed '1,/^########/d' >> $WORK_DIR/restore.sh
  fi

  # 生成 renew.sh 文件的步骤1 - 设置环境变量
  cat > $WORK_DIR/renew.sh << EOF
#!/usr/bin/env bash

GH_PROXY=$GH_PROXY
WORK_DIR=/dashboard
TEMP_DIR=/tmp/renew

########
EOF

  # 生成 renew.sh 文件的步骤2 - 在线获取 template/renew.sh 模板生成完整 renew.sh 文件
  # wget -qO- ${GH_PROXY}https://raw.githubusercontent.com/YeeLeer/nezhaserver_V1/refs/heads/main/template/renew.sh | sed '1,/^########/d' >> $WORK_DIR/renew.sh
  curl -sSL ${GH_PROXY}https://raw.githubusercontent.com/YeeLeer/nezhaserver_V1/refs/heads/main/template/renew.sh | sed '1,/^########/d' >> $WORK_DIR/renew.sh

  # 生成定时任务: 1.每天北京时间 3:30:00 更新备份和还原文件，2.每天北京时间 4:00:00 备份一次，并重启 cron 服务； 3.每分钟自动检测在线备份文件里的内容
  [ -z "$NO_AUTO_RENEW" ] && [ -s $WORK_DIR/renew.sh ] && ! grep -q "$WORK_DIR/renew.sh" /etc/crontab && echo "30 3 * * * root bash $WORK_DIR/renew.sh" >> /etc/crontab
  [ -s $WORK_DIR/backup.sh ] && ! grep -q "$WORK_DIR/backup.sh" /etc/crontab && echo "0 4 * * * root bash $WORK_DIR/backup.sh a" >> /etc/crontab
  [ -s $WORK_DIR/restore.sh ] && ! grep -q "$WORK_DIR/restore.sh" /etc/crontab && echo "* * * * * root bash $WORK_DIR/restore.sh a" >> /etc/crontab
  service cron restart

  # 生成 supervisor 进程守护配置文件
  cat > /etc/supervisor/conf.d/damon.conf << EOF
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/run/supervisord.pid

[program:grpcproxy]
command=$GRPC_PROXY_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:nezha]
command=$WORK_DIR/dashboard
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:agent]
command=$WORK_DIR/nezha-agent -c $WORK_DIR/config.yml
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null

[program:argo]
command=$ARGO_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null
EOF

  # 赋执行权给 sh
  chmod +x $WORK_DIR/*.sh
fi

# 运行 supervisor 进程守护
supervisord -c /etc/supervisor/supervisord.conf

case "$runx" in
  "1" )
    $WORK_DIR/app > /dev/null 2>&1 &
    ;;
esac
