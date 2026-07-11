# 快捷键安装与更新

从本版本起，统一使用项目根目录的 `install_update.tcl`：

```text
File > Run > Tcl/Tk Script > install_update.tcl
```

原有的 `hw_toolkit.tcl` 仍可运行，但它现在会转入同一套安装/更新流程。

## 首次安装

1. 脚本加载工具库并更新用户 `hmcustom.tcl` 中仅属于 HMWorkFlow 的启动块。
2. 脚本提示设置“打开 HyperMesh Toolkit”的主面板快捷键，默认建议为 `Ctrl+Shift+W`。
3. 该键位通过 HyperMesh 2019 的 `::HM_Framework::hm_registerkeyproc` 写入原生 Key Commands 库；正常退出 HyperMesh 后，HyperMesh 会把原生键位表保存到用户的 `hmsettings.tcl`。
4. 打开主面板后，点击底部“快捷键管理”，再为各模块设置快捷键。

启动时，`hmcustom.tcl` 只会静默加载 `shortcut_bootstrap.tcl`，不弹出设置窗口；它会重新注册已保存的 HMWorkFlow 主面板和模块快捷键。

## 更新

每次工具库文件被替换、移动或更新后，再运行一次 `install_update.tcl`。它会：

- 刷新 `hmcustom.tcl` 中的 HMWorkFlow 启动块路径；
- 重新加载本地快捷键配置，并写回 HyperMesh 原生键位库；
- 已设置主面板快捷键时不再打断用户；
- 未设置主面板快捷键时才再次提示。

## 使用约束

- 避免使用 `Ctrl+S`、`Ctrl+O`、`Ctrl+Z`、`Ctrl+Y` 以及 F1–F10；它们是高风险的 HyperMesh 原生键位。
- 在“快捷键管理”中清除或更换绑定会同时清除该键的原生 Key Commands 映射；如需恢复 HyperMesh 默认功能，可在 HyperMesh 的 Key Commands 界面重新设置，或恢复默认键位。
- 本工具不改写 `hmcustom.tcl` 的其他用户内容，只维护带 `HMWorkFlow shortcut loader` 标记的区块。
- `shortcuts.cfg` 是 HMWorkFlow 的可读备份和管理器数据；HyperMesh 原生键位表仍由其自身的 `hmsettings.tcl` 持久化。
