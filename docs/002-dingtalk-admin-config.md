# 002 - 钉钉 Auth 配置管理化（管理员后台可配置）

> 完成日期：2026-09-16 ｜ 分支：`seahub/dev-dingtalk` ｜ 状态：已上线验证
> 前置：[001 - 钉钉扫码登录](001-dingtalk-login.md)

## 1. 需求

上一功能把钉钉配置写死在 `seahub_settings.py`，改一次要编辑文件 + 重启。本功能把 `ENABLE_DINGTALK / DINGTALK_APP_KEY / DINGTALK_APP_SECRET` 挪到**系统管理后台 → 设置页**，网页修改、**免重启生效**。

## 2. 方案：复用 seahub 的 constance 机制

seahub 自带动态配置基础设施，全部复用、零新模型/零新 API：

- **django-constance 2.4.0**（vendored 在 `thirdpart/constance/`）：DB 表 `seahub_db.constance_config` + FileBasedCache（多 worker 共享），写入即生效
- **后台设置页** `/sys/web-settings/`：React 页 + `AdminWebSettings` API（`GET/PUT /api/v2.1/admin/web-settings/`，IsAdminUser + can_config_system 权限），本来就是读写 constance

兼容设计：**constance 默认值取自 seahub_settings.py 文件值**（文件=默认、后台=覆盖），无需数据迁移，DB 无记录时行为与改造前一致。

## 3. 核心改造：常量 → 访问函数

原 `seahub/dingtalk/settings.py` 的模块级常量被 10 个文件模块级 import（进程启动即固化）。改为仿 `seahub/utils/two_factor_auth.py` 的访问函数范式：

```python
# seahub/dingtalk/settings.py
from constance import config

def is_dingtalk_enabled():
    return bool(config.ENABLE_DINGTALK)

def get_dingtalk_app_key():
    return config.DINGTALK_APP_KEY

def get_dingtalk_app_secret():
    return config.DINGTALK_APP_SECRET
```

### 改动文件清单（16 个文件，commit `see git log`）

| 类别 | 文件 | 改动 |
|---|---|---|
| 配置定义 | `seahub/settings.py` | CONSTANCE_CONFIG 加 3 项；加 DINGTALK_APP_KEY/SECRET 默认值；`AUTHENTICATION_BACKENDS` 改无条件注册 OauthRemoteUserBackend（启动期读不到 constance；backend 常驻无害，运行期由视图层开关拦截） |
| 动态读 | `seahub/dingtalk/settings.py` | 常量 → 3 个访问函数，URL 类常量保持静态 |
| 引用点 | `dingtalk/views.py`（14 处）、`dingtalk/utils.py`、`oauth/backends.py`、`base/context_processors.py`、`views/sso.py`、`views/sysadmin.py`、`profile/views.py`、2 个通知命令、1 个部门修复命令 | 模块级 import → 函数调用 |
| **硬点** | `api2/endpoints/admin/dingtalk.py`、`notifications/.../send_dingtalk_notifications.py` | 原有**模块级** `if DINGTALK_APP_KEY: from ... import A else: import B` 条件 import，改为包装函数内**运行时**分支（不改会 ImportError，seahub 起不来） |
| oauth 后端 | `oauth/backends.py` | 类体的 `if ENABLE_DINGTALK:` 固化配置，移到 `authenticate()` 内运行时判断（局部变量，避免跨请求污染） |
| API 白名单 | `api2/endpoints/admin/web_settings.py` | ENABLE_DINGTALK 入 DIGIT；两个 key 入 STRING 且加入「允许空值」豁免（原来非空校验会拒绝清空密钥） |
| 前端 | `frontend/src/pages/sys-admin/web-settings/web-settings.js` | 新增「DingTalk Login」Section：开关 CheckboxItem + AppKey InputItem + AppSecret InputItem（inputType=password） |

## 4. 前端构建部署（关键流程）

