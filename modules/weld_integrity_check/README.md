# 网格焊缝完整性检查

面向 HyperMesh 2019 的网格后 Shell–Shell 焊缝候选审查模块。它只缩小人工检查范围，不判断某处必须焊接，也不创建或修改焊缝、网格与 Component。

## 数据流

1. Tcl 使用 HyperMesh 原生 Component mark panel 获取检查范围并排除指定组件。
2. Tcl 将壳单元、节点、组件和设置写入 `runtime/tasks/weld_integrity_check/<run_id>/input/`。
3. Python 从壳单元拓扑推导自由边，执行 AABB 粗筛、空间哈希近邻搜索、连续边区域提取、Component Pair 去重与指标汇总。
4. Python 写出 `output/result.json` 与安全 Tcl sidecar；Tcl 一次加载结果并打开交互审查窗口。
5. 审查状态独立写入 `state/review_state.json`，不会重写大体积输入。

输入文件为 `components.json`、`nodes.csv`、`elements.csv`、`free_edges.csv` 和 `settings.json`。HM2019 自由边命令在不同安装中存在差异，因此首版的 `free_edges.csv` 只保留稳定接口表头，实际自由边由 Python 按“壳边只被一个单元拥有”推导。

## 使用

在主面板选择“网格焊缝完整性检查”，选择至少两个 Component，设置模型单位下的最大搜索距离、最小有效接近长度和最小连续节点数，然后开始检测。报告窗口中可按名称或 ID 筛选 Pair，并执行孤立、高亮、区域切换、完成/重新打开和恢复进入模块前显示。关闭报告会自动清除 mark/编号并恢复原显示状态；再次进入模块可选择“继续上次审查”。

## 算法边界

当前仅实现 Shell–Shell。精确搜索采用自由边节点到另一 Component 节点的空间哈希近邻近似，不做点到曲面的 CAD 级投影；粗网格、错位网格或目标面内部无邻近节点时可能漏报。结果始终需要人工确认。`::WeldIntegrityCheck::OpenWeldCreator pairData` 是未来接入焊缝创建模块的保留接口。

## 测试

使用工具箱随附的 Python 3.8：

```powershell
runtime\python\windows-x64\python.exe -m unittest discover -s modules\weld_integrity_check\tests -v
```

普通 Tcl 可完成语法加载验证；组件选择、显示恢复与 HyperMesh mark 高亮必须在 HyperMesh 2019 中使用实际模型验证。
