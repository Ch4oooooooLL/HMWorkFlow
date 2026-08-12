# BatchMesher 自动网格划分（HyperMesh 2019 / 2022）

## 入口与职责

主页 `网格` 分组中的 `BatchMesher 自动网格划分` 调用 `::BatchMesher::runAction`。旧的 `batch_mesh_washer.tcl`、component 分批、自动参数生成和二次 washer 规则已删除。

实现文件：

| 文件 | 职责 |
| --- | --- |
| `modules/batch_mesher.tcl` | 模块装载入口。 |
| `modules/batch_mesher/config.tcl` | hmbatch 路径、criteria/param 多预设和执行选项持久化。 |
| `modules/batch_mesher/selection.tcl` | Surface ID 选择、mark 重建、实体有效性及 component 展示信息。 |
| `modules/batch_mesher/connectivity.tcl` | HM2019/2022 `by attached` 连通域、诊断、排除和任务构建。 |
| `modules/batch_mesher/executor.tcl` | 2019/2022 命令封装、版本规范化、失败重试和备份。 |
| `modules/batch_mesher/background.tcl` | 按连通域并行启动 hmbatch、状态轮询、进程树终止、完整结果汇总，以及带差集验证和整批回滚的一次性自动导入。 |
| `modules/batch_mesher/background_worker.tcl` | 单连通域工作脚本；以新增 Element 为结果判据、记录质量/迭代警告、任务 FEM 导出，以及原生 HM 结果保存。 |
| `modules/batch_mesher/background_merge_worker.tcl` | 在空白 2019/2022 hmbatch 模型中逐个导入 worker FEM，自动偏移冲突 ID，保存一个干净的合并 HM 并导出最终 FEM。 |
| `modules/batch_mesher/logging.tcl` | 共享任务工作区、run/task 日志和 JSON 报告。 |
| `modules/batch_mesher/ui.tcl` | 与工具箱一致的 Tcl/Tk 管理窗口。 |

## 配置

配置沿用 `::HWFlow::saveState`，写入 `%APPDATA%/HMWorkFlow/batch_mesher_state.txt`（无 APPDATA 时回退项目 `config/`）。结构为 Tcl 安全列表键值：

```text
HMBATCH_PATH {.../hmbatch.exe}
ACTIVE_PRESET Durability_8mm
DEFAULT_PRESET Durability_8mm
CRITERIA_PATH {.../durability_8mm.criteria}
PARAM_PATH {.../durability_8mm.param}
PRESETS {{name Durability_8mm criteria_path {...} param_path {...} criteria_mtime 0 param_mtime 0}}
CONTINUE_AFTER_FAILURE 1
AUTO_BACKUP 1
LARGE_GROUP_RATIO 0.8
PARALLEL_WORKERS 2
SHOW_CMD_WINDOW 1
```

`PARALLEL_WORKERS` 控制同时运行的独立 hmbatch 数量，范围 1–16。根据 2022 实机许可证并发验证默认设为 2；若出现 license denial，可降为 1。调度器采用固定容量滑动窗口：任一 worker 进入终态后立即释放槽位并拉取下一个 pending 任务，不等待同批其他任务结束；只要剩余任务数足够，活动 worker 数会保持为设置值。旧的 `FUTURE_PARALLEL_WORKERS` 只是未启用的占位设置，不会把历史默认值 1 迁移过来。并行单位严格为完整 Surface 拓扑连通域；同一个连通域不会为了增加并行度而拆开。

首次打开面板或已保存路径失效时，模块会自动查找本机受支持的 Altair 2019/2022 `hmbatch.exe`，并选用该安装随附的 `hm/batchmesh/general_8mm.criteria` 与 `general_8mm.param` 作为 Default 规格。扫描同时支持经典 `<year>/hm` 和新版 `<year>/hwdesktop/hm` 布局；不依据父目录年份判断产品版本（例如本机 HyperMesh 2022.0.0.33 安装在 `Altair/2020/hwdesktop`），实际版本始终由 hmbatch 启动门禁确认。Default 预设会从旧安装的自动默认值迁移到新发现的 hwdesktop 安装；有效的自定义预设不会被覆盖。

## 连通域与执行

选择结果立即复制为实际 Surface ID 列表，不保留临时 mark。每个种子写入独立 mark 后反复调用：

```tcl
*appendmark surfs 1 "by attached"
```

直到 mark 数量稳定，再与本次目标 ID 集合取交集。搜索可穿过未被选择但拓扑 attached 的 Surface，但这些非目标 Surface 不会进入任务。焊缝 Surface 不做类型过滤。component ID/名称只用于诊断展示，不参与分组。

