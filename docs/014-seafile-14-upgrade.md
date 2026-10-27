# 014 - Seafile 14.0.9 升级实录（产品 1.2.0）

> 完成日期：2026-10-27 ｜ 状态：升级完成（1.2.0 已发布并灰度验证）
> 方法论沿用 [012](012-seafile-13-upgrade-assessment.md) 的四阶段（镜像层取证 → 补丁重放 → 回归 → 灰度发布）。

## 1. 结论先行

13.0.28 → 14.0.9（产品 1.1.1 → 1.2.0），全部四阶段零阻塞完成。14.0 相对 13.0 的
破坏面**远小于** 13 相对 12（那轮是 Django 4.2→5.2 + 缓存体系换代）：本轮无框架跳变、
无基础设施重做，大头只有一个——**WebDAV 开关机制换代**，外加管理后台 UI 改版导致
前端补丁漂移。

| 维度 | 12→13 | 13→14（本轮） |
|---|---|---|
| Django | 4.2 → 5.2 跳变 | 5.2.x 内小版本，无感 |
| 缓存 | memcached → redis 默认 | redis 保持默认，形态不变 |
| 补丁重放冲突 | 8/10 干净 + 2 处 import 机械合并 | 3 处冲突（均机械）+ 1 个前端文件被上游删除 |
| 镜像层锚点 | 6 锚点全过 | 5/6 全过，1 处上游改了 `su` 为 `su -p` |
| 部署机制破坏点 | conf 静态化、LE 移除、DB env 改名 | 仅 WebDAV env 化一处 |

## 2. 功能面：14.0 与我们有关的变更

| 官方变更 | 对我们的冲击 | 处置 |
|---|---|---|
| **WebDAV 改 env 开关**（`ENABLE_SEAFDAV`，seafdav.conf 删 `enabled`/`workers` 语义） | 直击 `custom_bootstrap.apply_webdav()`（13.0 写 conf 的 `enabled = true`）与 smoke/彩排的 seafdav 断言 | 全面改造，见 §4.2 |
| 本地密码设置改名（`DISABLE_ADFS_USER_PWD_LOGIN` 等 → `DISABLE_SSO_USER_LOCAL_PWD_LOGIN`） | 与补丁 0008（密码登录仅管理员）语义并存 | 复测无双重拦截，见 §5.1 |
| 管理后台 UI 改版（设置页重写） | 钉钉设置段的宿主文件 `web-settings.js` 被上游**删除** | 移植到新设置页，见 §3.2 |
| 人脸识别移除；metadata/缩略图/AI/SeaSearch 配置 env 化 | 均不部署 | 确认默认关闭即可，无动作 |
| wiki 依赖 SeaDoc | 知识库已按 [013](013-wiki-disabled.md) 关闭 | 无感 |

## 3. 源码层：10 个补丁 vs 14.0.9（重放实录）

基线 `3c408439`（v14.0.9-server），分支 `upgrade-14.0.9`，HEAD `cd12d4b9`，
tree_sha `68dc2ff7…`（已入 MANIFEST，CI 断言复现）。

### 3.1 冲突与解决（3 处，全部机械合并）

1. `seahub/context_processors.py` —— import 块漂移：保留 14.0 的 import 列表 + 我们的 dev 注释。
2. `seahub/views/sysadmin.py` —— 上游新增 `get_commit` import 与我们的 `is_dingtalk_enabled` 邻近：两者都保留。
3. `seahub/settings.py` —— EOF 处 `SEAFILE_VERSION = "12.0.14-dev"` 块上下文变了：补丁锚点重放后手工对齐（该值构建期会被 Dockerfile sed 成发布号，冒烟有断言）。

### 3.2 前端补丁漂移（本轮唯一超机械的地方）

