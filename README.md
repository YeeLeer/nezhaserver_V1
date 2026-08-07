# 基于 F大argo哪吒服务器  https://github.com/fscarmen2/Argo-Nezha-Service-Container 自用

自用容器版，逻辑已同步自 `vps_nezha` 最新版。数据目录为 `/dashboard/data`（`config.yaml` 与 `sqlite.db`），恢复数据时把 `sqlite.db` 直接覆盖到该目录即可。

## VPS 版（`vps_nezha.sh`）
- 与容器版共用同一套 `template/` 备份还原逻辑（生成脚本时 `IS_DOCKER` 为空，走 systemd / openrc 分支）
- 备份还原可选变量：`GH_PAT` / `GH_REPO` / `GH_EMAIL` / `GH_BACKUP_USER`（默认同 `GH_USER`），填了才会生成 `restore.sh` 并开启定时备份还原
- 生成的脚本位于 `FILE_PATH`（默认 `/root/dashboard`）：`backup.sh` 每天 4:00 备份，`restore.sh` 每分钟检测在线备份记录，`renew.sh` 每天 3:30 在线更新脚本
- `NO_AUTO_RENEW=1` 可关闭定时更新备份/还原脚本

## 必填环境变量
- `GH_USER` / `GH_CLIENTID` / `GH_CLIENTSECRET`：GitHub OAuth 登录（备份还原默认使用该账户）
- `UUID`：agent 的 `LOCAL_TOKEN`
- `AGENT_KEY`：nezha v1 key（兼容旧变量名 `agentsecretkey`）
- `ARGO_AUTH` / `ARGO_DOMAIN`：开启 argo 时需要（见下方 `ENABLE_ARGO`）

## 常用可选变量
- `ENABLE_ARGO`：`true`（默认）开启 argo；`false` 时不使用 argo，直连面板 `GRPC_PORT`，需设 `MY_DOMAIN`
- `MY_DOMAIN`：直连时 CDN 域名；未填 `ARGO_DOMAIN` 时会作为 `ARGO_DOMAIN` 使用
- `TZ`：面板时区，默认 `Asia/Shanghai`
- `GH_PROXY`：GitHub 下载加速镜像（可空，如 `https://gh-proxy.com/`）
- `DASHBOARD_VERSION` / `AGENT_VERSION`：固定 dashboard / agent 版本号，可空
- `GH_BACKUP_USER` / `GH_REPO` / `GH_EMAIL` / `GH_PAT`：GitHub 备份还原配置（未填则不开备份还原）
- `NO_AUTO_RENEW`：设置后禁用定时更新备份/还原脚本
- `runx`：置为 `1` 时运行额外的 app 文件（默认不运行）
