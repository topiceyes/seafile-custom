# 012 - Seafile 13.x 升级评估（差异分析底稿）

> 完成日期：2026-09-24 ｜ 状态：**已落地**（2026-09-24 当天执行完 Phase 1–3：
> 补丁重放 / 镜像层改造 / 本地+CI 构建 / 彩排 37 断言全绿，镜像 tag `1.1.0.e1d530c7`）。
> 执行中实撞的三个新坑已回写进对应代码注释：① db_update_helper.py 只从 env 读库密码；
> ② 三个库名 env 空串注入坑（全新卷首启）；③ 静态 conf 占位符替换后必须 reload nginx。
> 0009 实测结论：保留（见 docs/011 §10）
> 调研口径：seahub 12.0 基线 `0877ad7` → 13.0 分支 tip `7555f87`；
> 镜像 `seafile-mc:12.0.14` → `seafile-mc:13.0.28`（CE）
> 配套：[007 §6](007-production-deployment.md)（升级四处同步流程）、[010 §4](010-ci-release-pipeline.md)（tag 血缘断言）

## 1. 结论先行

**可行，且比预期干净**。CE 在 13.x 活跃维护：13.0.6 起 CE/Pro 交错发版，至 2026-09 的
13.0.28 约 9 个月出了 15+ 个 CE 小版本；**CE 唯一官方渠道只剩 Docker**（二进制包停发，
升级说明原文："Deploying Seafile with binary package is no longer supported for community
edition."）——对我们无影响，我们本来就是自建镜像。

工作量分布（本文后面三节的逐条明细）：

| 层 | 工作量 | 性质 |
|---|---|---|
| seahub 补丁重放（10 个） | **小**（半天） | 8/10 干净落位，2 处 import 冲突纯机械 |
| 镜像/部署层 | **中**（1–2 天） | 5 处破坏点，每处有明确解法 |
| Django 4.2→5.2 行为回归 | **隐性大头**（约 1 天） | 登录/SSO/WebDAV/上传下载要全链路回归 |

总量级：**一周内可完成一轮完整升级**。

> ⚠️ 调研中修正的两个说法：**「日历组件」不是日历功能**——`@seafile/seafile-calendar`
> 只是管理后台统计页的日期选择器 npm 包；**「管理后台 UI 改版」是 14.0 的主题**，
> 不是 13.0（13.0 只进了统计视图 statistics view）。

## 2. 功能面：13.0 带来什么

| 主打 | 说明 |
|---|---|
| **元数据服务器（metadata server）** | 13.0 架构核心：文件结构化元数据 + 六种视图（Table/Kanban/Gallery/**Map**/Card/Statistics）；13.0.24 起新建库自动初始化 metadata |
| 通知服务器 | Web 实时刷新，独立镜像，`ENABLE_NOTIFICATION_SERVER` 默认 false |
| 缩略图服务器 | 独立处理视频/图片/PDF 缩略图 |
| Seafile AI | 抽取/摘要/翻译/打标/人脸检测/OCR（**强制要求 Redis**） |
| SeaSearch 1.0 / SeaDoc 2.0 | 生产级全文搜索（独立服务）；块编辑器 + AI 写作助手 + 白板（Excalidraw）；sdoc 1.0→2.0 必须重新部署 |
| Wiki 增强 | 块编辑、评论、Ask AI、sdoc/Markdown 导入导出 |
| 废弃 | 旧文件标签（tags）→ 层级标签；**WebDAV 不再支持 LDAP 账号登录**（改个人页生成 token） |

对钉钉定制最关键的事实：**上游自带的 `seahub/dingtalk/` 模块 12.0→13.0 几乎没动**
（`settings.py`/`admin 端点`/`oauth backends` 等核心文件零漂移），钉钉 SSO/部门同步面稳定。

