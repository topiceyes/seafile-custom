# 011 - 站点地址（SERVICE_URL）管理化

> 完成日期：2026-09-20 ｜ 补丁：`patches/0009` ｜ 状态：dev 已验证，随生产镜像上线
> 前置：[002 - 钉钉配置管理化](002-dingtalk-admin-config.md)（同一套 constance 套路）、
> [007 - 生产部署](007-production-deployment.md)

## 1. 需求

起因是一句质问：**「你的回调地址、分享链接、下载链接都是应该配置在数据库里面的，你写死在配置文件里面干什么？」**

原有的做法是：域名在**首启**时由环境变量写进 `seahub_settings.py`，之后想改得跑一个脚本改文件 + 重启。
这确实是错的——域名是运行期部署参数，不是构建期/首启产物。改个域名要停机 + 跑脚本，这个代价没有任何理由。

**本补丁之后**：`SERVICE_URL` 在「系统管理 → 设置」页填，**保存即生效，不用重启**。

## 2. 先澄清一个前提：这个值必须有个来源

「反代直接拿 IP:端口访问容器，所以应用不该关心域名」——这句话对了一半。

**对的部分**：截图跳转、健康检查这类**代理 → 容器**的流量，确实与应用无关，应用不该知道代理的存在。

**不能成立的部分**：Seafile 要生成**发到用户浏览器**的绝对链接——分享链接、下载链接、邮件里的链接、
钉钉回调地址。浏览器够不着内网 IP:端口，所以这些链接必须是公网域名。**一定有个地方要提供这个域名。**

> **考虑过但否决的方案：从请求头现推。** 代理会把 `Host` / `X-Forwarded-Host` 传进来，理论上可以零配置。
> 否决原因：攻击者可以伪造 `Host` 头，让服务端生成的分享链接指向他的域名（host header injection）。
> 除非 `ALLOWED_HOSTS` 锁死且代理强制覆写该头，否则不能这么干。
> 所以**必须有一个显式配置**——本补丁解决的是「配置放哪、什么时候能改」，不是「能不能不配」。

## 3. 方案

`SERVICE_URL` 进 constance（与 002 的钉钉配置同一套机制，`CONSTANCE_BACKEND = 数据库`、
`CONSTANCE_DATABASE_CACHE_BACKEND = 'default'`）：

- 默认值 = `seahub_settings.py` / `SEAFILE_SERVER_*` 环境变量算出来的值（即首启的占位域名）
- 后台保存后覆盖默认值；后台**清空**则回落默认值
- 存的表是 `seahub_db.constance_config`，与数据卷同生命周期，重启/换镜像都不丢

**`FILE_SERVER_ROOT` 不单独注册**，由 `SERVICE_URL` 推导。理由见 §4.2。

## 4. 关键改造点

### 4.1 两个访问函数（`seahub/utils/__init__.py`）

`get_service_url()` 改为读 constance，失败时静默回落：

```python
try:
    from constance import config
    url = config.SERVICE_URL or ''
except Exception:
    url = ''          # 数据库未就绪 / 表未迁移 / 独立脚本：不能把启动期或迁移期打断
if not url:
    url = seahub.settings.SERVICE_URL
return url.rstrip('/')
```

`try/except` 不是防御性冗余：`migrate` 期间、以及不经过 Django 启动的独立脚本里，
constance 读表会抛异常，而 `SERVICE_URL` 在这些路径上也会被读到。

### 4.2 `FILE_SERVER_ROOT` 改为推导

```python
def get_fileserver_root():
    return get_site_scheme_and_netloc() + '/seafhttp'
```

上游让这两个值分开填是**冗余**：改了域名只改一处、另一处忘了，症状就是
「页面能打开、但上传下载坏」——很难查。推导与上游语义一致：上游 `settings.py` 里
`FILE_SERVER_ROOT` 取的是 `host_url`（**不带** `SITE_ROOT`），而 `SERVICE_URL` 在
`SITE_ROOT` 场景下才带路径。所以从 **scheme+netloc** 推导，而不是从 `SERVICE_URL` 整串拼。

容器内部访问（`INNER_FILE_SERVER_ROOT = http://127.0.0.1:8082`）**不受影响**——那个本来就该是 IP:端口。

