#!/bin/bash

# 定义颜色函数
red() { echo -e "\e[1;91m$1\e[0m"; }
green() { echo -e "\e[1;32m$1\e[0m"; }
yellow() { echo -e "\e[1;33m$1\e[0m"; }
purple() { echo -e "\e[1;35m$1\e[0m"; }
# reading() { read -p "$(red "$1")" "$2"; }

# 固定变量一般不用改
export ENABLE_ARGO=${ENABLE_ARGO:-'true'} # true or false  #为true时开启argo.不受ipv4,ipv6限制.为false时不使用argo,直接面板 默认8008, nat_vps需cdn_rule到GRPC_PORT端口
export GRPC_PROXY_PORT=${GRPC_PROXY_PORT:-'443'} # 不用改
export GRPC_PORT=${GRPC_PORT:-'8008'} # 不用改
export WEB_PORT=${WEB_PORT:-'80'} # 和F佬隧道设置一样  # 不用改
export FILE_PATH=${FILE_PATH:-'/root/dashboard'}
export DASHBOARD_VERSION=${DASHBOARD_VERSION:-''}  # 不用改
export AGENT_VERSION=${AGENT_VERSION:-''}  # 不用改

# oauth2设置，选择其中之一即可,不填的使用admin
# github
export GH_CLIENTID=${GH_CLIENTID:-''}
export GH_CLIENTSECRET=${GH_CLIENTSECRET:-''}
# gitlab
export GL_CLIENTID=${GL_CLIENTID:-''}
export GL_CLIENTSECRET=${GL_CLIENTSECRET:-''}
# gitee
export GT_CLIENTID=${GT_CLIENTID:-''}
export GT_CLIENTSECRET=${GT_CLIENTSECRET:-''}
# Cloudflare
export CF_CLIENTID=${CF_CLIENTID:-''}
export CF_CLIENTSECRET=${CF_CLIENTSECRET:-''}
export CF_AUTHURL=${CF_AUTHURL:-''}
export CF_TOKENUR=${CF_TOKENUR:-''}
export CF_USERINFOURL=${CF_USERINFOURL:-''}

# GitHub 下载加速镜像（可空，如 https://ghproxy.com/ 或 https://mirror.ghproxy.com/）
export GH_PROXY=${GH_PROXY:-''}
# 面板时区（用于 config.yaml 的 location 字段）
export TZ=${TZ:-'Asia/Shanghai'}

# 自己填写这段变量
export UUID=${UUID:-''} # LOCAL_TOKEN
export AGENT_KEY=${AGENT_KEY:-''}  # nezhav1 key
export ARGO_DOMAIN=${ARGO_DOMAIN:-''}  # nezhav1域名
export ARGO_AUTH=${ARGO_AUTH:-''}
export MY_DOMAIN=${MY_DOMAIN:-''}  # 直连时cdn域名

# GitHub 备份还原设置（可选，填了 GH_PAT/GH_EMAIL/GH_REPO 才生成 restore.sh 并开启定时备份还原）
export GH_USER=${GH_USER:-''}
export GH_PAT=${GH_PAT:-''}
export GH_EMAIL=${GH_EMAIL:-''}
export GH_REPO=${GH_REPO:-''}
export GH_BACKUP_USER=${GH_BACKUP_USER:-$GH_USER}
export NO_AUTO_RENEW=${NO_AUTO_RENEW:-''}

# 检查是否为root下运行
if [ "$(id -u)" != 0 ]; then
  red "请在root用户下运行脚本"
  exit 1
fi

# 安全删除：路径为空时跳过，路径加引号，拒绝删除系统关键路径
safe_rm() {
  local target
  for target in "$@"; do
    [ -z "$target" ] && continue
    # 保护：拒绝删除根目录与系统关键目录（防 FILE_PATH 配置错误导致灾难）
    case "$target" in
      /|/etc|/var|/usr|/bin|/sbin|/lib|/lib64|/dev|/proc|/sys|/run|/root)
        red "安全保护: 拒绝删除系统关键路径 $target"
        continue
        ;;
    esac
    # -e 跟随符号链接，损坏的链接（dangling）需用 -L 判断，否则删不掉
    { [ -e "$target" ] || [ -L "$target" ]; } && rm -rf -- "$target"
  done
}