执行前重新检查目标 ID 存在性以及全模型 Surface ID 集合签名；发现新增或删除 Surface 后阻止运行并要求重分析。仅改变拓扑但保持全部 Surface ID 不变的修改无法被可靠监听，因此用户在 trim、缝合、边释放、焊缝创建或 surface 替换后必须主动刷新分析。

每个未排除连通域生成一个任务。每个任务在自己的完整模型快照进程中调用统一入口：

```tcl
*createmark surfs 1 {*}$surface_ids
*hm_batchmesh2 surfs 1 1 0 $criteria_file $param_file
```

`number_of_strings=0`，不创建自动参数字符串，不传入 `elem_size`、`params_generate_mode`、`no_washer` 或任何 washer 覆盖项。criteria/param 原文件不被复制或修改。

“启动后台划分”先使用与正式 worker 完全相同的 `hmbatch.exe -nocommand -nouserprofiledialog -tcl hmbatch_preflight.tcl` 命令执行真实门禁，确认 Tcl 被执行、版本属于 2019/2022 且 `*hm_batchmesh2` 存在；门禁失败时不会启动任何连通域任务。通过后保存只读输入快照，再为不同连通域启动相互隔离的 hmbatch，最多同时运行 `PARALLEL_WORKERS` 个。2022 worker 在读入模型后显式执行 `*templatefileset` 和 `*readqualitycriteria`，再调用实机验证过的 `*hm_batchmesh2`。主 HyperMesh 每 500ms 汇总各 worker 的原子状态文件，不会被原生命令阻塞。

Windows 默认勾选“显示 hmbatch 命令窗口”。整次运行只打开一个汇总 CMD：每两秒刷新当前阶段、所有活动 `hmopengl.exe` PID 和任务统计，网格与合并结束后三秒自动关闭，不再为每个 worker/merge 进程创建窗口。关闭该窗口不影响后台任务；取消任务仍会同时终止 launcher 与实际进程树。

后台任务失败时记录原始 Tcl `errorInfo`、Surface IDs、Component 名称和独立日志，并删除该失败任务在后台快照中产生的不确定半成品单元。默认“失败后继续（推荐）”会继续后续连通域；关闭该选项才会把后续任务标为 skipped。用户可以终止整个后台进程树。

`*hm_batchmesh2` 返回后以新增 Element 数量作为任务结果边界：只要产生单元，任务即为完成；质量目标未全部满足或迭代警告记录为 `warning_message`，不会删除已有网格。只有完全没有新增单元时才判定网格失败。网格状态与结果封装状态分别记录，后续 FEM/HM 保存失败不会反向把已完成网格改成失败。

每个成功 worker 保存只移除了快照原有 Elements 的原生 `task_result.hm` 作为恢复文件，并把结果 Component 设为自定义输出范围，通过 `*feoutputwithdata` 输出 `task_result.fem`；这会让模板整体序列化 Component 内的新增 Elements 及依赖，避免旧的逐实体 mark 导出产生只有 GRID、没有 Element 卡的半有效文件。FEM 导出失败只会把“封装状态”标为失败，不会把已生成网格改判为失败。无论成功任务是一个还是多个，都统一进入合并 worker：空白模型逐个执行采用默认 OptiStruct 选项的 `*feinputwithdata2`，使用 `overwrite_flag=0` 自动偏移冲突实体 ID，随后保存干净的 FE-only `merged_result.hm` 并导出 `batchmesh_result.fem`。主会话优先以 `geom_merge=0, fe_merge=1` 导入合并 HM；跨版本原生 HM 不兼容时，自动回退到唯一的最终合并 FEM。

worker 日志记录 FEM 文件大小、预期 Element/Component 数以及 `export_mode=custom_components`。合并日志为每个 FEM 输入记录文件大小、`overwrite_flag=0`、`import_options=default`、Surfaces/Elements/Nodes/Components/Properties/Materials 前后计数、命令返回和完整 `errorInfo`，并记录 `merged_result.hm`、最终 FEM 的大小及最终实体计数。

主会话不再逐包增量导入 FEM，而是一次性 `*mergefile` 已经清理并聚合完成的原生结果。此前一次 HM2019 FEM translator 零增量来自旧的输入/结果组织；当前每个 worker FEM 已可独立打开，并在独立合并进程中逐包验证 Element 增量。导入前后比较 Element/Node/Component/Property/Material ID 集合；命令报错或没有新增单元时整批回滚新增实体。最终 FEM 或原生合并模型无效时不会尝试导入，并保留 worker/merge 日志用于诊断。

## 日志与报告

复用 HybridCore 任务存储。默认目录为项目运行存储下的：

