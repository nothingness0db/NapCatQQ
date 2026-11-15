# AGENT.md

自建 NapCat 的部署状态、改动记录与操作手册。最后更新：2026-11-15 12:30（CST）。

## 1. 背景

上游 `NapNeko/NapCatQQ` 已于 2026-11-12 清空（只剩一个 `docs: ending` 的 README），代码不再更新。
本仓库是 `CllvvR/NapCatQQ` 的 fork（分支 `qqbackup-selfhost`，基线提交 `454cc0e`，2026-10-05），
用于自托管 QQ 机器人部署，并在此基础上做本地修补。

## 2. 部署拓扑

| 项目 | 值 |
| --- | --- |
| 主机 | `nothing`（Linux，用户 `eria`） |
| Compose 目录 | `/home/eria/data_disk/astrbot` |
| Compose 文件 | `compose.yml` + `compose.override.yml` |
| NapCat 容器 | `napcat`，镜像 `napcat-custom:qqbackup`（本地构建，未推送 registry） |
| WebUI | `http://100.110.46.118:6099`（仅绑定 Tailscale IP） |
| OneBot | 反向 WS：`ws://astrbot:6199/ws`（连接 `astrbot` 容器） |
| 网络 | `astrbot_astrbot_network` |

挂载：

- `./data:/AstrBot/data`
- `./napcat/config:/app/napcat/config`
- `./ntqq:/app/.config/QQ`（QQ 登录态、设备信息）

## 3. 源码与构建

| 项目 | 值 |
| --- | --- |
| Fork | `nothingness0db/NapCatQQ` |
| 分支 | `qqbackup-selfhost` |
| 远端克隆 | `/home/eria/napcat-src` |
| 基线 | `454cc0e ci(release): 下游 AppImage 用的 QQ 换成 3.2.32-52194`（2026-10-05） |
| 构建工具 | Node 22 + corepack pnpm 9.15.4（`~/.local/bin/pnpm`） |

构建流程（与上游 CI 一致）：

```bash
pnpm --filter napcat-webui-frontend run build
pnpm run build:shell
pnpm --filter napcat-plugin-builtin run build
```

产物：`packages/napcat-shell/dist`（约 89 MB，含 `napcat.mjs`、`static/`、`native/`）。

### 3.1 运行时依赖的特殊处理

构建产物里的 `package.json` 是仓库根 `package.json`，带 `devDependencies`。
在本机 npm 10.9.9 下执行 `npm install --omit=dev` 会触发 arborist 的
`Cannot read properties of null (reading 'edgesOut')`（解析 vitest peer 时崩溃）。

处理方式：把 `dist/package.json` 换成只含运行时依赖的最小版本
（本仓库根目录的 `dist-package.json`），再安装：

```json
{
  "name": "napcat",
  "private": true,
  "type": "module",
  "version": "0.0.1",
  "dependencies": {
    "express": "^5.0.0",
    "ws": "^8.18.3"
  }
}
```

### 3.2 镜像构建

`packages/napcat-shell/dist/Dockerfile`：

```dockerfile
FROM mlikiowa/napcat-docker:latest
RUN rm -rf /app/napcat/napcat.mjs /app/napcat/static /app/napcat/native \
           /app/napcat/node_modules /app/napcat/worker /app/napcat/package.json \
           /app/napcat/config /app/napcat/qqnt.json
COPY . /app/napcat/
RUN chown -R 1000:1000 /app/napcat
```

这样只替换 shell 代码，保留镜像里的 QQ、entrypoint、模板等。

## 4. 本次改动记录

1. `compose.override.yml`：napcat 的镜像从 `mlikiowa/napcat-docker:latest`
   改为 `napcat-custom:qqbackup`。
   备份：`compose.override.yml.bak-20261115-034601`。
2. 新增 `/home/eria/napcat-src/rebuild-napcat.sh`：改完源码后一键重建并部署。
3. 新增 `/home/eria/napcat-src/dist-package.json`：构建时替换 dist 的 package.json。
4. 在 `dist/` 内新增 `Dockerfile`，用于打派生镜像。
5. 容器于 2026-11-15 03:46 用新镜像重建；`napcat.mjs` 为本地构建版本
   （3,112,753 字节，含 `SelfOffline` 静默离线恢复逻辑）。

## 5. 运行状态与事件记录（2026-11-15）

- `03:47` 容器启动，等待扫码。
- `03:50` 扫码登录成功。
- `05:57:13` 收到 `[KickedOffLine] 你的账号当前登录已失效`（唯一一次真实掉线）。
- `06:04:47` 恢复逻辑重启容器，因 Docker 入口未带 `-q`，回到二维码模式等待。
- `12:22:27` 快速登录；`12:22:46` 扫码确认；之后正常收发消息。

日志里 `Login Error ErrType:1 ErrCode:3`（185 次）和二维码写入（188 次）
是二维码每 2 分钟过期自动刷新，**不是掉线重连**。

## 6. 已知问题 / 待办

1. **PacketBackend 版本表缺 QQ 3.2.34-53644**
   - 现象：`[Core] [Packet] PacketBackend 不支持当前QQ版本架构：3.2.34-53644-x64`
   - 原因：本分支基线是 2026-10-05，上游 2026-10-09 才补上 53644 的偏移表。
   - 影响：底层发包能力被禁用，部分 OneBot 动作不可用。
   - 修复：从 10-27 快照补 `packet.json` / `appid.json` / `napi2native.json`
     中 `3.2.34-53644-x64` 的条目（`packet.json` 值为
     `{"send":"CBF25A0","recv":"CBF60E0"}`），然后重建镜像。
2. **重启后需要重新扫码**
   - Docker entrypoint 只有设置 `ACCOUNT` 环境变量才会带 `-q` 快速登录。
   - 建议在 compose 的 napcat 环境变量里加 `ACCOUNT=<主账号QQ>`，
     降低掉线恢复后的扫码成本。
3. 本地镜像 `napcat-custom:qqbackup` 只存在于本机，换机器部署需要重新构建。

## 7. 操作手册

### 改代码并部署

```bash
cd /home/eria/napcat-src
# 修改源码...
./rebuild-napcat.sh          # 会自动 pull、构建、打镜像、docker compose up -d napcat
SKIP_PULL=1 ./rebuild-napcat.sh   # 不想被 pull 覆盖本地改动时
```

### 回滚到官方镜像

把 `compose.override.yml` 里的 `image:` 改回 `mlikiowa/napcat-docker:latest`，然后：

```bash
cd /home/eria/data_disk/astrbot && docker compose up -d napcat
```

### 查看状态

```bash
docker ps --filter name=napcat
docker logs --tail 100 napcat
docker logs --since 2026-11-15T03:45:00 napcat 2>&1 | grep -a -E "登录|离线|Kicked|二维码"
```

> 注意：WebUI token、QQ 账号等敏感信息不写入本文件；请从服务器上的
> `compose.yml`/`.env` 获取。