# 建立运行目录
createfolder() {
  if [ ! -d "$FILE_PATH" ]; then
    mkdir -p "$FILE_PATH"
  fi
}

# 建立必要的数据目录
[ ! -d /data ] && mkdir /data

# 停止移除服务
stop_services() {
  if [ -f /etc/alpine-release ]; then
    rc-service dashboard stop
    rc-update del dashboard default
    pkill -TERM -f "${FILE_PATH}/dashboard" >/dev/null 2>&1 || true
    sleep 1
    pkill -KILL -f "${FILE_PATH}/dashboard" >/dev/null 2>&1 || true

    rc-service nezha-agent stop
    rc-update del nezha-agent default
    pkill -TERM -f "${FILE_PATH}/nezha-agent" >/dev/null 2>&1 || true
    sleep 1
    pkill -KILL -f "${FILE_PATH}/nezha-agent" >/dev/null 2>&1 || true
    if [ "${ENABLE_ARGO}" = "true" ]; then
      rc-service argo stop
      rc-update del argo default
      pkill -TERM -f "${FILE_PATH}/argo" >/dev/null 2>&1 || true
      sleep 1
      pkill -KILL -f "${FILE_PATH}/argo" >/dev/null 2>&1 || true

      rc-service caddy stop
      rc-update del caddy default
      pkill -TERM -f "${FILE_PATH}/caddy" >/dev/null 2>&1 || true
      sleep 1
      pkill -KILL -f "${FILE_PATH}/caddy" >/dev/null 2>&1 || true
    fi
  else
    systemctl stop dashboard 2>/dev/null || true
    systemctl disable dashboard 2>/dev/null || true
    systemctl stop nezha-agent 2>/dev/null || true
    systemctl disable nezha-agent 2>/dev/null || true
    if [ "${ENABLE_ARGO}" = "true" ]; then
      systemctl stop argo 2>/dev/null || true
      systemctl disable argo 2>/dev/null || true
      systemctl stop caddy 2>/dev/null || true
      systemctl disable caddy 2>/dev/null || true
    fi
  fi
}

# 清理文件
cleanup_files() {
  safe_rm "${FILE_PATH}"/config.yml
  if [ -f /etc/alpine-release ]; then
    safe_rm /etc/init.d/dashboard /etc/init.d/nezha-agent
    if [ "${ENABLE_ARGO}" = "true" ]; then
      safe_rm /etc/init.d/argo /etc/init.d/caddy
    fi
  else
    safe_rm /etc/systemd/system/dashboard.service /etc/systemd/system/nezha-agent.service
    if [ "${ENABLE_ARGO}" = "true" ]; then
      safe_rm /etc/systemd/system/argo.service /etc/systemd/system/caddy.service
    fi
  fi
}

