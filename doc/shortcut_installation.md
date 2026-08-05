# 快捷键安装与启动验证

## 安装或更新

1. 在 HyperMesh 2019 或 HyperMesh 2022 中运行项目根目录的 `install_update.tcl`。安装或更新一次即可。
2. 打开 HMWorkFlow 的“快捷键管理”，设置主面板或模块快捷键。
3. 工具会在当前用户的 `hmcustom.tcl` 中维护 HMWorkFlow 专用标记块，不覆盖其他用户脚本。
4. 重新启动 HyperMesh，检查管理器中的“本次启动已验证”状态。

快捷键配置写入 `%APPDATA%/HMWorkFlow/shortcuts.cfg`；运行状态和启动心跳写入 `%LOCALAPPDATA%/HMWorkFlow/`。安装目录只保存代码和默认配置。

HyperMesh 2019 启动时会立即恢复快捷键。HyperMesh 2022 会先读取 `hmcustom.tcl`、后建立建模上下文，因此启动加载器会在后台等待原生快捷键接口就绪，并在上下文重建按键表后自动恢复绑定；无需每次重新运行 `install_update.tcl`。

更新脚本会先终止当前会话仍在运行的 HMWorkFlow BatchMesher 子进程和持久 Python worker，取消旧版本注册的后台回调，删除旧模块命名空间，再从本次 `install_update.tcl` 所在目录完整重载。成功对话框必须显示当前版本、项目根目录和安装报告路径；报告默认写入 `%LOCALAPPDATA%/HMWorkFlow/runtime/instances/hm-<PID>/install_update.log`。如果安装报告没有生成或根目录不是本次更新目录，不要继续运行网格任务。

BatchMesher 窗口标题应显示 `v2.6` 或更高版本。外部 hmbatch 子进程带有专用启动标记，不会再加载交互式快捷键或启动无关的持久 Python worker；启动命令同时禁止 command 文件和 user-profile 对话框，并在正式拆分任务前执行真实 Tcl/API 门禁。

## 修复

项目移动后，如果管理器显示路径失效，使用“修复自动加载”重新写入当前 `shortcut_bootstrap.tcl` 路径。若启动心跳未更新，先确认当前 HyperMesh 实际加载的用户配置目录，再检查启动日志中的快捷键注册结果。

## 卸载

使用“禁用自动加载”删除 HMWorkFlow 标记块。此操作不会删除 `hmcustom.tcl` 中的其他内容，也不会修改模型。
