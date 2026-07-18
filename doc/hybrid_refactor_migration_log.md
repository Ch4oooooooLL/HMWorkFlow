# 混合架构迁移日志

## 阶段 0：分析

- 完整梳理四个顶层 Tcl 模块、入口、配置、HyperMesh 读写、纯算法和风险。
- 产出 `python_tcl_refactor_analysis.md` 与 `python_tcl_bridge_protocol.md`。
- 保持主界面注册、快捷键入口和配置文件位置不变。

## 阶段 1：公共桥接层

- 新增 `modules/hybrid_core/python`：schema、mesh model、几何、拓扑、边图、空间索引、
  统计、结果写入和日志。
- 新增 `modules/hybrid_core/tcl`：内置 Python 优先解析、唯一任务目录、UTF-8 JSON、
  进程执行、stdout/stderr 分离、operation log、sidecar 与 run_id 校验。
- HyperMesh 2019.0.0.70 已完成不修改模型的运行时自检。

## 阶段 2：auto_hole_rbe2

- Python 迁移：实体外表面提取、面法向/邻接、法向分段、边界闭环、孔段几何过滤、
  dependent-node 重复检查、候选完整性校验。
- Tcl 保留：UI、HM 数据读取、中心节点/RBE2 创建、Component 整理和浏览器刷新。
- 顶层 `run/runAction/runSettings` 保持，原识别流程改名为 `runCoreLegacy`。
- 修复：Python 回写验证原先误用逗号键，而旧业务 `nodeSetKey` 使用下划线；已统一调用
  旧函数，避免成功创建后被误报 dependent-node 校验失败。

## 阶段 3：shell_washer_hole_rbe2

- Python 迁移：壳边拓扑、自由边路径、环几何、圆/椭圆过滤、Washer 层扩展、外圈检查、
  dependent-node 重复索引和重复组删除计划。
- Tcl 保留：重建/清理动作、输出 Component、中心节点/RBE2 创建和刷新。
- 原 `processComponent` 保留为 `processComponentLegacy`，兼容包装按后端分派。
- 修复：原日志直接写 `stdout`，HM hmbatch 无该通道时会中断单候选创建；改为容错输出。

## 阶段 4：rbe2_bolt_connector

- Python 迁移：RBE2 几何记录、平面性/法向轴、孔径估算、三轴并查集语义分组、相邻配对、
  代表直径、现有一维连接去重和未使用壳 RBE2 列表。
- Tcl 保留：选择、Material、Beam Section、Property、Component、CBEAM 创建和创建后验证。
- 原 `runCreateFromSelection` 保留为 `runCreateFromSelectionLegacy`。
- Python executor 对每个计划重新检查中心节点、重合节点和已有连接；单条失败记录后继续。

## 阶段 5：mesh_seam_weld

- Python 阶段 A：源壳拓扑、连续路径/闭合自由边验证、路径长度和预期密度。
- Tcl 中间阶段：继续调用现有 `imprint_nodelist` 并读取实际新节点 ID。
- Python 阶段 B：最近节点一一匹配、开放路径反向、闭合路径旋转/反向最小代价、QUAD 计划、
  重复节点和近零面积拒绝。
- Tcl 最终阶段：继续使用现有 ruled surface、automesh、Component 命名和实体移动。
- 原 `processWeldPath` 保留为 `processWeldPathLegacy`。

## 后端切换

```tcl
set ::AutoHoleRBE2::cfg(recognitionBackend) python
set ::RB2W::recognitionBackend python
set ::RB2Bolt::recognitionBackend python
set ::MeshSeamWeld::recognitionBackend python
```

值可为 `python`、`legacy_tcl`、`compare`。开发对比选项未加入正式 UI。

## 测试与日志

```powershell
runtime\python\windows-x64\python.exe modules\hybrid_core\tests\run_tests.py
runtime\python\windows-x64\python.exe modules\auto_hole_rbe2\tests\run_tests.py
runtime\python\windows-x64\python.exe modules\shell_washer_hole_rbe2\tests\run_tests.py
runtime\python\windows-x64\python.exe modules\rbe2_bolt_connector\tests\run_tests.py
runtime\python\windows-x64\python.exe modules\mesh_seam_weld\tests\run_tests.py
```

HM2019 批处理验证脚本：

```text
modules/hybrid_core/tests/hm_source_modules.tcl
modules/hybrid_core/tests/hm_hybrid_export_smoke.tcl
modules/hybrid_core/tcl/runtime_self_test.tcl
```

每次正式运行日志位于 `runtime/tasks/<module>/<run_id>/`。

## 阶段 6 状态

旧 Tcl 算法未删除。按照任务约束，需要更多生产模型 compare 样本确认复杂几何一致性后，
才允许执行清理；当前保留旧路径是有意的兼容措施，不是遗留死代码。

## 运行链路修复：卡死、进度和 Python 冷启动

- `hybrid_core/python/persistent_worker.py`：新增单进程、逐任务清理模块状态的 stdio worker。
- `hybrid_core/tcl/process_runner.tcl`：从同步 `exec` 改为 `fileevent + vwait` 管道等待；
  同一 HyperMesh 会话复用 worker，崩溃时清理并支持 one-shot 回退。
- `hybrid_core/tcl/progress_bridge.tcl`：统一 150 ms UI 节流、阶段范围和长分析活动提示。
- Python runtime 解析结果缓存，避免每次运行重复执行版本探测。
- Auto Hole、Shell Washer、RBE2 Bolt、Mesh Seam 均增加导出/分析/创建阶段进度映射。
- Shell Washer 的 Component 总进度按每个 Component 的实际区间计算，候选创建按实际数量推进。
- Mesh Seam 开放路径现在也显示进度窗口；阶段 A、Imprint、阶段 B、ruled mesh 分段显示。
- 常驻模式默认开启；可用 `set ::HybridCore::persistentWorkerEnabled 0` 临时关闭，或调用
  `::HybridCore::stopPersistentWorker` 主动重启 worker。
- 修复公共 `mesh_model.read_mesh` 的 O(elements × nodes) 校验缺陷：全节点集合改为一次构建；
  真实 74,400 elements / 86,401 nodes 数据的读取从 71.108 秒降到 0.338 秒。
- `MeshModel.elements_for_components` 增加惰性 Component 索引；Auto Hole 与 Shell Washer
  的候选节点验证也改为复用预建集合。

## Shell Washer 流程简化

- 删除 `PERFORMANCE_MODE` 变量、配置持久化键、设置面板选项、参数校验和所有
  begin/end/resume performance mode 分支。
- 删除原先对 redraw、message、browser buffer 的全局开关，避免异常路径残留阻塞状态。
- 输出 Component 不再调用 `HWFlow::createComponent` 的 Model Browser 创建路径；改用
  现有 HyperMesh `*createentity` / `*collectorcreateonly` 命令静默创建。
- Component 创建期间不刷新、不激活 Browser；所有输出完成后统一显示并刷新一次。
- 合并重复节点动作也只在操作完成后刷新一次。
