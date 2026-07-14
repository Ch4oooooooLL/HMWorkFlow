# hwtk 界面架构

## 目标

项目以 HyperWorks 2019 内置的 `hwtk 1.0` 作为首选 GUI 后端，同时保留 Tk/ttk 回退。业务模块继续调用同一套 Tcl 执行入口，GUI 迁移不建立第二套业务逻辑。

## 第一阶段范围

- `::HWFlow::initUI` 探测并缓存 hwtk/Tk 后端。
- `::HWFlow::createTopLevel` 统一创建和登记主窗口、模块窗口及进度窗口。
- `::HWFlow::uiWidget` 为公共界面和主界面创建 hwtk 控件，并在控件不可用时回退。
- 主工具箱使用 hwtk frame、label、button 和 notebook。
- 公共进度窗口使用 hwtk progressbar、label、button 和 scrollbar。
- 模块内部的参数表单暂时保留原有 Tk 控件，顶层窗口已经进入统一生命周期。

## 窗口生命周期

所有模块继续通过以下入口创建窗口：

```tcl
::HWFlow::createTopLevel $w
```

公共层会优先调用 `hwtk::toplevel`，失败时回退到 `toplevel`，并把窗口登记到工具箱窗口注册表。窗口销毁时登记自动移除。

不再设置或重复恢复 `wm attributes -topmost 1`。打开 `*createmarkpanel` 时，`::HWFlow::nativeMarkPanel` 只临时隐藏登记过的工具箱窗口，选择完成或发生异常后恢复原映射状态。

快捷键通过 `::HWToolkit::requestShortcutLaunch` 切换窗口。该入口先保存状态并销毁全部登记窗口，再使用 `after idle` 等待旧模块的 `tkwait window` 和 `MODULE_BUSY` 状态退出，最后创建目标模块或主面板。连续按下不同快捷键时以最后一次请求为准。活动进度任务由 `::HWFlow::progressIsActive` 保护，不允许快捷键强制销毁。

## 后续模块迁移约定

模块参数页面逐步迁移时，应优先通过 `::HWFlow::uiWidget` 创建公共类型控件：

```tcl
::HWFlow::uiWidget frame $w.main
::HWFlow::uiWidget label $w.main.title -text "Title"
::HWFlow::uiWidget button $w.main.run -text "Run" -command ::Module::run
```

复杂控件可以在确认 HyperMesh 2019 实机行为后直接采用 `hwtk::table`、`hwtk::propertysheet`、`hwtk::openfileentry` 等控件，再按需要补充到适配层。模块不得复制后端探测、窗口登记或原生选择面板管理逻辑。

## HM2019 验证点

1. 主面板的 Geometry、Mesh、Connector 页面可以切换。
2. 每个可见模块能够打开并返回主页。
3. component、element、node、surface 等原生选择面板不会被工具箱窗口遮挡。
4. 选择结束和按 Esc 取消后，原模块窗口恢复。
5. 公共进度条显示数值、日志和取消状态。
6. 多显示器环境下窗口不会因永久置顶抢占焦点。
