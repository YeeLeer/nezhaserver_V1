#!/bin/bash

# 首次运行时执行以下流程，再次运行时存在 /etc/supervisor/conf.d/damon.conf 文件，直接到最后一步
if [ ! -s /etc/supervisor/conf.d/damon.conf ]; then
  # 固定变量一般不用改
  export ENABLE_ARGO=${ENABLE_ARGO:-'true'} # true or false  #为true时开启argo.不受ipv4,ipv6限制.为false时不使用argo,直接面板 默认8008, nat_vps需cdn_rule到GRPC_PORT端口
  export GRPC_PROXY_PORT=${GRPC_PROXY_PORT:-'443'} # 不用改
  export GRPC_PORT=${GRPC_PORT:-'8008'} # 不用改
  export WEB_PORT=${WEB_PORT:-'80'} # 和F佬隧道设置一样  # 不用改
  export WORK_DIR=/dashboard

  export DASHBOARD_VERSION="${DASHBOARD_VERSION}"
  export AGENT_VERSION="${AGENT_VERSION}"
  export runx=${runx:-'0'}  # runx为1时运行app，默认不运行

  # GitHub 下载加速镜像（可空，如 https://ghproxy.com/ 或 https://mirror.ghproxy.com/）
  export GH_PROXY="${GH_PROXY}"
  # 面板时区（用于 config.yaml 的 location 字段）
  export TZ=${TZ:-'Asia/Shanghai'}

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

  # 自己填写这段变量
  export UUID="${UUID}"  # LOCAL_TOKEN
  export AGENT_KEY="${AGENT_KEY:-$agentsecretkey}"  # nezhav1 key (兼容旧变量名 agentsecretkey)
  export ARGO_DOMAIN="${ARGO_DOMAIN}"  # nezhav1域名
  export ARGO_AUTH="${ARGO_AUTH}"
  export MY_DOMAIN="${MY_DOMAIN}"  # 直连时cdn域名

  # 如不分离备份的 github 账户，默认与哪吒登陆的 github 账户一致
  GH_BACKUP_USER=${GH_BACKUP_USER:-$GH_USER}

  error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
  info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
  hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色

  # 安全删除：路径为空时跳过，路径加引号，拒绝删除系统关键路径
  safe_rm() {
    local target
    for target in "$@"; do
      [ -z "$target" ] && continue
      # 保护：拒绝删除根目录与系统关键目录（防路径配置错误导致灾难）
      case "$target" in
        /|/etc|/var|/usr|/bin|/sbin|/lib|/lib64|/dev|/proc|/sys|/run|/root)
          hint "安全保护: 拒绝删除系统关键路径 $target"
          continue
          ;;
      esac
      # -e 跟随符号链接，损坏的链接（dangling）需用 -L 判断，否则删不掉
      { [ -e "$target" ] || [ -L "$target" ]; } && rm -rf -- "$target"
    done
  }

  # 如参数不齐全，容器退出，另外处理某些环境变量填错后的处理
  [[ -z "$GH_USER" || -z "$GH_CLIENTID" || -z "$GH_CLIENTSECRET" ]] && error " There are variables that are not set. "
  if [ "${ENABLE_ARGO}" = "true" ]; then
    [[ -z "$ARGO_AUTH" || -z "$ARGO_DOMAIN" ]] && error " ENABLE_ARGO=true 时 ARGO_AUTH 和 ARGO_DOMAIN 必须设置. "
  fi
  [[ "$ARGO_AUTH" =~ TunnelSecret ]] && grep -qv '"' <<< "$ARGO_AUTH" && ARGO_AUTH=$(sed 's@{@{"@g;s@[,:]@"\0"@g;s@}@"}@g' <<< "$ARGO_AUTH")  # Json 时，没有了"的处理
  [[ "$ARGO_AUTH" =~ ey[A-Z0-9a-z=]{120,250}$ ]] && ARGO_AUTH=$(awk '{print $NF}' <<< "$ARGO_AUTH") # Token 复制全部，只取最后的 ey 开始的
  [ -n "$GH_REPO" ] && grep -q '/' <<< "$GH_REPO" && GH_REPO=$(awk -F '/' '{print $NF}' <<< "$GH_REPO")  # 填了项目全路径的处理

  # 检测是否需要启用 Github CDN，如能直接连通，则不使用
  [ -n "$GH_PROXY" ] && wget --server-response --quiet --output-document=/dev/null --no-check-certificate --tries=2 --timeout=3 https://raw.githubusercontent.com/YeeLeer/nezhaserver_V1/refs/heads/main/README.md >/dev/null 2>&1 && unset GH_PROXY

  # 设置 DNS
  echo -e "nameserver 127.0.0.11\nnameserver 8.8.4.4\nnameserver 223.5.5.5\nnameserver 2001:4860:4860::8844\nnameserver 2400:3200::1\n" > /etc/resolv.conf

  # 设置时区（默认 +8 北京时间，可通过 TZ 变量修改）
  echo "$TZ" > /etc/timezone
  ln -fs /usr/share/zoneinfo/$TZ /etc/localtime
  dpkg-reconfigure -f noninteractive tzdata

  # 判断处理器架构
  case "$(uname -m)" in
    aarch64|arm64 )
      ARCH=arm64
      ;;
    x86_64|amd64 )
      ARCH=amd64
      ;;
    * ) echo "Unsupported systems!" && exit 1
  esac

  if [ ! -d "$WORK_DIR" ]; then
    mkdir -p "$WORK_DIR"
  fi

  # 下载需要的应用
  [ ! -d data ] && mkdir data

  # 获取 GitHub 最新 release 版本号（通用 sed 解析，兼容 GNU/busybox）
  get_latest_release() {
    curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 \
      "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
  }

  # Caddy（仅 ENABLE_ARGO=true 时需要）
  if [ "${ENABLE_ARGO}" = "true" ] && [ ! -f $WORK_DIR/caddy ]; then
    CADDY_LATEST=$(get_latest_release "caddyserver/caddy")
    if [ -z "$CADDY_LATEST" ]; then
      error "获取 caddy 最新版本失败，请检查网络后重试"
    fi
    CADDY_LATEST=${CADDY_LATEST#v}
    curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 "${GH_PROXY}https://github.com/caddyserver/caddy/releases/download/v${CADDY_LATEST}/caddy_${CADDY_LATEST}_linux_${ARCH}.tar.gz" | tar xz -C $WORK_DIR caddy
    chmod +x $WORK_DIR/caddy
  fi

  if [ "${ENABLE_ARGO}" = "true" ]; then
    GRPC_PROXY_RUN="$WORK_DIR/caddy run --config $WORK_DIR/Caddyfile"
    cat > $WORK_DIR/Caddyfile << EOF
{
    admin off
    log {
        level ERROR
    }
}

:$WEB_PORT {
    reverse_proxy /* 127.0.0.1:$GRPC_PORT
}

:$GRPC_PROXY_PORT {
    reverse_proxy /proto.NezhaService/* h2c://127.0.0.1:$GRPC_PORT
    tls $WORK_DIR/nezha.pem $WORK_DIR/nezha.key
}
EOF
  fi

  if [ ! -f $WORK_DIR/dashboard ]; then
    if [ -n "${DASHBOARD_VERSION}" ]; then
      DASHBOARD_LATEST="${DASHBOARD_VERSION}"
    else
      DASHBOARD_LATEST=$(get_latest_release "nezhahq/nezha")
    fi
    if [ -z "$DASHBOARD_LATEST" ]; then
      error "获取 dashboard 最新版本失败，请检查网络后重试"
    fi
    curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 "${GH_PROXY}https://github.com/nezhahq/nezha/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip" -o $WORK_DIR/dashboard.zip
    unzip $WORK_DIR/dashboard.zip -d $WORK_DIR > /dev/null
    mv -f $WORK_DIR/dashboard-linux-$ARCH $WORK_DIR/dashboard
    safe_rm "$WORK_DIR"/dashboard.zip
    chmod +x $WORK_DIR/dashboard
  fi

  # cloudflared（仅 ENABLE_ARGO=true 时需要）
  if [ "${ENABLE_ARGO}" = "true" ] && [ ! -f $WORK_DIR/cloudflared ]; then
    curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 "${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH" -o $WORK_DIR/cloudflared
    chmod +x $WORK_DIR/cloudflared
  fi

  if [ ! -f $WORK_DIR/nezha-agent ]; then
    if [ -n "${AGENT_VERSION}" ]; then
      AGENT_LATEST="${AGENT_VERSION}"
    else
      AGENT_LATEST=$(get_latest_release "nezhahq/agent")
    fi
    if [ -z "$AGENT_LATEST" ]; then
      error "获取 nezha-agent 最新版本失败，请检查网络后重试"
    fi
    curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 "${GH_PROXY}https://github.com/nezhahq/agent/releases/download/$AGENT_LATEST/nezha-agent_linux_$ARCH.zip" -o $WORK_DIR/nezha-agent.zip
    unzip $WORK_DIR/nezha-agent.zip -d $WORK_DIR > /dev/null
    safe_rm "$WORK_DIR"/nezha-agent.zip
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

  # 直连时若未填 ARGO_DOMAIN，使用 MY_DOMAIN
  if [ -n "$MY_DOMAIN" ] && [ -z "${ARGO_DOMAIN}" ]; then
    export ARGO_DOMAIN="$MY_DOMAIN"
  fi

  # 根据参数生成哪吒服务端配置文件
  if [ "${ENABLE_ARGO}" = "true" ]; then
    tls="true"
  else
    tls="false"
  fi
  cat > ./data/config.yaml << EOF
admin_template: admin-dist
agent_secret_key: $AGENT_KEY
avg_ping_count: 2
cover: 1
https: {}
ip_change_notification_group_id: 0
jwt_timeout: 1
language: zh-CN
listen_port: $GRPC_PORT
install_host: $ARGO_DOMAIN:$GRPC_PROXY_PORT
tls: $tls
location: $TZ
memory: {}
site_name: "Nazha Probe"
tsdb: {}
user_template: user-dist
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
  chmod 600 ./data/config.yaml

  cat > $WORK_DIR/config.yml << EOF
client_secret: $AGENT_KEY
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
  chmod 600 $WORK_DIR/config.yml

  # SSH path 与 GH_CLIENTSECRET 一样
  echo root:"$GH_CLIENTSECRET" | chpasswd root
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g;s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  service ssh restart

  if [ "${ENABLE_ARGO}" = "true" ]; then
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
  fi

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
ENABLE_ARGO=$ENABLE_ARGO

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
ENABLE_ARGO=$ENABLE_ARGO

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

  # 生成 supervisor 进程守护配置文件（ENABLE_ARGO=false 时不含 caddy/argo 进程）
  cat > /etc/supervisor/conf.d/damon.conf << EOF
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/run/supervisord.pid
EOF
  if [ "${ENABLE_ARGO}" = "true" ]; then
    cat >> /etc/supervisor/conf.d/damon.conf << EOF

[program:grpcproxy]
command=$GRPC_PROXY_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null
EOF
  fi
  cat >> /etc/supervisor/conf.d/damon.conf << EOF

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
EOF
  if [ "${ENABLE_ARGO}" = "true" ]; then
    cat >> /etc/supervisor/conf.d/damon.conf << EOF

[program:argo]
command=$ARGO_RUN
autostart=true
autorestart=true
stderr_logfile=/dev/null
stdout_logfile=/dev/null
EOF
  fi

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