```text
runtime/tasks/batch_mesher/<run-id>/
  run.json
  result.json
  run.log
  task_G001.log
  task_G002.log
  model_before_batchmesh.hm   # 后台进程的不可变输入快照
  background.state
  monitor_batchmesher.cmd      # 单一汇总监视窗口
  monitor_status.txt
  monitor.done                 # 完成信号，触发窗口自动关闭
  workers/T001/
    background_launcher.tcl
    launch.log                 # 管理器在调用 hmbatch 前即写入，含命令、工作目录和 launcher PID
    manager_failure.log        # worker 未进入 Tcl 时仍会生成的管理端失败诊断
    background.state
    hmbatch_worker.log
    launcher_error.log
    hmbatch_stdout.log
    hmbatch_stderr.log
    task_result.fem
    task_result.hm             # 保留源几何元数据、仅含该任务新增 Elements
  merge/                       # 至少一个可聚合 FEM 时生成
    background_launcher.tcl
    launch.log
    manager_failure.log        # 仅管理器判定启动/进程异常时生成
    merge.state
    hmbatch_merge.log
    hmbatch_stdout.log
    hmbatch_stderr.log
    merged_result.hm           # 通过 FE-only merge 得到的完整原生结果
  batchmesh_result.fem        # 仅包含成功任务产生的网格
```

失败日志包含 task/group、Surface 数量、criteria/param 路径、原始 Tcl errorInfo 和检查建议。即使 Altair launcher 没有产生 stdout/stderr，`launch.log` 也会保留实际命令、独立工作目录和 launcher PID；120 秒内未收到真实 worker 状态握手时，`manager_failure.log` 会记录状态文件及各日志是否存在和字节数。

## 测试

离线测试：

```powershell
python modules\batch_mesher\tests\test_batch_mesher.py
```

HM2019 命令可用性矩阵：

```powershell
python tools\run_hm2019_matrix.py --hmbatch "C:\...\hmbatch.exe"
```

2022 实机调查、能力探针、真实网格、并行与合并脚本见 [HyperWorks 2022 BatchMesher 实机调查报告](../docs/batch_mesher_hm2022_investigation.md)。

主会话和所选 hmbatch 可分别使用 HyperMesh 2019 或 2022，不再要求版本一致。版本探测会把 `19`/`19.x` 归一化为 2019，把实机字符串 `22.000000` 归一化为 2022；worker 按 hmbatch 自己的实际版本初始化 profile，并优先使用其安装目录中的 OptiStruct 模板。生产验收应分别覆盖同版本与跨版本组合，以及单一连通域、跨 component 焊缝连通、多任务并发、失败继续、license 降级和失败重试。

## 已知限制与尚未真机验证项

- 当前开发机未安装 HyperMesh，无法在本机重新执行二进制测试；2022 的调用、两进程并发和 `*mergefile` 数据来自 2026-07-31 远端实机报告及其保留脚本。
- `*hm_batchmesh2 surfs 1 1 0 criteria param` 的签名来自 Altair 官方文档（命令版本历史始于 14.0）及项目旧代码中的 HM2019 命令存在性证据，但仍需在目标公司的具体 2019 补丁版用真实模型验证 criteria/param 兼容性和返回错误文本。
- `*appendmark ... "by attached"`、`*isolateentitybymark`、`*setreviewbymark`、`*window_entitymark` 已纳入 `hm2019_api_smoke.tcl`，本开发机因缺少 hmbatch 未运行。
- 不同连通域现已使用多个隔离 hmbatch 并行执行；同一连通域仍是不可拆分的最小安全单元。单次 `*hm_batchmesh2` 内部没有稳定的脚本进度回调，因此进度粒度仍为连通域任务。
- 实机完整车架日志证实：第一个完整 worker HM 可合并，但 HM2019 在第二个完整快照的 `*mergefile` 内直接退出，Tcl 无法捕获错误。因此 worker HM 只作恢复用途，最终聚合改用可独立打开的 worker FEM 和 `overwrite_flag=0` ID 偏移；仍需在目标实机复核最终 Property、Material、Component 归属。
- 原生 `.hm` 通常具有“新版本可读取旧版本”的方向性；如果使用 2022 hmbatch 生成原生结果并导入 2019 主会话，Altair 文件格式本身可能不向后兼容。工具不再预先禁止该组合，但会保留合并模型、最终 FEM 和明确导入错误；生产环境优先使用同版本，或使用不高于主会话版本的 hmbatch。
- 如果一个连通域内部仅部分 Surface 成功、但 `*hm_batchmesh2` 没有抛出 Tcl 错误且创建了单元，当前 API 无法可靠给出逐 Surface 成败清单；仍需结合 hmbatch 日志和网格检查确认。
- Surface ID 集合签名无法发现“ID 完全不变但拓扑已变化”的编辑事件。
