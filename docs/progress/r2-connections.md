# r2/connections

目标：iOS 改版第 2 轮的“连接”一组（规范 docs/ios-ui-redesign.md 4.8、6.12；参考 36–52、101–107）：连接目录（分类胶囊，
一个按数据生成的分类页）、已连接列表、推荐 / 精选完整列表、应用详情 sheet。版式照参考 1:1 排，ThinkTin 还没有的应用用本地演示数据、
操作弹“即将推出”；已经有的接入（电脑、IM 渠道、模型 key、保险箱）用真数据，打开各自的现有页面。不改 `ClientProtocol` / Mock / CoreClient。

已完成：
- （还没有）

进行中：
- 2026-11-05 Claude（会话 session_01GuCp3KRgqaK6Kzynw6udRn，工作流 r2/connections）开工：路由、视图模型和演示数据、页面。

下一步：
- 路由 `.connections(category:)`、`.connectedApps`、`.connectionList(_:)`、`.connection(_:)` + 新功能 `AppFeature.connections`；
  `ViewModels/Connections/`（`ConnectionsModel`、`ConnectionsDemoData`）+ 测试。
- `Screens/Connections/`：目录、已连接、完整列表、详情 sheet；设置里的“连接”一行。

坑和决定：
- （待补）