### 4.3 import 期绑定 —— 真正会咬人的坑

有两类写法，行为完全不同：

```python
seahub.settings.SERVICE_URL          # 运行时属性读取：改了立刻生效
from seahub.settings import SERVICE_URL   # import 期绑定：启动时固化，改了什么也不发生
```

后者是**静默失效**——代码看着对，改完没反应，还不报错。本次修掉三处：

| 文件 | 问题 |
|---|---|
| `base/context_processors.py` | `FILE_SERVER_ROOT` 是 import 期绑定。**前端上传下载用的正是它**，不改就是「后台改了、页面不认」 |
| `api2/endpoints/ocm.py` | `SERVICE_URL` import 期绑定（OCM 未启用，但留着就是雷） |
| `ocm_via_webdav/ocm_api.py` | 同上 |

### 4.4 后台 API 白名单

`api2/endpoints/admin/web_settings.py` 用**显式白名单**决定哪些键可读可写，
不在白名单里的键 PUT 会 400。`SERVICE_URL` 加进 `STRING_WEB_SETTINGS_ALLOW_EMPTY`
（允许清空 = 回落默认，等于给了个「恢复出厂值」的入口）。

### 4.5 前端

`frontend/src/pages/sys-admin/web-settings/web-settings.js` 里的字段是**硬编码列表**，
不是按 constance 注册表动态渲染的。所以新键必须手工加一个 `<InputItem>`——
这正是 002 当年也动过前端的原因。新增一个 `Site` 分节放在最前。

> 未加中文翻译：002 加的钉钉字段也没加，`zh_Hans` 里没有对应条目，中文界面下显示英文源串。
> 保持一致以免引入 msgfmt 重编译。要补的话是独立的一件事。

## 5. 改动文件清单

| 文件 | 改动 |
|---|---|
| `seahub/settings.py` | `CONSTANCE_CONFIG` 加 `SERVICE_URL` |
| `seahub/utils/__init__.py` | `get_service_url()` 走 constance；`get_fileserver_root()` 改推导 |
| `seahub/base/context_processors.py` | 去 import 期绑定，改用 `get_fileserver_root()` |
| `seahub/api2/endpoints/admin/web_settings.py` | `SERVICE_URL` 进白名单 |
| `seahub/api2/endpoints/ocm.py` | 去 import 期绑定 |
| `seahub/ocm_via_webdav/ocm_api.py` | 去 import 期绑定 |
| `frontend/.../web-settings.js` | 新增 `Site` 分节 + Site URL 字段 |

**不受影响**：`INNER_FILE_SERVER_ROOT`、`SITE_ROOT`、seafhttp 的容器内分流。
`FILE_SERVER_ROOT` 这个 settings 项仍存在（上游代码里仍会算它），只是 seahub 不再读它。

## 6. 验证记录（dev，2026-09-20）

| 项 | 实测 |
|---|---|
| 6 个 Python 文件语法 | ✅ `py_compile` 通过 |
| 默认值读取 | ✅ `config.SERVICE_URL='https://127.0.0.1'`；`get_fileserver_root()='https://127.0.0.1/seafhttp'`；分享链接 `https://127.0.0.1/f/a/` |
| **跨进程即时生效** | ✅ 进程 A 写入 → **全新进程 B** 立刻读到新值（这是「免重启」的实质：gunicorn 各 worker 是独立进程） |
| 后台 API GET | ✅ `GET /api/v2.1/admin/web-settings/` 返回 `SERVICE_URL` |
| 后台 API PUT | ✅ PUT `{"SERVICE_URL":"https://seafile.acme.cn"}` → 200 |
| **HTTP 端到端** | ✅ PUT 后请求 `/dingtalk/login/`，`Location` 里 `redirect_uri=https://seafile.acme.cn/dingtalk/callback/`——**走 gunicorn、没重启** |
| 清空回落 | ✅ 设为 `''` → `get_service_url()` 回落到 `https://127.0.0.1` |
| 删除行回出厂 | ✅ 删 constance 行 + 清缓存 → 回到 settings 默认 |
| 前端构建 | ✅ `npm run build` + `docker cp` + `collectstatic`（210 个文件） |
| **前端字段真的渲染** | ✅ 字段进了**实际被服务的那份**产物：`media/assets/frontend/static/js/sysAdmin.<hash>.js` 含 `SERVICE_URL`；`/sys/web-settings/` 200 且引用的正是该 bundle |