# 根据系统类型安装、卸载依赖
manage_packages() {
  if [ $# -lt 2 ]; then
    red "Unspecified package name or action"
    return 1
  fi

  action=$1
  shift

  # Alpine 下 apk update 只需执行一次（循环外）
  if [ "$action" == "install" ] && command -v apk &>/dev/null; then
    apk update >/dev/null 2>&1
  fi

  for package in "$@"; do
    if [ "$action" == "install" ]; then
      # coreutils 是包名不是命令，用 date 命令判断；其他包用 command -v
      if [ "$package" = "coreutils" ]; then
        if command -v date &>/dev/null; then
          green "${package} already installed"
          continue
        fi
      elif command -v "$package" &>/dev/null; then
        green "${package} already installed"
        continue  # continue命令的作用是跳过后面的代码，并且在循环迭代中移动到下一个出现点。
      fi
      yellow "正在安装 ${package}..."
      if command -v apt &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt install -y "$package"
      elif command -v dnf &>/dev/null; then
        dnf install -y "$package"
      elif command -v yum &>/dev/null; then
        yum install -y "$package"
      elif command -v apk &>/dev/null; then
        apk add "$package"
      else
        red "Unknown system!"
        return 1
      fi
    elif [ "$action" == "uninstall" ]; then
      if [ "$package" = "coreutils" ]; then
        # coreutils 是基础包，跳过卸载避免破坏系统
        yellow "${package} is a base package, skip uninstall"
        continue
      fi
      if ! command -v "$package" &>/dev/null; then
        yellow "${package} is not installed"
        continue
      fi
      yellow "正在卸载 ${package}..."
      if command -v apt &>/dev/null; then
        apt remove -y "$package" && apt autoremove -y
      elif command -v dnf &>/dev/null; then
        dnf remove -y "$package" && dnf autoremove -y
      elif command -v yum &>/dev/null; then
        yum remove -y "$package" && yum autoremove -y
      elif command -v apk &>/dev/null; then
        apk del "$package"
      else
        red "Unknown system!"
        return 1
      fi
    else
      red "Unknown action: $action"
      return 1
    fi
  done

  return 0
}

# 检查并安装必要的工具
check_and_install_tools() {
  manage_packages install curl openssl coreutils unzip tar git sqlite3
  # cron 守护进程（各发行版包名不同：Debian=cron，RHEL/Alpine=cronie）
  if ! command -v crond >/dev/null 2>&1 && ! command -v cron >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1; then
      manage_packages install cron
    else
      manage_packages install cronie
    fi
  fi
}

# 判断处理器架构
case "$(uname -m)" in
  aarch64|arm64 )
    ARCH=arm64
    ;;
  x86_64|amd64 )
    ARCH=amd64
    ;;
  * )
    echo "Unsupported architecture: $(uname -m)"
    exit 1
    ;;
esac

# 系统类型（用于备份还原脚本选择 openrc/systemd 分支）
[ -f /etc/alpine-release ] && SYSTEM=Alpine || SYSTEM=Linux

