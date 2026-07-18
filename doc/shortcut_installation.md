# 快捷键安装与启动验证

## 安装或更新

1. 在 HyperMesh 2019 中运行项目根目录的 `install_update.tcl`。
2. 打开 HMWorkFlow 的“快捷键管理”，设置主面板或模块快捷键。
3. 工具会在当前用户的 `hmcustom.tcl` 中维护 HMWorkFlow 专用标记块，不覆盖其他用户脚本。
4. 重新启动 HyperMesh，检查管理器中的“本次启动已验证”状态。

快捷键配置写入 `%APPDATA%/HMWorkFlow/shortcuts.cfg`；运行状态和启动心跳写入 `%LOCALAPPDATA%/HMWorkFlow/`。安装目录只保存代码和默认配置。

## 修复

项目移动后，如果管理器显示路径失效，使用“修复自动加载”重新写入当前 `shortcut_bootstrap.tcl` 路径。若启动心跳未更新，先确认当前 HyperMesh 实际加载的用户配置目录，再检查启动日志中的快捷键注册结果。

## 卸载

使用“禁用自动加载”删除 HMWorkFlow 标记块。此操作不会删除 `hmcustom.tcl` 中的其他内容，也不会修改模型。