> **跨进程那条是本次最关键的验证。** constance 的 `DatabaseBackend.set()` 在写库的同时更新了
> 共享的 FileBasedCache，所以其它进程立刻可见，不需要等 TTL（`CACHES['default']` 没设 TIMEOUT，
> 默认 300 秒——若只写库不清缓存，改域名最多会有 5 分钟延迟且难以解释）。
>
> 前端那条也是必须验的：`collectstatic` 之前，新产物只躺在 `frontend/build/` 里，
> **页面加载的还是旧 bundle**（`.js` 文件名带内容哈希，旧 HTML 仍指向旧文件）。
> 只看「build 目录里有 SERVICE_URL」会漏掉这类「构建成功但没生效」的故障。

## 7. 使用方式

「系统管理 → 设置 → Site」→ `Site URL` 填 `https://你的域名`（结尾斜杠可省）→ 保存。**不用重启。**

改完要手工同步的**只有一处**：钉钉开发者后台的回调域名。因为那是钉钉侧的配置，
Seafile 只能生成地址、改不了对方后台。

> 顺带：钉钉回调地址是 `get_site_scheme_and_netloc()` 现算的（源头就是 `SERVICE_URL`），
> 所以改完 `SERVICE_URL` 下次登录时它就是新的——**不需要改代码，也不需要重启**。

## 8. 踩坑与注意

1. **`del config.X` 在 constance 里不支持**，会抛 `AttributeError: 'Config' object has no attribute 'X'`
   ——那正是 Python 默认 `object.__delattr__` 的报错，别被它误导成「键没注册」。
   要回到出厂值，用 ORM 删行 + `cache.clear()`：
   ```python
   from constance.backends.database.models import Constance
   Constance.objects.filter(key='SERVICE_URL').delete()
   ```
   注意模型路径是 `constance.backends.database.models`，**不是** `constance.models`（后者不存在）。
2. **`from seahub.settings import SERVICE_URL` 是静默失效**，见 §4.3。加新的「后台可配」项时，
   务必全仓 grep 一遍该键，确认没有 import 期绑定。
3. **前端字段是硬编码的**，只加后端 constance 键，后台界面不会出现这个字段。
4. 首次上线时 `.env` 里的 `SEAFILE_SERVER_HOSTNAME`（占位域名）**仍然要填**——它是 constance 的
   **默认值来源**，不是「写死」。填占位值不影响首启，装完在后台改掉即可。
5. 改 `SERVICE_URL` 之后，**已经发出去的分享链接不会变**（它们已经是绝对地址存在数据库/邮件里了），
   只有新生成的那批指向新域名。

## 9. 遗留

- 上游 `FILE_SERVER_ROOT` 这个 settings 项现在成了死配置（seahub 不再读）。上游升级时若该处逻辑变化，
  本补丁的推导需要重新核对。
- 中文翻译未补（见 §4.5）。

## 10. 13.0 实测复核（2026-09-24，升级 13.0.28 时）

13.0 上游把 `SERVICE_URL` 改成运行期即时计算（`settings.py` 在加载 seahub_settings.py
**之后**，只要 `SEAFILE_SERVER_PROTOCOL` + `SEAFILE_SERVER_HOSTNAME` 都在就无条件重算，
写进配置文件的同名值成为死配置）——曾担心与本补丁的 constance 化对撞。dev 容器
（13.0.28，env 已设）manage.py shell 实测：

| 场景 | get_service_url() | get_fileserver_root() |
|---|---|---|
| 初始（DB 无记录） | `https://127.0.0.1`（= env 计算的默认值） | `https://127.0.0.1/seafhttp` |
| 后台改 SITE_URL 后 | 改后值**立即生效**（constance DB 优先） | 跟随 |
| 后台清空 | 回落 env 默认值 | 跟随 |

结论：**模型不撞，补丁保留**。env 只决定 constance 的【默认值】；后台一旦保存，
DB 值赢。上游那条「加载后重算」反而让默认值永远正确——`seahub_settings.py` 里的
`SERVICE_URL`/`FILE_SERVER_ROOT` 在 13.0 是死配置，conf-templates 里已删。
