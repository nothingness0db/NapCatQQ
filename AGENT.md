# AGENT.md

自建 NapCat 的部署状态、改动记录与操作手册。最后更新：2026-11-15 21:30（CST）。

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

Dockerfile 模板在仓库的 `docker/Dockerfile.napcat-dist`（构建时由脚本复制到 `dist/Dockerfile`）：

```dockerfile
FROM mlikiowa/napcat-docker:latest
RUN rm -rf /app/napcat/napcat.mjs /app/napcat/static /app/napcat/native \
           /app/napcat/node_modules /app/napcat/worker /app/napcat/package.json \
           /app/napcat/config /app/napcat/qqnt.json
COPY . /app/napcat/
RUN dpkg -i --force-depends --force-overwrite --force-downgrade /app/napcat/qq.deb \
 && rm -f /app/napcat/qq.deb \
 && sed -i 's#"main": *".*"#"main": "./loadNapCat.js"#' /opt/QQ/resources/app/package.json \
 && grep -q '"main": "./loadNapCat.js"' /opt/QQ/resources/app/package.json \
 && grep -q '"version": "3.2.32-' /opt/QQ/resources/app/package.json \
 && echo "QQ 3.2.32 + NapCat injection OK"
RUN chown -R 1000:1000 /app/napcat
```

两条与「只替换 shell」不同的关键步骤，都是为了兼容本分支的 1.0.0-dev shell：

1. **装 3.2.32 的 deb**：基础镜像里的 QQ 是 3.2.34-53644，该版本的登录服务与本 shell
   不兼容（`connect()` 成功但永不回调、二维码不生成）。deb 来自
   `/home/eria/napcat-debs/QQ_3.2.32_260812_amd64_01.deb`
   （SHA256 `d085dd89397225061eb9f194308f688129818ed445777e97a4a0a16e13d7b0e8`，
   源 `Rodert/qq-versions` 归档；官方 CDN 带签名链接已 404）。
2. **改回 `main`**：装 deb 会把 `/opt/QQ/resources/app/package.json` 的 `main`
   覆盖成 QQ 原生入口，QQ 能启动但 NapCat 不加载、6099 也不监听。`sed` 改回
   `./loadNapCat.js`，并用 `grep` 校验版本和入口，写错了构建直接失败。

## 4. 本次改动记录

1. `compose.override.yml`：napcat 的镜像从 `mlikiowa/napcat-docker:latest`
   改为 `napcat-custom:qqbackup`。
   备份：`compose.override.yml.bak-20261115-034601`。
2. 新增 `/home/eria/napcat-src/rebuild-napcat.sh`：改完源码后一键重建并部署。
3. 新增 `/home/eria/napcat-src/dist-package.json`：构建时替换 dist 的 package.json。
4. 在 `dist/` 内新增 `Dockerfile`，用于打派生镜像。
5. 容器于 2026-11-15 03:46 用新镜像重建；`napcat.mjs` 为本地构建版本
   （3,112,753 字节，含 `SelfOffline` 静默离线恢复逻辑）。

### 4.1 2026-11-15 晚间（QQ 降版本）

6. `packages/napcat-core/external/{packet,appid,napi2native}.json`：补 `3.2.34-53644-x64`
   条目（来源 `XingYunStar/NapCatQQ` v4.18.42）。
   packet `{"send":"CBF25A0","recv":"CBF60E0"}`、appid `537391664` /
   `V1_LNX_NQ_3.2.34_53644_GW_B`、napi2native `{"send":"6E5AB20","recv":"3A12CD0"}`。
   3.2.32 下不生效，留着以后升 3.2.34 用。
7. `packages/napcat-shell/base.ts`：登录服务回退。QQ 3.2.32 上 `onLoginConnected`
   偶发不回调（`connect()` 返回 true、MSF 在线），二维码永远不生成。现在注册监听后
   起一个 5 秒定时器：既没登录也没 `qrcodeurl` 就主动调一次 `getQRCodePicture()`；
   之后过期刷新仍走原有的 `ErrCode 3` 监听。
8. `docker/Dockerfile.napcat-dist`：新的镜像模板（QQ deb 降版 + `main` 注入修复，
   见 §3.2）。原来手写在 `dist/Dockerfile` 里，会被 `vite build` 清掉。