来源：[Seafile 13.0 is ready（官方公告）](https://forum.seafile.com/t/seafile-13-0-is-ready/24876)、
[升级说明](https://raw.githubusercontent.com/haiwen/seafile-admin-docs/master/manual/upgrade/upgrade_notes_for_13.0.x.md)、
[seahub 13.0 分支](https://github.com/haiwen/seahub/commits/13.0)。

## 3. 源码层：10 个补丁 vs 13.0（已实测）

**方法**：partial clone 拉 13.0 树，把 `patches/*.patch` 逐个 `git apply -3` 三方合并重放
——重放难度的金标准，不是目测。基线 → 13.0 共 **1384 个提交**、300+ 文件，但落在
我们补丁触碰的 21 个文件上的冲击面小得多。

| 结果 | 明细 |
|---|---|
| ✅ **8/10 全自动干净落位** | 0001、0002、0004~0008、0010 |
| ⚠️ 0003 冲突 | 仅 `seahub/profile/views.py` **import 块**：我们改 1 行导入（`ENABLE_DINGTALK` → `is_dingtalk_enabled`）+ 1 处调用；上游重排了该文件 imports。机械合并 |
| ⚠️ 0009 冲突 | 仅 `seahub/base/context_processors.py` **import 块**：同一行 import，我们删 `FILE_SERVER_ROOT`、上游追加了 13.0 新配置项（metadata/通知服务器/人脸识别等）。机械合并 |
| 文件存活 | 21 个补丁文件在 13.0 **全部存在**；上游自带 dingtalk 模块完整保留 |
| 零漂移文件 | 8 个补丁文件 12.0→13.0 一字未动：`dingtalk/settings.py`、`api2/endpoints/admin/dingtalk.py`、`oauth/backends.py`、`admin/web_settings.py`、`api2/endpoints/ocm.py`、`ocm_via_webdav/ocm_api.py` 等——钉钉集成核心全在这批里 |

**语义复测点**（apply 干净 ≠ 语义等价）：

1. `profile/views.py` `edit_profile` 被上游重构：社交绑定/密码权限逻辑抽到**新模块
   `seahub/utils/auth.py`**（`can_user_update_password`、`is_force_user_sso`）。
   0003/0005 在该区域的逻辑要功能复测。已核 `is_force_user_sso` 实现：只管 ADFS/OAuth
   组织级强制 SSO，**不覆盖钉钉**，0008 不因此冗余。
2. `auth/forms.py` 上游 ±106 行重构 + `login.html` ±37 —— 0008（密码登录仅限管理员）
   是重点复测对象。
3. `settings.py` ±190 行（160+/30−；新增 `IS_SEAFILE_PLUS` 版本旗标）——0002/0003/0008/0009
   都动它，合并虽干净，构建期的 `SEAFILE_VERSION` grep/sed 锚点要重验。

## 4. 镜像/部署层：重灾区，但每处有机械解

取证方式：对比 seafile-docker 仓库 `scripts_12.0`/`scripts_13.0` + 本地
`seafileltd/seafile-mc:12.0.14` 实际镜像（验证过 master 的 scripts_12.0 与该镜像逐点一致，
基线无漂移）。13.0 镜像内 `/scripts` 目录结构有变，**8 个补丁锚点里 7 个原样保留**。

### 4.1 破坏点清单（按必须处理的顺序）

| # | 破坏点 | 解法 |
|---|---|---|
| 1 | **nginx 模板机制整个废除**：13.0 没有 `/templates/` 目录，conf 构建期静态烘入 `/etc/nginx/sites-enabled/seafile.nginx.conf`；`generate_local_nginx_conf()` 函数删除——`patch-upstream.py` 第 3 处补丁锚点 0 匹配，构建会按设计响亮失败 | 改为构建期直接替换静态 conf（仍是 COPY 一条），XFP 两处照补（**上游依然没修这个坑**，静态 conf 的 `location /` 和 `/seafdav/` 还是没有 `X-Forwarded-Proto`）；静态 conf 无 `server_name` 需新增（`$http_host = $server_name` 恒不成立，域名判定输入没了）；日志路径对齐 13.0 的 `/shared/seafile/logs/`。**`sync_nginx_conf` 整套退役**——病根被上游治好：conf 随镜像走，「数据卷 conf 滞留」（403 第三形态）在 13.0 结构性消失 |
| 2 | **DB 环境变量全家改名**：`DB_HOST`→`SEAFILE_MYSQL_DB_HOST`、`DB_USER`→`SEAFILE_MYSQL_DB_USER`、`DB_PASSWORD`→`SEAFILE_MYSQL_DB_PASSWORD`、`DB_PORT`→`SEAFILE_MYSQL_DB_PORT`、`DB_ROOT_PASSWD`→`INIT_SEAFILE_MYSQL_ROOT_PASSWORD`；且 **13.0 删掉了 wait_for_mysql 读 seafile.conf 的回落**，只读环境变量 | compose 环境段同步改名。不改 = 升级即 `wait_for_mysql` 死循环（我们 prod compose 传的 4 个旧变量在 13.0 全失效） |
| 3 | **cache 默认 memcached → redis**：`CACHE_PROVIDER` 默认 `redis`，只认 redis/memcached，其它值直接 raise | 选边：换 redis 容器（官方形态；**Seafile AI 硬要求 Redis**）或 `CACHE_PROVIDER=memcached` 续命 |
| 4 | **collectstatic 配方炸**：stub 环境没设 `CACHE_PROVIDER`，settings 导入即 `raise ValueError` | 配方补 `CACHE_PROVIDER=memcached`（或配 redis LOCATION） |
| 5 | 机械项 | Dockerfile 的 `BASE_IMAGE`/`INSTALLPATH`/`SEAFILE_VERSION` → 13.0.28；nginx 模板 COPY 行删除；`VERSION` 的 `seafile_version` 同步（CI 断言兜底，半途而废会被拦） |

### 4.2 存活的假设（全部程序化验证）

- **`init_custom_settings` 插入窗口语义完好**：start.py 的调用时序不变
  （wait_for_mysql → init_seafile_server → check_upgrade → 起服务），7/8 锚点原样保留。
- **`open('w')` 首启重写前提成立**：13.0 的 `generate_seahub_config` 仍整体重写
  seahub_settings.py，幂等追加模型不变。注意 13.0 写入内容大幅缩水（只剩 utf8 注释 +
  SECRET_KEY；SERVICE_URL/DATABASES/CACHES 改为运行期即时计算），旧卷遗留值不会断
  （seahub 13 settings.py 对旧 `DATABASES` 做 update 后再被 env 覆盖）。
- **seahub.sh 的 sleep 5 + pgrep 误判在 13.0 原样存在**（v13.0.28-server 逐字相同）
  → 我们的 `start_service_retry` 补丁继续对症，两处锚点成立。
- **WebDAV**：`apply_webdav` 的 `^enabled\s*=` 锚点原样成立（bootstrap 仍把 share_name 改 `/seafdav`）。
- **Python 同为 3.12**（两版镜像同 ubuntu:24.04 配方），Python 层无跳变。
- 环境变量：`NON_ROOT`、`TIME_ZONE`、`INIT_SEAFILE_ADMIN_*`、`JWT_PRIVATE_KEY`（13.0
  seahub.sh 仍强制要求，我们已在传）全部保留。
- **SEAFILE_VERSION sed 配方兼容**：13.0 的 `write_version_to_settings_py()` 以
  `open('a+')` 追加，与我们的 grep/sed 兼容（后行生效，与 12.0 现状相同）。

### 4.3 环境变量与依赖速查

| 类 | 12.0 → 13.0 |
|---|---|
| DB 变量 | `DB_*` → `SEAFILE_MYSQL_DB_*`（见 4.1 #2）；新增 `*_CCNET_DB_NAME` 等自定义库名 |
| 废弃 | `SEAFILE_SERVER_LETSENCRYPT`（acme.sh/ssl.sh 整套移除；SERVICE_URL 协议改由 `SEAFILE_SERVER_PROTOCOL`+`SEAFILE_SERVER_HOSTNAME` 即时计算）、`INIT_S3_*`、`CLUSTER_INIT_ES_*` |
| 配置迁入 `.env` | 需删 seafevents.conf `[DATABASE]`、seafile.conf `[database]/[memcached]/…`、seahub_settings.py 的 `SERVICE_URL/DATABASES/CACHES/FILE_SERVER_ROOT` 等废弃段 |
| Django | 4.2 → **5.2**（跳变点在 v13.0.9 的 requirements.txt） |
| pip | gevent 移除、pyjwt 2.10、pillow 11.3、新增 cairosvg/scikit-learn；apt 新增 exiftool |
| 官方 13.0 compose 默认 DB | MariaDB 10.11（与我们一致） |

## 5. 与我们定制**语义对撞**的决策点（不只是改代码）

1. **0009（SERVICE_URL 后台管理化）vs 上游新模型**——唯一的设计级冲突。13.0 上游自己
   把 SERVICE_URL 改成运行期从 `SEAFILE_SERVER_PROTOCOL`+`SEAFILE_SERVER_HOSTNAME`
   即时计算、不再落盘。与我们 0009 的「后台可改、免重启」目标方向相同，但**事实来源
   相反**（env 变量 vs 管理后台 DB）。重放时必须二选一或明确优先级：
   保留 0009（后台模型，钉钉多入口场景已依赖它）就要在 13.0 上重验上游即时计算路径
   是否绕开了我们的覆盖；顺上游走 env 则 0009 整个退役。**决策前需 13.0 实测**。
2. **memcached vs redis**（4.1 #3）：想要 AI/元数据完整功能则没得选，只能 redis。
3. **13.0.28 vs 直奔 14.0**：14.0 在发布前夜——CE `14.0.8-testing` 镜像 2026-09-21
   已推、官方演示站 plus.seafile.com 在跑 14.0.8，但**尚无稳定公告**（论坛只有
   2026-06 的 14.0 Preview: UI Improvements）。若动手窗口在几个月后，值得评估直升 14.0
   （主题恰是管理后台 UI 改版，与我们的后台管理化定制区重叠，值得等它定型）。

## 6. 已知问题里与我们有关的（论坛/官方回帖实证）

- **SeaDrive 13.0.25 存在随机删文件问题**（影响 100+ 用户实例，官方已介入）——
  若用户在用 SeaDrive 客户端，这是当前 13.x 最大的实际风险，升级前确认客户端版本规避。
- 13.0.12 起容器**无视数据卷里的 nginx conf**（论坛高频坑）——对我们反而是利好：
  我们的构建期替换方案与上游新模型同构。
- `ALLOWED_HOSTS` 需含 `127.0.0.1`（或删除），否则 seaf-server 内部鉴权请求 400
  ——12.0 起就有、13.0 仍是高频坑，我们的反代形态（宝塔宿主反代 + 云反代双入口）要验。
- 升级前**先清 Activity 大表**（否则 DB 迁移极慢）；有用户报告需手工补建
  `base_usermonitoredrepos` 表。
- ARM64 坑：13.0.13+ 的 arm 镜像要用 `-arm` 后缀标签——影响开发机彩排，不影响生产 amd64。

## 7. 建议路径

```
Phase 0  决策：redis/memcached、0009 存废、13 vs 14（§5 三条）
Phase 1  镜像层改造（§4.1 五项；含 rehearsal-rp 彩排）          ~1–2 天
Phase 2  补丁重放：基线订到 v13.0.28-server（本轮试的是分支 tip 7555f87，
         动手时对准 tag 再跑一次 apply -3），2 处 import 合并 +
         export-patches.sh 重导（MANIFEST/tree_sha 自动刷新）   ~半天
Phase 3  回归：rehearsal-rp.sh 38 断言 + CI 冒烟 + Django 5.2
         行为面（登录/钉钉 SSO/WebDAV/上传下载/分享）            ~1 天
Phase 4  生产灰度：先单机 pull + 真浏览器登录走一遍，
         回滚钉旧 tag（既有通道 tag 机制原样可用，docs/007 §6）
```

发版侧零新增流程：版本制 1.0.0 已就位（VERSION + CI 血缘断言），升级时改
`VERSION` 的 `seafile_version`（12.0.14 → 13.0.28），Dockerfile 的
BASE_IMAGE/INSTALLPATH 同步，CI 断言「seafile_version == BASE_IMAGE」会拦半途而废。

## 8. 未确认项（诚实清单）

- 官方逐版本 changelog 正文：已迁至 plus.seafile.com wiki（JS 渲染，抓取失败），
  §1 的时间线以 git compare 证据替代
- 外部 MySQL（非 MariaDB）的官方版本要求：手册未写
- CE/Pro 策略官方长文：未找到，「仅 Docker 渠道」的唯一依据是升级说明那句话
- 13.0 运行期 SERVICE_URL 即时计算与我们 0009 覆盖的实际交互（§5.1）：需 13.0 实测
