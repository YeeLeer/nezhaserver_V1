#!/usr/bin/env bash

# backup.sh 传参 a 自动还原； 传参 m 手动还原； 传参 f 强制更新面板 dashboard 文件及 cloudflared 文件，并备份数据至成备份库。
# 如是 IPv6 only 或者大陆机器，需要 Github 加速网，可自行查找放在 GH_PROXY 处 ，如 https://mirror.ghproxy.com/ ，能不用就不用，减少因加速网导致的故障。

GH_PROXY=
GH_PAT=
GH_BACKUP_USER=
GH_EMAIL=
GH_REPO=
SYSTEM=
ARCH=
WORK_DIR=
DAYS=5
IS_DOCKER=
DASHBOARD_VERSION=

########

# version: 2025.08.08

warning() { echo -e "\033[31m\033[01m$*\033[0m"; }  # 红色
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; } # 红色
info() { echo -e "\033[32m\033[01m$*\033[0m"; }   # 绿色
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }   # 黄色

cmd_systemctl() {
  local ENABLE_DISABLE=$1
  if [ "$ENABLE_DISABLE" = 'enable' ]; then
    # 与 vps_nezha.sh 一致：systemd 服务名为 dashboard，Alpine 用 openrc(rc-service)
    if [ -f /etc/alpine-release ] || [ "$SYSTEM" = 'Alpine' ]; then
      local TRY=5
      until [ "$(rc-service dashboard status 2>/dev/null)" = 'started' ]; do
        rc-service dashboard stop >/dev/null 2>&1; sleep 1
        rc-service dashboard start
        ((TRY--))
        [ "$TRY" = 0 ] && break
      done
      rc-update add dashboard default >/dev/null 2>&1
    else
      systemctl enable --now dashboard
    fi

  elif [ "$ENABLE_DISABLE" = 'disable' ]; then
    if [ -f /etc/alpine-release ] || [ "$SYSTEM" = 'Alpine' ]; then
      rc-service dashboard stop >/dev/null 2>&1
    else
      systemctl disable --now dashboard
    fi
  fi
}

# 运行备份脚本时，自锁一定时间以防 Github 缓存的原因导致数据马上被还原
[ -s $WORK_DIR/restore.sh ] && touch $(awk -F '=' '/NO_ACTION_FLAG/{print $2; exit}' $WORK_DIR/restore.sh)1

# 手自动标志
[ "$1" = 'a' ] && WAY=Scheduled || WAY=Manualed
[ "$1" = 'f' ] && WAY=Manualed && FORCE_UPDATE=true

# 检查更新面板主程序 DASHBOARD 及 cloudflared
if [[ -n "$DASHBOARD_VERSION" ]]; then
  DASHBOARD_UPDATE=false
