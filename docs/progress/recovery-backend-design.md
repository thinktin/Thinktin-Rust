# recovery/backend-design

本分支从 PR #18 的后端交接继续，补齐五个 agent 的联网需求、浏览器执行与接管协议、跨用户项目的产品评审和分期验收。三个设计分别见[出口代理](../egress.md)、[浏览器](../browser.md#实现设计与验收)、[跨用户项目](../projects-impl.md)。

代理客户端探针使用本机回环代理，逐个检查 curl、Git HTTPS、Python urllib 和 Node fetch 是否将指定目标交给代理。探针只验证客户端代理选择；东京 ACS 的网络隔离、五份镜像的实际行为和资源开销仍须按出口代理及浏览器文档实测。
