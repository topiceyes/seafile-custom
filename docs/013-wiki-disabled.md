# 013 - 知识库（wiki）模块关闭：不部署 SeaDoc

> 决策日期：2026-10-08 ｜ 状态：**已落地**（1.1.1）

## 背景

13.0 的知识库（wiki）页面是 **sdoc 格式文档**，前端编辑器是 SeaDoc
（`pages/wiki2/main-panel.js` 用 `SdocWikiEditor`），它依赖一个**独立的协作服务容器**
（`seafileltd/sdoc-server`），并且 seahub 的所有 `/api/v2.1/seadoc/*` 接口只在
`ENABLE_SEADOC=true` 时才注册（`urls.py:1088`）。

本部署从未带过 SeaDoc（12.0 时代同样没有——官方 13.0 Docker 单机部署默认带它，
我们的 compose 是 12.0  lineage 演进来的）。所以知识库从首装起就是坏的：
用户点「新建页面」→ 前端调 `/api/v2.1/seadoc/participants|notifications` → 404 →
弹 AxiosError（2026-10-08 用户实撞）。**这不是 13.0 升级引入的回归**，是功能从未启用。

## 决策

用户明确不打算用知识库 → **关掉模块**，而不是部署 SeaDoc 整套（新容器 + nginx 两段
location + WebSocket 透传链路面）。

## 实现

`custom_bootstrap.MANAGED_SETTINGS` 增加一项：

```python
ENABLE_WIKI = False
```

生效链路（全部源码核实）：

- `accounts.py:422` `can_create_wiki()`：`not settings.ENABLE_WIKI` → False
- `base_for_react.html:116` `canCreateWiki` → 前端侧边栏「知识库」入口不渲染
  （`main-side-nav.js:299`）
- 创建 API 双层兜底：`api2/endpoints/wiki2.py:212`、`wikis.py:102` 都查
  `can_create_wiki()`，直接访问 API 也会被 403

逐项核对机制保证老部署升级自动补上这一行（生产数据卷已确认无 `ENABLE_WIKI` 残留行，
不会落在「已有 True 值」盲区）。冒烟第 6 项（首启 + 升级路径两处）与彩排第 6 节
都有断言。

## 想重新启用时

1. 数据卷 `seahub_settings.py` 删掉 `ENABLE_WIKI = False` 行（或改 True）——
   注意镜像每次启动逐项核对，删行会被补回；要真正启用必须**先改镜像**
   （`custom_bootstrap.py` 里去掉该项）再删行
2. 部署 SeaDoc：官方配方 <https://manual.seafile.com/13.0/extension/setup_seadoc/>
   （`seadoc.yml` + `ENABLE_SEADOC=true` + `SEADOC_SERVER_URL` + nginx 的
   `/sdoc-server/` 与 `/socket.io` 两段，后者要 WebSocket Upgrade 透传——
   反代层是主要风险点）
3. `sdoc-server` 镜像需先走 `mirror-infra-images.yml` 镜像到 ghcr