- `frontend/src/pages/sys-admin/web-settings/web-settings.js` 在 14.0 **被上游删除**
  （管理后台设置页重写为 `settings/index.js`）。`git apply` 是原子的：一个不存在的
  文件让**整个** 10 合 1 补丁静默全回滚——症状是「apply 报成功但树没变」。修法：
  `git apply -3 --exclude=frontend/src/pages/sys-admin/web-settings/web-settings.js`。
- 钉钉设置段（ENABLE_DINGTALK / DINGTALK_APP_KEY / DINGTALK_APP_SECRET 三个设置项）
  按新页面结构（`Section` + `CheckboxItem`/`InputItem` 组件体系）重新落位在
  `settings/index.js` 的 Sync 段之后。

### 3.3 语义复测（源码级结论，运行时随彩排/灰度复验）

- **0008 vs `DISABLE_SSO_USER_LOCAL_PWD_LOGIN`（§5.1）**：无双重拦截 ✅
- **0009 vs 14.0 SERVICE_URL 计算（§5.2）**：与 13.0 结论相同，兼容 ✅
- 0003/0005（资料编辑/密码修改区域）、0001/0002（钉钉登录主体）：调用点源码均在，无漂移。

## 4. 镜像/部署层

### 4.1 patch-upstream.py：6 锚点 5 过 1 改

上游 14.0 的 start.py 把起 seahub 的 root 分支从 `su seafile -c` 改成
`su -p seafile -c`（保留环境变量），锚点 4 失配——这正是该脚本「匹配不到即构建失败」
设计要拦的东西。锚点改为 `su -p` 形式后，对 14.0.9 基础镜像实跑 6/6 全过。

nginx 静态 conf：与官方 14.0.9 逐行 diff，除两处定制（`server_name` 占位符 +
`$seafile_fwd_proto` 分流）和一个行尾空格外**完全一致**（上游仍未修 XFP 透传，
server_name 也仍无）。即 13.0 那版 conf 可直接沿用，头部注释更正为 14.0 基线。

### 4.2 WebDAV 机制换代（本轮唯一的部署机制破坏点）

**取证**（对 14.0.9 镜像实测，非文档推断）：

- 14.0 `seafile-monitor.sh:226`：`if [ $ENABLE_SEAFDAV ] && [ $ENABLE_SEAFDAV = "true" ]`
  —— 只认 env。
- 13.0 同文件有「env 未设则 `awk` 读 conf 的 enabled」回落（60-61 行）；**14.0 把这行
  回落删了**。所以 13.0 卷里 `enabled = true` 的 conf 在 14.0 下是死配置。
- seahub 侧对 seafdav.conf 只剩 `share_name` 解析（拼界面上的 WebDAV 地址，
  `utils/__init__.py:980`）；setup 模板照写 `enabled = false` 但已无人读。
- `share_name = /` → `/seafdav` 的改写 14.0 bootstrap.py 仍做，无需接管。

**改造**：

| 处 | 13.0 形态 | 14.0 形态 |
|---|---|---|
| `custom_bootstrap.apply_webdav()` | 把 conf 的 `enabled` 翻成 true | 不再写 conf；env=true 时确认接线，**env 缺失 loud warning**（WebDAV 静默关掉与「忘了不会报错」同类，不给它留位置） |
| compose（prod + dev） | 无此项 | `ENABLE_SEAFDAV=true` |
| smoke-test | 断言 conf 里有 `enabled = true` | 断言 conf **不被改动**（改它就是又去信死键）+ env 缺失时 loud warning |
| 彩排 | 同上 conf 断言 | 容器内 env=true + `/seafdav/` 端到端 401（wsgidav 活着的硬证据） |

**⚠️ 真实升级路径的坑（比机制本身重要）**：服务器上的 `seafile-prod.yml` 是从当时
Release 资产取的——1.1.1 及之前的版本**没有** `ENABLE_SEAFDAV=true`。只跑
`docker compose pull && up -d` 的话，14.0 镜像 + 旧 compose = WebDAV 静默关掉
（bootstrap 会打 loud warning，但功能仍是关的）。**升级 14.0 必须先从 1.2.0 Release
重取 seafile-prod.yml 再 up**（回滚回 13.0 镜像同样兼容：13.0 优先读 env）。