前端是 CRA5 fork（react 17 + webpack 5），**容器内没有 node**，构建在宿主机、部署进容器：

```bash
cd deploy && ./rebuild-frontend.sh
# 内部：npm run build → docker cp build/ + webpack-stats.pro.json → 容器内 collectstatic
```

- 静态文件在**镜像层**（`media/assets/frontend/static/`，不在 /shared 卷），**容器重建会丢** → 用脚本固化，重建后重跑
- ⚠️ **docker cp 嵌套坑**（已修复）：`docker cp build 容器:.../frontend/build` 在目标已存在时会把源嵌套成 `build/build/`，collectstatic 收集到旧产物而 webpack-stats 是新的 → 页面引用 404 → React 白屏。脚本里先 `rm -rf` 旧 build 再复制
- 产物里 `webpack publicPath` 是 `http://0.0.0.0:3000/assets/bundles/`——**与官方 Docker 镜像产物完全一致**（官方也这样），seahub 页面实践中不触发动态 chunk 加载，无影响；若未来某页面 404 再修（设 PUBLIC_PATH 或改 paths.js 拼接）
- 前端改动后只需跑脚本 + 浏览器强刷，**不需要重启 seahub**

## 5. 验证结果（全绿）

| 验证项 | 结果 |
|---|---|
| 冒烟 `import seahub.wsgi` | ✅ 无 ImportError |
| 文件默认值兼容（DB 无 constance 记录） | ✅ AppKey 从 seahub_settings.py 默认值读出 |
| **免重启开关**：constance 关 ENABLE_DINGTALK | ✅ 登录页钉钉图标立即消失；开启立即恢复（不重启） |
| GET web-settings API | ✅ 响应含 3 个钉钉配置项 |
| PUT 改 AppKey 为错误值 | ✅ 跳转钉钉的 client_id 立即变为新值（免重启即时生效） |
| PUT 空值 | ✅ 200（豁免生效，可清空） |
| 恢复正确值 | ✅ client_id 恢复 |
| 新 sysAdmin bundle 上线 | ✅ 新 hash 产物 200，含 DINGTALK_APP_KEY 代码 |

## 6. 使用方式

管理员登录 → 左侧「设置」（`/sys/web-settings/`）→ **DingTalk Login** 分区：
- ☑ Enable DingTalk login（勾选/取消即时生效）
- DingTalk AppKey / DingTalk AppSecret（AppSecret 以密码框显示，点对号保存）

页面顶部提示同样适用：「数据库中的设置优先于配置文件」——后台保存过即覆盖 seahub_settings.py。

## 7. 踩坑与注意

| # | 事项 |
|---|---|
| 1 | 容器内 `seahub.sh python-env python3` 单独跑 constance 操作必须先 `import seahub.wsgi`（否则 DJANGO_SETTINGS_MODULE 未配置直接 ImportError） |
| 2 | `dingtalk_get_orgapp_token` 有 Django cache（约 2h）——后台换 AppKey 后旧企业 token 最长残留 2 小时，仅影响企业 API 取邮箱，不影响登录主流程 |
| 3 | 后台改配置**免重启**；但 Python 源码改动仍需 `seahub.sh restart`；前端改动跑 rebuild-frontend.sh |
| 4 | AppSecret 在 GET 响应里是明文返回给管理员（与 SITE_NAME 等同通道，官方设计如此）；界面 input 用 password 类型只是视觉遮挡 |
| 5 | 引用点若未来新增代码，注意不要再用 `from seahub.dingtalk.settings import ENABLE_DINGTALK`（已不存在），用 `is_dingtalk_enabled()` |

## 8. 遗留

- i18n：钉钉卡片文案目前英文直出（gettext 包裹未配词条），需要中文可加 `locale/zh_CN/LC_MESSAGES/djangojs.po` 词条后编译
- 动态 chunk publicPath 隐患（见第 4 节，与官方一致，暂不处理）