elif [[ -n "$DASHBOARD_VERSION" || "$DASHBOARD_VERSION" =~ 0\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
  error "The DASHBOARD_VERSION variable should be in a format like v0.00.00, please check."
  DASHBOARD_UPDATE=false
else
  cd $WORK_DIR
  DASHBOARD_NOW=$(./dashboard -v)
  # DASHBOARD_LATEST=$(wget -qO- https://api.github.com/repos/nezhahq/nezha/releases/latest | awk -F '"' '/tag_name/{print $4}')
  DASHBOARD_LATEST=$(curl -sSL https://api.github.com/repos/nezhahq/nezha/releases/latest | awk -F '"' '/tag_name/{print $4}')
  [ "v${DASHBOARD_NOW}" != "$DASHBOARD_LATEST" ] && DASHBOARD_UPDATE=true
fi

if [ "${ENABLE_ARGO}" = "true" ]; then
  CLOUDFLARED_NOW=$(./cloudflared -v | awk '{for (i=0; i<NF; i++) if ($i=="version") {print $(i+1)}}')
  # CLOUDFLARED_LATEST=$(wget -qO- https://api.github.com/repos/cloudflare/cloudflared/releases/latest | awk -F '"' '/tag_name/{print $4}')
  CLOUDFLARED_LATEST=$(curl -sSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest | awk -F '"' '/tag_name/{print $4}')
  [[ "$CLOUDFLARED_LATEST" =~ ^20[0-9]{2}\.[0-9]{1,2}\.[0-9]+$ && "$CLOUDFLARED_NOW" != "$CLOUDFLARED_LATEST" ]] && CLOUDFLARED_UPDATE=true
fi

# 检测是否有设置备份数据
if [[ -n "$GH_REPO" && -n "$GH_BACKUP_USER" && -n "$GH_EMAIL" && -n "$GH_PAT" ]]; then
  # IS_PRIVATE="$(wget -qO- --header="Authorization: token $GH_PAT" https://api.github.com/repos/$GH_BACKUP_USER/$GH_REPO | sed -n '/"private":/s/.*:[ ]*\([^,]*\),/\1/gp')"
  IS_PRIVATE="$(curl -sSL --header "Authorization: token $GH_PAT" https://api.github.com/repos/$GH_BACKUP_USER/$GH_REPO | sed -n '/"private":/s/.*:[ ]*\([^,]*\),/\1/gp')"
  if [ "$?" != 0 ]; then
    warning "\n Could not connect to Github. Stop backup. \n"
  elif [ "$IS_PRIVATE" != true ]; then
    warning "\n This is not exist nor a private repository. \n"
  else
    IS_BACKUP=true
  fi
fi

# 分步骤处理
if [[ "${DASHBOARD_UPDATE}${CLOUDFLARED_UPDATE}${IS_BACKUP}${FORCE_UPDATE}" =~ true ]]; then
  # 更新面板主程序
  if [[ "${DASHBOARD_UPDATE}${FORCE_UPDATE}" =~ 'true' ]]; then
    hint "\n Renew dashboard to $DASHBOARD_LATEST \n"
    if [ -n "${DASHBOARD_VERSION}" ]; then
      DASHBOARD_LATEST="${DASHBOARD_VERSION}"
    else
      DASHBOARD_LATEST="latest"
    fi
    # wget -O $WORK_DIR/dashboard.zip ${GH_PROXY}https://github.com/nezhahq/nezha/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip
    curl -sSL ${GH_PROXY}https://github.com/nezhahq/nezha/releases/download/$DASHBOARD_LATEST/dashboard-linux-$ARCH.zip -o /tmp/dashboard.zip
    unzip -o /tmp/dashboard.zip -d /tmp
    chmod +x /tmp/dashboard-linux-$ARCH
    if [ -s /tmp/dashboard-linux-$ARCH ]; then
      info "\n Restart Nezha Dashboard \n"
      if [ "$IS_DOCKER" = 1 ]; then
        supervisorctl stop nezha >/dev/null 2>&1
        sleep 10
        mv -f /tmp/dashboard-linux-$ARCH $WORK_DIR/dashboard
        supervisorctl start nezha >/dev/null 2>&1
      else
        cmd_systemctl disable >/dev/null 2>&1
        sleep 10
        mv -f /tmp/dashboard-linux-$ARCH $WORK_DIR/dashboard
        cmd_systemctl enable >/dev/null 2>&1
      fi
    fi
    rm -rf /tmp/dist /tmp/dashboard.zip
  fi

  # 更新 cloudflared（ENABLE_ARGO=false 时跳过）
  if [ "${ENABLE_ARGO}" = "true" ] && [[ "${CLOUDFLARED_UPDATE}${FORCE_UPDATE}" =~ 'true' ]]; then
    hint "\n Renew Cloudflared to $CLOUDFLARED_LATEST \n"
    # wget -O /tmp/cloudflared ${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH && chmod +x /tmp/cloudflared
    curl -sSL ${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH -o /tmp/cloudflared
    if [ -s /tmp/cloudflared ]; then
      info "\n Restart Argo \n"
      if [ "$IS_DOCKER" = 1 ]; then
        supervisorctl stop argo >/dev/null 2>&1
        mv -f /tmp/cloudflared $WORK_DIR/
        supervisorctl start argo >/dev/null 2>&1
      else
        cmd_systemctl disable >/dev/null 2>&1
        mv -f /tmp/cloudflared $WORK_DIR/
        cmd_systemctl enable >/dev/null 2>&1
      fi
    fi
  fi

  # 克隆备份仓库，压缩备份文件，上传更新
  if [ "$IS_BACKUP" = 'true' ]; then
    # 定时任务触发时 cwd 不固定，先切到工作目录
    cd $WORK_DIR
    # 备份前先停掉面板，设置 git 环境变量，减少系统开支
    if [ "$IS_DOCKER" != 1 ]; then
      cmd_systemctl disable >/dev/null 2>&1
      git config --global core.bigFileThreshold 1k
      git config --global core.compression 0
      git config --global advice.detachedHead false
      git config --global pack.threads 1
      git config --global pack.windowMemory 50m
    else
      supervisorctl stop nezha >/dev/null 2>&1
    fi
    sleep 10

    # 优化数据库，感谢 longsays 的脚本
    # 1. 导出数据
    sqlite3 "data/sqlite.db" <<EOF
.output /tmp/tmp.sql
.dump
.quit
EOF

    # 2. 导入到新库
    if [ $? -ne 0 ]; then
      echo "Data export failed!"
    else
      sqlite3 "/tmp/new.sqlite.db" <<EOF
.read /tmp/tmp.sql
.quit
EOF
    fi

    # 3. 检查导入是否成功
    if [ $? -ne 0 ]; then
      echo "Data import failed!"
    else
      # 覆盖原库并优化
      mv -f "/tmp/new.sqlite.db" "data/sqlite.db"
      sqlite3 "data/sqlite.db" 'VACUUM;'
      [ $? -eq 0 ] && echo "Database migration and optimisation complete!" || echo "Database migration and optimisation failed!"
      # 清理临时文件
      rm -f /tmp/tmp.sql
    fi

    # 克隆现有备份库
    [ -d /tmp/$GH_REPO ] && rm -rf /tmp/$GH_REPO
    git clone https://$GH_PAT@github.com/$GH_BACKUP_USER/$GH_REPO.git --depth 1 --quiet /tmp/$GH_REPO

    # 压缩备份数据，只备份 data/ 目录下的 config.yaml 和 sqlite.db
    if [ -d /tmp/$GH_REPO ]; then
      TIME=$(date "+%Y-%m-%d-%H_%M_%S")
      echo "↓↓↓↓↓↓↓↓↓↓ dashboard-$TIME.tar.gz list ↓↓↓↓↓↓↓↓↓↓"
      tar czvf /tmp/$GH_REPO/dashboard-$TIME.tar.gz data/
      echo -e "↑↑↑↑↑↑↑↑↑↑ dashboard-$TIME.tar.gz list ↑↑↑↑↑↑↑↑↑↑\n\n"

      # 更新备份 Github 库，删除 5 天前的备份
      cd /tmp/$GH_REPO
      [ -e ./.git/index.lock ] && rm -f ./.git/index.lock
      echo "dashboard-$TIME.tar.gz" > README.md
      find ./ -name '*.gz' | sort | head -n -$DAYS | xargs rm -f
      git config --global user.name $GH_BACKUP_USER
      git config --global user.email $GH_EMAIL
      git checkout --orphan tmp_work
      git add .
      git commit -m "$WAY at $TIME ."
      git push -f -u origin HEAD:main --quiet
      IS_UPLOAD="$?"
      cd ..
      rm -rf $GH_REPO
      if [ "$IS_UPLOAD" = 0 ]; then
        echo "dashboard-$TIME.tar.gz" > $WORK_DIR/dbfile
        info "\n Succeed to upload the backup files dashboard-$TIME.tar.gz to Github.\n"
      else
        rm -f $(awk -F '=' '/NO_ACTION_FLAG/{print $2; exit}' $WORK_DIR/restore.sh)*
        hint "\n Failed to upload the backup files dashboard-$TIME.tar.gz to Github.\n"
      fi
    fi
  fi
fi

if [ "$IS_DOCKER" = 1 ]; then
  supervisorctl start nezha >/dev/null 2>&1
  [ $(supervisorctl status all | grep -c "RUNNING") = $(grep -c '\[program:.*\]' /etc/supervisor/conf.d/damon.conf) ] && info "\n All programs started! \n" || error "\n Failed to start program! \n"
else
  cmd_systemctl enable >/dev/null 2>&1
  if [ -f /etc/alpine-release ] || [ "$SYSTEM" = 'Alpine' ]; then
    [ "$(rc-service dashboard status 2>/dev/null)" = 'started' ] && info "\n Nezha dashboard started! \n" || error "\n Failed to start Nezha dashboard! \n"
  else
    [ "$(systemctl is-active dashboard)" = 'active' ] && info "\n Nezha dashboard started! \n" || error "\n Failed to start Nezha dashboard! \n"
  fi
fi