### 4.3 存活的假设（逐项复验）

- `heal_stale_caches`（12.0 老卷 memcached CACHES 自愈）**仍然必要**：14.0
  settings.py:1348-1356 照旧从文件现成的 `CACHES['default']['LOCATION']` 解析 redis
  主机/端口，REDIS_* env 只盖显式设的部分。老卷 `memcached:11211` 残留依然全站 500。
- 构建期 collectstatic stub：`CACHE_PROVIDER` 14.0 默认 `redis`（不再像 13.0 未设即
  raise），stub 仍显式给 `memcached` 以避免构建期依赖 redis 可用性——配方不变，
  Dockerfile 注释已更正。
- `MANAGED_SETTINGS` 5 项对 14.0 settings.py 逐项复核：全部仍有活的读取方
  （`ENABLE_WIKI` 上游 1009 行定义仍在）。

## 5. 与我们定制语义对撞的决策点

### 5.1 补丁 0008 vs `DISABLE_SSO_USER_LOCAL_PWD_LOGIN`

14.0 上游把「SSO 用户禁用本地密码」收拢成这一个设置（`utils/auth.py:102`，
`user_local_password_enabled()`），在登录表单 Step 2、密码认证**之后**检查。

0008 的拦截点在表单层密码校验**之前**（`auth/forms.py:80`）+ backend 兜底
（`base/accounts.py:837`）。普通用户走密码登录时 0008 先 raise，永远到不了上游那层；
管理员两边都放行。**无双重拦截、无报错时序变化**——补丁原样保留，不设上游新键。

### 5.2 补丁 0009（SERVICE_URL constance 化）vs 14.0 运行期计算

14.0 settings.py:1399-1405：`SEAFILE_SERVER_PROTOCOL`+`HOSTNAME` 都在时于导入期计算
SERVICE_URL——算出的只是 **constance 默认值**（`CONSTANCE_CONFIG` 注册处），后台
DB 值照常覆盖。与 13.0 同构，[011](011-service-url-admin-config.md) 的结论不变。

## 6. 回归与发布

1. **本地构建**：`./build-image.sh --local`（arm64）零警告；镜像内 smoke-test
   **全绿（SMOKE_OK）**，含新版 seafdav 断言、幂等、老卷自愈、nginx 域名替换全路径。
2. **CI 分支预演**：`gh workflow run build-image.yml --ref upgrade-14.0.9` ✅。
   **跨架构指纹逐字节一致**（amd64 CI vs arm64 本地）：seahub 包 995 文件
   `4d690057…`、前端 716 文件 `3d3b4ad7…`、media 787 文件 `787e2569…` 全同。
3. **反代彩排**（`rehearsal-rp.sh --from-tree --tag …:1.1.1.d3c372fa`）：38 断言全绿，
   含两条新的 WebDAV 断言（容器 env 接线 + `/seafdav/` 401）。
   - 彩排脚本本轮同步换代：旧 `seafdav.conf enabled = true` 断言验的是死配置，
     已替换（改脚本只改事实来源这一份，文档不复制）。
   - 预发布期彩排要用 `--from-tree`：Release 上的 seafile-prod.yml 还是旧版
     （无 ENABLE_SEAFDAV），取回来验的是错配置。
4. **发布**：合 main → VERSION `product_version = 1.2.0` → `release/1.2.0` → CI 发布
   tag `1.2.0.924f77dc`，搬通道 + Release 资产（含新 compose）。

### 6.1 198 灰度

灰度步骤（在 198 的 /opt/seafile-custom/deploy）：

```bash
cp seafile-prod.yml seafile-prod.yml.bak-1.1.1 && cp .env .env.bak-1.1.1
curl -fsSL -o seafile-prod.yml https://github.com/topiceyes/seafile-custom/releases/latest/download/seafile-prod.yml
diff seafile-prod.yml.bak-1.1.1 seafile-prod.yml   # 期望只差 ENABLE_SEAFDAV 一行
docker compose pull && docker compose up -d
```