# 获取 GitHub 最新 release 版本号（通用 sed 解析，兼容 GNU/busybox）
get_latest_release() {
  curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 \
    "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

# 设置下载
initialize_downloads() {
  if [ "${ENABLE_ARGO}" = "true" ] && [ ! -f ${FILE_PATH}/caddy ]; then
    CADDY_LATEST=$(get_latest_release "caddyserver/caddy")
    if [ -z "$CADDY_LATEST" ]; then
      red "获取 caddy 最新版本失败，请检查网络后重试"
      return 1
    fi
    CADDY_LATEST=${CADDY_LATEST#v}
    if ! curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 "${GH_PROXY}https://github.com/caddyserver/caddy/releases/download/v${CADDY_LATEST}/caddy_${CADDY_LATEST}_linux_${ARCH}.tar.gz" | tar xz -C ${FILE_PATH} caddy; then
      red "caddy 下载失败"
      return 1
    fi
    chmod +x ${FILE_PATH}/caddy
  fi

  if [ ! -f ${FILE_PATH}/dashboard ]; then
    if [ -n "${DASHBOARD_VERSION}" ]; then
      DASHBOARD_LATEST="${DASHBOARD_VERSION}"
    else
      DASHBOARD_LATEST=$(get_latest_release "nezhahq/nezha")
    fi
    if [ -z "$DASHBOARD_LATEST" ]; then
      red "获取 dashboard 最新版本失败，请检查网络后重试"
      return 1
    fi
    if ! curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 "${GH_PROXY}https://github.com/nezhahq/nezha/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip" -o ${FILE_PATH}/dashboard.zip; then
      red "dashboard 下载失败"
      return 1
    fi
    unzip ${FILE_PATH}/dashboard.zip -d ${FILE_PATH} > /dev/null
    mv -f ${FILE_PATH}/dashboard-linux-$ARCH ${FILE_PATH}/dashboard
    safe_rm "${FILE_PATH}"/dashboard.zip
    chmod +x ${FILE_PATH}/dashboard
  fi

  if [ "${ENABLE_ARGO}" = "true" ] && [ ! -f ${FILE_PATH}/argo ]; then
    if ! curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 "${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH" -o ${FILE_PATH}/argo; then
      red "cloudflared(argo) 下载失败"
      return 1
    fi
    chmod +x ${FILE_PATH}/argo
  fi

  if [ ! -f ${FILE_PATH}/nezha-agent ]; then
    if [ -n "${AGENT_VERSION}" ]; then
      AGENT_LATEST="${AGENT_VERSION}"
    else
      AGENT_LATEST=$(get_latest_release "nezhahq/agent")
    fi
    if [ -z "$AGENT_LATEST" ]; then
      red "获取 nezha-agent 最新版本失败，请检查网络后重试"
      return 1
    fi
    if ! curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 "${GH_PROXY}https://github.com/nezhahq/agent/releases/download/$AGENT_LATEST/nezha-agent_linux_$ARCH.zip" -o ${FILE_PATH}/nezha-agent.zip; then
      red "nezha-agent 下载失败"
      return 1
    fi
    unzip ${FILE_PATH}/nezha-agent.zip -d ${FILE_PATH} > /dev/null
    safe_rm "${FILE_PATH}"/nezha-agent.zip
    chmod +x ${FILE_PATH}/nezha-agent
  fi
}

# 面板环境配置
my_config() {
  if [ "${ENABLE_ARGO}" = "true" ] && [ -e ${FILE_PATH}/caddy ]; then
    # 生成自签署SSL证书
    openssl genrsa -out ${FILE_PATH}/nezha.key 2048 >/dev/null 2>&1
    openssl req -new -subj "/CN=$ARGO_DOMAIN" -key ${FILE_PATH}/nezha.key -out ${FILE_PATH}/nezha.csr >/dev/null 2>&1
    openssl x509 -req -days 36500 -in ${FILE_PATH}/nezha.csr -signkey ${FILE_PATH}/nezha.key -out ${FILE_PATH}/nezha.pem >/dev/null 2>&1

    cat > ${FILE_PATH}/Caddyfile  << EOF
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
    tls ${FILE_PATH}/nezha.pem ${FILE_PATH}/nezha.key
}
EOF

    if [ -f /etc/alpine-release ]; then
      cat > /etc/init.d/caddy << ABC
#!/sbin/openrc-run

supervisor=supervise-daemon
name="caddy"
description="caddy Tunnel"
command=${FILE_PATH}/caddy
command_args="run --config ${FILE_PATH}/Caddyfile"
# 新进程启动前，旧进程死透
start_pre() {
    pkill -9 -f "${FILE_PATH}/caddy" || true
    sleep 1
}
# 自动重启设置
respawn_delay=5
respawn_max=0
# 静默输出
supervise_daemon_args="--stdout /dev/null --stderr /dev/null"
ABC
      chmod +x /etc/init.d/caddy
      rc-update add caddy default
    else
      cat > /etc/systemd/system/caddy.service << ABC
[Unit]
Description=Caddy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=simple
ExecStart=${FILE_PATH}/caddy run --config ${FILE_PATH}/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5s
# 将所有标准输出和错误输出丢弃
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
ABC
    fi
  fi

  if [ "$ENABLE_ARGO" = "true" ] && [ -e "${FILE_PATH}/argo" ]; then
    ARGS="tunnel --edge-ip-version auto --protocol http2 run --token ${ARGO_AUTH}"
    ARGO_RUNS="${FILE_PATH}/argo ${ARGS}"
    if [ -f /etc/alpine-release ]; then
      cat > /etc/init.d/argo << DEF
#!/sbin/openrc-run

supervisor=supervise-daemon
name="argo"
description="Cloudflare Tunnel"
export GODEBUG=netdns=go
command=${FILE_PATH}/argo
command_args="${ARGS}"
start_pre() {
    pkill -9 -f "${FILE_PATH}/argo" || true
    sleep 1
}
respawn_delay=5
respawn_max=0
supervise_daemon_args="--stdout /dev/null --stderr /dev/null"
DEF
      chmod +x /etc/init.d/argo
      rc-update add argo default
    else
      cat > /etc/systemd/system/argo.service << DEF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
# 强制 Argo 内部使用 Go 语言自带的 DNS 解析器，不理会系统不稳的解析服务
Environment="GODEBUG=netdns=go"
# 告诉 Argo 优先查询公网 DNS
Environment="LOCAL_DNS_SERVER=1.1.1.1"
ExecStart=$ARGO_RUNS
Restart=always
RestartSec=5s
# 将所有标准输出和错误输出丢弃
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
DEF
    fi
  fi

  if [ -e "${FILE_PATH}/dashboard" ]; then
    if [ -n "$MY_DOMAIN" ] && [ -z "${ARGO_DOMAIN}" ]; then
      export ARGO_DOMAIN="$MY_DOMAIN"
    fi
    if [ "${ENABLE_ARGO}" = "true" ]; then
      tls="true"
    else
      tls="false"
    fi
    cat > /data/config.yaml << EOF
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
    chmod 600 /data/config.yaml

    if [ -f /etc/alpine-release ]; then
      cat > /etc/init.d/dashboard << GHI
#!/sbin/openrc-run

supervisor=supervise-daemon
name="dashboard"
description="nezha dashboard"
command="${FILE_PATH}/dashboard"
command_args=""
start_pre() {
    pkill -9 -f "${FILE_PATH}/dashboard" || true
    sleep 1
}
respawn_delay=5
respawn_max=0
supervise_daemon_args="--stdout /dev/null --stderr /dev/null"
GHI
      chmod +x /etc/init.d/dashboard
      rc-update add dashboard default
    else
      cat > /etc/systemd/system/dashboard.service << GHI
[Unit]
Description=Nezha Argo for VPS
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=${FILE_PATH}/dashboard
Restart=on-failure
RestartSec=5s
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
GHI
    fi
  fi

  if [ -e "${FILE_PATH}/nezha-agent" ]; then
    NEZHA_RUNS="${FILE_PATH}/nezha-agent -c ${FILE_PATH}/config.yml"
    cat > ${FILE_PATH}/config.yml << EOF
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
    chmod 600 ${FILE_PATH}/config.yml

    if [ -f /etc/alpine-release ]; then
      cat > /etc/init.d/nezha-agent << JKL
#!/sbin/openrc-run

supervisor=supervise-daemon
name="nezha-agent"
description="nezha agent"
command=${FILE_PATH}/nezha-agent
command_args="-c ${FILE_PATH}/config.yml"
start_pre() {
    pkill -9 -f "${FILE_PATH}/nezha-agent" || true
    sleep 1
}
respawn_delay=5
respawn_max=0
supervise_daemon_args="--stdout /dev/null --stderr /dev/null"
JKL
      chmod +x /etc/init.d/nezha-agent
      rc-update add nezha-agent default
    else
      cat > /etc/systemd/system/nezha-agent.service << JKL
[Unit]
Description=nezha-agent
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=$NEZHA_RUNS
Restart=on-failure
RestartSec=5s
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
JKL
    fi
  fi
}

# 放行指定端口（不再清空全部防火墙规则）
open_ports() {
  local ports=()
  [ -n "${WEB_PORT}" ]      && ports+=("${WEB_PORT}")
  [ -n "${GRPC_PROXY_PORT}" ]    && ports+=("${GRPC_PROXY_PORT}")
  [ -n "${GRPC_PORT}" ]   && ports+=("${GRPC_PORT}")

  if command -v iptables &>/dev/null; then
    for p in "${ports[@]}"; do
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
  fi
  if command -v ip6tables &>/dev/null; then
    for p in "${ports[@]}"; do
      ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
        ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || \
        ip6tables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
  fi
}

# 保持进程运行
run_processes() {
  # 放行所需端口（不再清空防火墙）
  open_ports

  # systemd 下创建/修改了 unit 文件，先重载让 systemctl 识别
  if ! [ -f /etc/alpine-release ]; then
    systemctl daemon-reload
  fi

  if [ "$ENABLE_ARGO" = "true" ] && [ -e "${FILE_PATH}/caddy" ]; then
    chmod +x ${FILE_PATH}/caddy
    if [ -f /etc/alpine-release ]; then
      rc-service caddy start
    else
      systemctl enable caddy
      systemctl start caddy
    fi
    green "caddy服务已成功启动\n"
  fi

  if [ "$ENABLE_ARGO" = "true" ] && [ -e "${FILE_PATH}/argo" ]; then
    chmod +x ${FILE_PATH}/argo
    if [ -f /etc/alpine-release ]; then
      rc-service argo start
    else
      systemctl enable argo
      systemctl start argo
    fi
    green "argo服务已成功启动\n"
  fi

  sleep 5

  if [ -e "${FILE_PATH}/dashboard" ]; then
    chmod +x ${FILE_PATH}/dashboard
    if [ -f /etc/alpine-release ]; then
      rc-service dashboard start
    else
      systemctl enable dashboard
      systemctl start dashboard
    fi
    green "nezha-dashboard服务已成功启动\n"
  fi

  sleep 3

  if [ -e "${FILE_PATH}/nezha-agent" ]; then
    chmod +x ${FILE_PATH}/nezha-agent
    if [ -f /etc/alpine-release ]; then
      rc-service nezha-agent start
    else
      systemctl enable nezha-agent
      systemctl start nezha-agent
    fi
    green "nezha-agent服务已成功启动\n"
  fi

  purple "哪吒服务器V1 VPS版安装完毕!"
  red "温馨提醒：/data目录为哪吒服务器V1面板数据,恢复数据将sqlite.db直接覆盖到/data就行! "
  red "温馨提醒：卸载哪吒服务器时不会删除 /data目录,请妥善保存! "
}

# 启动 cron 守护进程
start_cron() {
  if [ -f /etc/alpine-release ]; then
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond restart >/dev/null 2>&1 || true
  else
    systemctl enable cron >/dev/null 2>&1 || systemctl enable crond >/dev/null 2>&1 || true
    systemctl restart cron >/dev/null 2>&1 || systemctl restart crond >/dev/null 2>&1 || true
  fi
}

# 拉取 template 脚本主体（去掉变量头），失败返回非0
fetch_template_body() {
  local name=$1 body
  body=$(curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 "${GH_PROXY}https://raw.githubusercontent.com/YeeLeer/nezhaserver_V1/refs/heads/main/template/${name}.sh" 2>/dev/null | sed '1,/^########/d')
  [ -n "$body" ] || return 1
  printf '%s\n' "$body"
}

# 生成备份/还原/更新脚本（与容器版同一套模板，IS_DOCKER 为空时走 systemd/openrc 分支）
gen_backup_restore_scripts() {
  [ -d "$FILE_PATH" ] || mkdir -p "$FILE_PATH"

  # backup.sh
  cat > ${FILE_PATH}/backup.sh << EOF
#!/usr/bin/env bash

# backup.sh 传参 a 自动还原； 传参 m 手动还原； 传参 f 强制更新面板 dashboard 文件及 cloudflared 文件，并备份数据至成备份库

GH_PROXY=$GH_PROXY
GH_PAT=$GH_PAT
GH_BACKUP_USER=$GH_BACKUP_USER
GH_EMAIL=$GH_EMAIL
GH_REPO=$GH_REPO
ARCH=$ARCH
WORK_DIR=$FILE_PATH
DAYS=5
IS_DOCKER=
DASHBOARD_VERSION=$DASHBOARD_VERSION
ENABLE_ARGO=$ENABLE_ARGO
SYSTEM=$SYSTEM
DATA_DIR=/data

########
EOF
  if ! fetch_template_body backup >> ${FILE_PATH}/backup.sh; then
    rm -f ${FILE_PATH}/backup.sh
    red "获取 template/backup.sh 失败，请检查网络后重试"
    return 1
  fi

  if [[ -n "$GH_BACKUP_USER" && -n "$GH_EMAIL" && -n "$GH_REPO" && -n "$GH_PAT" ]]; then
    # restore.sh
    cat > ${FILE_PATH}/restore.sh << EOF
#!/usr/bin/env bash

# restore.sh 传参 a 自动还原 README.md 记录的文件； f 强制还原备份库里 README.md 记录的文件； dashboard-***.tar.gz 还原指定文件；不带参数则选择备份库里的文件名

GH_PROXY=$GH_PROXY
GH_PAT=$GH_PAT
GH_BACKUP_USER=$GH_BACKUP_USER
GH_REPO=$GH_REPO
WORK_DIR=$FILE_PATH
TEMP_DIR=/tmp/restore_temp
NO_ACTION_FLAG=/tmp/flag
IS_DOCKER=
ENABLE_ARGO=$ENABLE_ARGO
SYSTEM=$SYSTEM
DATA_DIR=/data

########
EOF
    if ! fetch_template_body restore >> ${FILE_PATH}/restore.sh; then
      rm -f ${FILE_PATH}/restore.sh
      red "获取 template/restore.sh 失败，请检查网络后重试"
      return 1
    fi
  fi

  # renew.sh
  cat > ${FILE_PATH}/renew.sh << EOF
#!/usr/bin/env bash

GH_PROXY=$GH_PROXY
WORK_DIR=$FILE_PATH
TEMP_DIR=/tmp/renew
DATA_DIR=/data

########
EOF
  if ! fetch_template_body renew >> ${FILE_PATH}/renew.sh; then
    rm -f ${FILE_PATH}/renew.sh
    red "获取 template/renew.sh 失败，请检查网络后重试"
    return 1
  fi

  chmod +x ${FILE_PATH}/*.sh

  # 定时任务：renew 每天 3:30 更新脚本；backup 每天 4:00 备份；restore 每分钟检测在线备份记录
  [ -z "$NO_AUTO_RENEW" ] && [ -s ${FILE_PATH}/renew.sh ] && ! grep -q "${FILE_PATH}/renew.sh" /etc/crontab && echo "30 3 * * * root bash ${FILE_PATH}/renew.sh" >> /etc/crontab
  [ -s ${FILE_PATH}/backup.sh ] && ! grep -q "${FILE_PATH}/backup.sh" /etc/crontab && echo "0 4 * * * root bash ${FILE_PATH}/backup.sh a" >> /etc/crontab
  [ -s ${FILE_PATH}/restore.sh ] && ! grep -q "${FILE_PATH}/restore.sh" /etc/crontab && echo "* * * * * root bash ${FILE_PATH}/restore.sh a" >> /etc/crontab
  start_cron
}

# install_dashboard
install_dashboard() {
  stop_services
  check_and_install_tools
  createfolder
  cleanup_files
  if ! initialize_downloads; then
    red "下载初始化失败，安装中止（可重试）"
    return 1
  fi
  my_config
  gen_backup_restore_scripts
  run_processes
}

# remove_dashboard
remove_dashboard() {
  stop_services
  cleanup_files
  safe_rm "${FILE_PATH}"
  # 清理备份/还原/更新脚本的定时任务
  if [ -f /etc/crontab ]; then
    grep -Ev "${FILE_PATH}/(renew|backup|restore)\.sh" /etc/crontab > /tmp/crontab.tmp 2>/dev/null || true
    mv -f /tmp/crontab.tmp /etc/crontab
  fi
}

# reboot_dashboard
reboot_dashboard() {
  if [ -f /etc/alpine-release ]; then
    rc-service dashboard stop >/dev/null 2>&1 || true
    pkill -TERM -f "${FILE_PATH}/dashboard" >/dev/null 2>&1 || true
    sleep 1
    pkill -KILL -f "${FILE_PATH}/dashboard" >/dev/null 2>&1 || true
    rc-service dashboard start
  else
    systemctl stop dashboard 2>/dev/null || true
    systemctl start dashboard
  fi
}

# update_dashboard_binary
update_dashboard_binary() {
  yellow "正在更新 dashboard 二进制文件..."

  # 1. 停止服务
  if [ -f /etc/alpine-release ]; then
    rc-service dashboard stop >/dev/null 2>&1 || true
    pkill -TERM -f "${FILE_PATH}/dashboard" >/dev/null 2>&1 || true
    sleep 1
    pkill -KILL -f "${FILE_PATH}/dashboard" >/dev/null 2>&1 || true
  else
    systemctl stop dashboard >/dev/null 2>&1 || true
  fi

  # 2. 备份旧文件
  if [ -f "${FILE_PATH}/dashboard" ]; then
    cp "${FILE_PATH}/dashboard" "${FILE_PATH}/dashboard.backup"
    green "已备份旧版本到: ${FILE_PATH}/dashboard.backup"
  fi

  # 3. 获取最新版本并下载
  if [ -n "${DASHBOARD_VERSION}" ]; then
    DASHBOARD_LATEST="${DASHBOARD_VERSION}"
  else
    DASHBOARD_LATEST=$(get_latest_release "nezhahq/nezha")
  fi
  if [ -z "$DASHBOARD_LATEST" ]; then
    red "获取 dashboard 最新版本失败，请检查网络后重试"
    return 1
  fi

  yellow "下载最新版本: ${DASHBOARD_LATEST}..."
  if ! curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 15 "${GH_PROXY}https://github.com/nezhahq/nezha/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip" -o "${FILE_PATH}/dashboard.zip"; then
    red "下载失败"
    if [ -f "${FILE_PATH}/dashboard.backup" ]; then
      mv "${FILE_PATH}/dashboard.backup" "${FILE_PATH}/dashboard"
      chmod +x "${FILE_PATH}/dashboard"
      yellow "已恢复旧版本"
      # 恢复后重启服务
      if [ -f /etc/alpine-release ]; then
        rc-service dashboard start >/dev/null 2>&1 || true
      else
        systemctl start dashboard >/dev/null 2>&1 || true
      fi
      green "dashboard 服务已用旧版本重启"
    fi
  else
    unzip -o "${FILE_PATH}/dashboard.zip" -d "${FILE_PATH}" > /dev/null
    mv -f "${FILE_PATH}/dashboard-linux-$ARCH" "${FILE_PATH}/dashboard"
    chmod +x "${FILE_PATH}/dashboard"
    safe_rm "${FILE_PATH}/dashboard.zip"
    green "更新成功"

    # 4. 重启服务
    if [ -f /etc/alpine-release ]; then
      rc-service dashboard start
    else
      systemctl start dashboard
    fi
    green "dashboard 服务已重启"
  fi
}

# 一键备份数据库（推送 sqlite.db + config.yaml 至 GitHub 备份库）
github_backup() {
  if [ -z "$GH_PAT" ] || [ -z "$GH_REPO" ] || [ -z "$GH_BACKUP_USER" ] || [ -z "$GH_EMAIL" ]; then
    red "未配置 GitHub 备份信息（GH_PAT/GH_REPO/GH_BACKUP_USER/GH_EMAIL），请先填写脚本顶部变量"
    return 1
  fi
  gen_backup_restore_scripts || return 1
  yellow "正在备份 /data 数据到 GitHub 备份库 ${GH_BACKUP_USER}/${GH_REPO} ..."
  bash ${FILE_PATH}/backup.sh m
}

# 一键恢复数据库（从 GitHub 备份库拉取并覆盖 /data 数据）
github_restore() {
  if [ -z "$GH_PAT" ] || [ -z "$GH_REPO" ] || [ -z "$GH_BACKUP_USER" ]; then
    red "未配置 GitHub 备份信息（GH_PAT/GH_REPO/GH_BACKUP_USER），请先填写脚本顶部变量"
    return 1
  fi
  gen_backup_restore_scripts || return 1
  red "注意：恢复会停止 dashboard 服务并覆盖 /data 目录下的 sqlite.db 与 config.yaml！"
  bash ${FILE_PATH}/restore.sh
}

menu(){
echo "1、安装哪吒服务器V1-VPS版"
echo " "
echo "2、御载哪吒服务器V1-VPS版"
echo " "
echo "3、重启dashboard服务"
echo " "
echo "4、更新dashboard二进制文件"
echo " "
echo "5、一键备份数据库(推送至 GitHub)"
echo " "
echo "6、一键恢复数据库(从 GitHub 拉取)"
echo " "
echo "0、退出脚本"
echo " "
read -p " 请输入数字 [0-6]: " num
case "$num" in
    1)
    install_dashboard
    ;;
    2)
    remove_dashboard
    ;;
    3)
    reboot_dashboard
    ;;
    4)
    update_dashboard_binary
    ;;
    5)
    github_backup
    ;;
    6)
    github_restore
    ;;
    0)
    exit 0
    ;;
    *)
    clear
    red "请输入正确数字 [0-6]"
    sleep 5
    menu
    ;;
esac
}
menu
