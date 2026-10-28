# 015 - 客户端 SSO 设备不可见修复（产品 1.2.1）

> 完成日期：2026-10-28 ｜ 状态：1.2.1 已发布并灰度验证
> 起因：198 管理后台 `/sys/devices/desktop/` 看不到任何已链接客户端（同步功能正常）。

## 1. 结论先行

设备页为空不是 14.0 升级的回归，而是**客户端 SSO 链接流程的设备参数丢失**——
上游 `client_sso_complete` 在拿不到参数时兜底发 v1 token：同步可用，但 v1 不是
设备，永远不进 `api2_tokenv2`，管理后台不可见、无法解绑/远程擦除。

实测存在**两条独立的断链点**，踩中任何一条都会落到 v1：

| # | 断链点 | 性质 | 修复 |
|---|---|---|---|
| 1 | SeaDrive GUI ≤3.0.27 发 `/api2/client-sso-link/` 不带 `shib_*` 参数（源码实证，`ClientSSOLinkRequest` 裸 URL；seafile 同步客户端会带） | 上游客户端缺陷 | [0011] seahub 兜底补录 v2 |
| 2 | 登录页钉钉图标按钮 `{% url "dingtalk_sso" %}` 丢 `next`；而设备参数坐在 `next` 的 query 里（`views/sso.py` `client_sso()` 原样转发 query 进 next） | 上游模板缺陷 | [0012] 按钮补 `?next=` |

旁证：198 上两个已完成 SSO token 的 api_key 都在 `api2_token`（v1）不在 v2；
dev 栈参数存活时服务端正确 mint v2（服务器逻辑没坏）；dev 栈 9 月 17 日
（13.0.28 时代）同样落 v1——老问题，非本轮升级引入。

## 2. 修复内容（补丁 0011 / 0012 + 镜像层）

### 2.1 [0011] 无设备参数时按浏览器 UA 补录 TokenV2（views/sso.py）

`client_sso_complete` 的 v1 兜底替换为 `get_token_v2_fallback()`：

- 完成确认是**浏览器**发起的，UA 只有浏览器 UA（拿不到客户端版本），但 OS 信息
  足够定平台：`windows`/`mac`/`linux` 关键词映射，猜不出才退回上游 v1。
- `device_id = sha1(用户名|UA)`：40 位（桌面平台合法长度）、同用户同机稳定去重
  （unique_together(user, platform, device_id) 下重链接复用同一行；
  擦除后 `get_or_create_token` 删旧建新，客户端拿新 key）。
- device_name 标为「SSO 登录设备（浏览器 UA 识别）」，与真实设备行可区分。
- **远程擦除对补录设备同样有效**：擦除是 api2 认证时的 `wiped_at` DB 检查，
  不依赖真实 peer id。

### 2.2 [0012] 登录页钉钉按钮保留 next（login.html）

`<a href="{% url "dingtalk_sso" %}{% if next %}?next={{ next|urlencode }}{% endif %}">`，
写法对齐同文件 JS SSO 按钮（220/233 行）。`urlencode` 保证内层 query
（`complete/?shib_platform=…&shib_device_id=…`）不被拆散。
效果：参数链救活（参数齐全的客户端拿真实 device_id 的 v2）+ 首次扫码直接回
客户端确认页，不再落首页。

### 2.3 镜像层：dingtalk-sync cron 路径修复（无补丁号）

排查时顺带发现：`/etc/cron.d/dingtalk-sync` 的 cd 路径硬编码
`/opt/seafile/seafile-server-12.0.14/seahub`——**12→13 升级起该目录不存在，
离职员工同步每小时静默失败，从未运行**。改为 `seafile-server-latest` 符号链接
（随升级自动指向新版本），并加 `|| echo … FAILED` 留痕。smoke-test 新增断言
cron 路径必须走 latest 链接（防回归）。

### 2.4 已存在 v1 token 的存量设备

补丁只影响**新**链接流程。198 上已有的 v1 token（管理员 + 钉钉用户）不受影响的
继续可用；要进设备列表，在客户端上重新走一次登录（解绑账号重新链接）即可。

## 3. 实测记录

dev 栈（14.0.9 官方镜像 + bind-mount 补丁源码）全流程仿真：

| 场景 | 结果 |
|---|---|
| SeaDrive 模拟（POST 无参数）+ Mac Safari UA 走完登录+确认 | `api2_tokenv2` 新增 mac 行（device_id=`e321a693…` 40 位 sha1，device_name=「SSO 登录设备（浏览器 UA 识别）」）；status 接口返回的 apiToken 是 v2 key，`/api2/repos/` 认证 200 ✅ |
| 同流程但 UA 不可识别（curl/8.7.1） | 正确退回 v1：v2 表不增行，复用该用户既有 v1 ✅ |
| 登录页带 `?next=/client-sso/…complete/` | 钉钉按钮 href 含 `?next=`，内层 query 编码完整 ✅ |

198 灰度（1.2.1）：

| 项 | 结果 |
|---|---|
| 溯源 | 运行中 digest == digest(:latest) == digest(:1.2.1.d6dbd1d9) ✅ |
| cron 修复生效 | 容器内 `/etc/cron.d/dingtalk-sync` 走 seafile-server-latest；手动执行 deactivate_departed_users 命令成功 ✅ |
| 存量 v1 用户重新链接 | 重新走客户端登录后设备出现在管理后台（浏览器 UA 识别的平台正确）✅ |
| 回归：登录/上传下载/WebDAV/钉钉扫码 | 全绿（docs/014 §6.1 探针原样重放）✅ |

## 4. 上游遗留（不修，观察）

- SeaDrive GUI 不发参数的客户端缺陷属上游（haiwen/seadrive-gui），0011 兜底后
  影响只剩「设备名是浏览器 UA 识别、无客户端版本号」。上游修复后真实参数进来，
  unique_together 下自然并存新行，无需清旧行。
- 上游模板里企业微信/微信图标按钮同样丢 next（login.html 112/118 行）——我们不
  启用这两个登录方式，未修；上游若修了注意 rebase 时别冲突。

## 5. 踩坑回写

1. **「同步正常」≠「设备正常」**：v1 token 全功能可用，唯一观察口是管理后台设备
   列表。排查这类「功能活着但看不见」的问题，直接查 `api2_tokenv2` 表计数最快。
2. **cron 硬编码版本目录是定时炸弹**：升级换目录后 cron 静默失效没有任何日志，
   本次靠排查别的问题顺带发现。凡引用版本目录的代码，一律走 `seafile-server-latest`
   符号链接 + 失败留痕 + 冒烟断言，三层兜底。
3. **参数坐在 next 的 query 里**：评估「登录页按钮丢 next」这类小 bug 的影响面时，
   要追到 next 的内容本身——这里它承载了整个设备参数链，不是单纯的跳转问题。
4. **14.0 用户表在 ccnet_db.EmailUser**，不在 seahub_db.auth_user（后者存在但空），
   排查时 `SELECT … FROM auth_user` 查不到人会误判成空库。