9. `rebuild-napcat.sh`：重写。校验 deb SHA256 → 前端/shell/插件构建 → 把 Dockerfile
   模板和 qq.deb 放回 `dist/` → `npm install --omit=dev` 用 `dist-package.json` →
   `docker build` → 删掉 `dist/qq.deb`。新增 `BUILD_ONLY=1` 只打镜像、不重建容器
   （当前没配快速登录，重建 = 必须重新扫码）。
10. `/home/eria/data_disk/astrbot/ntqq/versions/config.json` 从 3.2.34 改成 3.2.32-52194
    （备份 `config.json.bak-3.2.34-201039`）。

回滚点：镜像 `napcat-custom:qqbackup-before53644-20261115`。

## 5. 运行状态与事件记录（2026-11-15）

- `03:47` 容器启动，等待扫码。
- `03:50` 扫码登录成功。
- `05:57:13` 收到 `[KickedOffLine] 你的账号当前登录已失效`（唯一一次真实掉线）。
- `06:04:47` 恢复逻辑重启容器，因 Docker 入口未带 `-q`，回到二维码模式等待。
- `12:22:27` 快速登录；`12:22:46` 扫码确认；之后正常收发消息。

日志里 `Login Error ErrType:1 ErrCode:3`（185 次）和二维码写入（188 次）
是二维码每 2 分钟过期自动刷新，**不是掉线重连**。

### 5.1 晚间事故与恢复（2026-11-15）

- 白天起 NapCat 不可用：WebUI 起来了但从来没有二维码。排查发现基础镜像的 QQ
  已被上游推到 3.2.34-53644，本分支 shell 与之不兼容（偏移表缺失只是第一层）。
- `20:42` 补完偏移表 + 降 QQ 到 3.2.32 + 修 `main` 注入后重建，二维码恢复生成。
- `20:51:08` 扫码但没在手机上点确认，`20:51:15` 报 `ErrCode 10`（二维码过期）。
- `21:01:30` 重新扫码，`21:03:35` 登录成功；`21:03:31` AstrBot 的 OneBot 适配器已连上。
- 结论：**二维码有效期约 2 分钟，扫完必须立刻在手机端点「确认登录」。**

## 6. 已知问题 / 待办

1. ~~**PacketBackend 版本表缺 QQ 3.2.34-53644**~~ **已修**（见 §4.1 第 6 条）。
   但注意：补了偏移表不等于 3.2.34 能用——本分支 shell 的登录服务与 3.2.34 不兼容，
   所以镜像仍固定在 3.2.32-52194。真要升 3.2.34，得先确认 shell 兼容性。
2. **重启后需要重新扫码**
   - Docker entrypoint 只有设置 `ACCOUNT` 环境变量才会带 `-q` 快速登录。
   - 建议在 compose 的 napcat 环境变量里加 `ACCOUNT=<主账号QQ>`，
     降低掉线恢复后的扫码成本。
3. **`vite build` 会清空 `dist/`**
   - `pnpm run build:shell` 会删掉 `dist/` 里手工放的东西（Dockerfile、qq.deb）。
   - 现在由 `rebuild-napcat.sh` 在构建后自动放回，**不要再手写 `dist/Dockerfile`**。
4. 本地镜像 `napcat-custom:qqbackup` 只存在于本机，换机器部署需要重新构建。

## 7. 操作手册

### 改代码并部署

```bash
cd /home/eria/napcat-src
# 修改源码...
./rebuild-napcat.sh          # 会自动 pull、构建、打镜像、docker compose up -d napcat
SKIP_PULL=1 ./rebuild-napcat.sh   # 不想被 pull 覆盖本地改动时
SKIP_PULL=1 BUILD_ONLY=1 ./rebuild-napcat.sh   # 只打镜像，不重建容器（不会让 QQ 掉线）
```

> `rebuild-napcat.sh` 默认结尾会 `docker compose up -d napcat`，**容器重建 = QQ 掉线 =
> 必须重新扫码**（没配 `ACCOUNT`）。只想更新镜像时加 `BUILD_ONLY=1`。
> 二维码有效期约 2 分钟，扫完立刻在手机上点「确认登录」，否则 `ErrCode 10`。

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