回滚（一条命令，不改文件）：

```bash
SEAFILE_PRO_IMAGE=ghcr.io/topiceyes/seafile-mc:1.1.1.a1e0b916 docker compose pull \
  && SEAFILE_PRO_IMAGE=ghcr.io/topiceyes/seafile-mc:1.1.1.a1e0b916 docker compose up -d
```

灰度验证结果（198，2026-10-27，镜像 `1.2.0.924f77dc`）全绿：

| 项 | 结果 |
|---|---|
| 溯源 | 运行中 digest `3c225f4a…` == digest(:latest) == digest(:1.2.0.924f77dc) ✅ |
| bootstrap 日志 | 5 项定制齐全、WebDAV env 确认接线、server_name 替换 m-disc.moresec.cn，零 warning ✅ |
| WebDAV `GET /seafdav/`（未认证） | 401——env 机制在真实服务器上端到端生效 ✅ |
| 管理员表单登录（IP 直连 9800） | 302 + sessionid ✅ |
| 上传/下载回环 | 上传链接按 constance SERVICE_URL 派生 `https://i-disc.moresec.cn:7443/seafhttp/…`，上传返回 40 位文件 id，下载逐字节一致 ✅ |
| 钉钉 redirect_uri（域名入口） | `https://m-disc.moresec.cn/dingtalk/callback/`（https + 登记域名）✅；IP 直连入口跟随发起者为 http（0010 设计内行为，与 13.0 一致） |
| 外网两入口（m-disc / i-disc:7443） | 登录页 200；m-disc 外网表单登录 302 + 会话 ✅ |

备份留在 198：`seafile-prod.yml.bak-1.1.1` / `.env.bak-20261027`（确认无虞后可删）。
用户侧待验：真浏览器两入口走一遍 + 钉钉真机扫码登录。

## 7. 踩坑回写（本轮新增）

1. **`git apply` 原子回滚**：补丁里含上游已删除的文件时，整个 apply 静默全回滚且
   报成功。内环用 `git apply -3 --exclude=<死文件>`，并留意「树没变」这个症状。
2. **锚点漂移的好响声**：patch-upstream 的「匹配不到即失败」本轮第 3 次立功
   （`su` → `su -p`）。改锚点前先对上上游新代码的语义，别只改字符串。
3. **机制换代要追到「谁在读」**：WebDAV 不是「配置换个地方」，是「开关判定整个
   挪进 env + conf 回落删除」。只改写入方不查读取方，就会留下写死键的僵尸代码。
4. **compose 是 Release 资产，升级两步缺一不可**：镜像升级（pull）和 compose 升级
   （重取）是两条独立路径，后者漏了功能静默关。 loud warning 是最后一道网，不是解法。
5. **预发布彩排用 `--from-tree`**：Release 资产永远滞后于工作树，改了三件套
   （compose/env 模板/init 脚本）之一的升级，彩排取工作树才验的是将要发布的东西。

## 8. 升级检查清单（下次 14.x → 15.x 用）

- [ ] `docker pull seafileltd/seafile-mc:<新>`，提取 /scripts、nginx conf、setup 模板逐点 diff（不猜）
- [ ] patch-upstream 6 锚点对实镜像 dry-run（`docker run` 挂脚本即可，不用真构建）
- [ ] MANAGED_SETTINGS 逐项 grep 14.0 settings.py 确认读取方仍在
- [ ] `heal_stale_caches` 读取方（settings.py 的 LOCATION 解析）是否仍存在
- [ ] 上游删除的文件：`git status` 树对比 + apply 用 `--exclude` 兜
- [ ] compose 三件套 diff（旧 Release 资产 vs 新工作树），识别「必须重取 compose」类变更
- [ ] smoke / 彩排断言里所有「conf 内容断言」确认读取方还活着
