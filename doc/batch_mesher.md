# BatchMesher 自动网格划分（HyperMesh 2019）

## 入口与职责

主页 `网格` 分组中的 `BatchMesher 自动网格划分` 调用 `::BatchMesher::runAction`。旧的 `batch_mesh_washer.tcl`、component 分批、自动参数生成和二次 washer 规则已删除。

实现文件：

| 文件 | 职责 |
| --- | --- |
| `modules/batch_mesher.tcl` | 模块装载入口。 |
| `modules/batch_mesher/config.tcl` | hmbatch 路径、criteria/param 多预设和执行选项持久化。 |
| `modules/batch_mesher/selection.tcl` | Surface ID 选择、mark 重建、实体有效性及 component 展示信息。 |
| `modules/batch_mesher/connectivity.tcl` | HM2019 `by attached` 连通域、诊断、排除和任务构建。 |
| `modules/batch_mesher/executor.tcl` | HM2019 命令封装、顺序调度、失败重试、停止后续任务和备份。 |
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
FUTURE_PARALLEL_WORKERS 1
```

`FUTURE_PARALLEL_WORKERS` 仅为后续调度接口预留，当前版本始终单会话顺序执行。hmbatch 路径只用于路径验证与无模型启动探针；当前版本不提供模型拆分、后台合并或伪并行。

## 连通域与执行

选择结果立即复制为实际 Surface ID 列表，不保留临时 mark。每个种子写入独立 mark 后反复调用：

```tcl
*appendmark surfs 1 "by attached"
```

直到 mark 数量稳定，再与本次目标 ID 集合取交集。搜索可穿过未被选择但拓扑 attached 的 Surface，但这些非目标 Surface 不会进入任务。焊缝 Surface 不做类型过滤。component ID/名称只用于诊断展示，不参与分组。

执行前重新检查目标 ID 存在性以及全模型 Surface ID 集合签名；发现新增或删除 Surface 后阻止运行并要求重分析。仅改变拓扑但保持全部 Surface ID 不变的修改无法被可靠监听，因此用户在 trim、缝合、边释放、焊缝创建或 surface 替换后必须主动刷新分析。

每个未排除连通域生成一个任务，并顺序调用统一入口：

```tcl
*createmark surfs 1 {*}$surface_ids
*hm_batchmesh2 surfs 1 1 0 $criteria_file $param_file
```

`number_of_strings=0`，不创建自动参数字符串，不传入 `elem_size`、`params_generate_mode`、`no_washer` 或任何 washer 覆盖项。criteria/param 原文件不被复制或修改。

当前会话中的原生 BatchMesher 调用不能安全中断；“停止后续任务”只设置调度停止标志，当前任务仍以真实结果进入 completed/failed，后续 pending 任务转为 cancelled。

## 日志与报告

复用 HybridCore 任务存储。默认目录为项目运行存储下的：

```text
runtime/tasks/batch_mesher/<run-id>/
  run.json
  result.json
  run.log
  task_G001.log
  task_G002.log
  model_before_batchmesh.hm   # 启用运行前备份时
```

失败日志包含 task/group、Surface 数量、criteria/param 路径、原始 Tcl errorInfo 和检查建议。

## 测试

离线测试：

```powershell
python modules\batch_mesher\tests\test_batch_mesher.py
```

HM2019 命令可用性矩阵：

```powershell
python tools\run_hm2019_matrix.py --hmbatch "C:\...\hmbatch.exe"
```

生产调用验收必须在 HyperMesh 2019 中打开已保存的代表模型，选择一个小型独立 Surface 连通域，使用审批过的 criteria/param，启用备份后执行；检查 `result.json`、任务日志、生成网格以及 param 内 washer 规则是否生效。随后分别验证单一连通域、跨 component 焊缝连通、同 component 孤立区域、多任务失败继续和失败重试。

## 已知限制与尚未真机验证项

- 当前开发机未安装 HyperMesh 2019，无法在本次交付中执行 hmbatch 矩阵或真实 `*hm_batchmesh2` 网格任务。
- `*hm_batchmesh2 surfs 1 1 0 criteria param` 的签名来自 Altair 官方文档（命令版本历史始于 14.0）及项目旧代码中的 HM2019 命令存在性证据，但仍需在目标公司的具体 2019 补丁版用真实模型验证 criteria/param 兼容性和返回错误文本。
- `*appendmark ... "by attached"`、`*isolateentitybymark`、`*setreviewbymark`、`*window_entitymark` 已纳入 `hm2019_api_smoke.tcl`，本开发机因缺少 hmbatch 未运行。
- 当前仅支持当前 HyperMesh 会话顺序执行。配置 hmbatch 和测试启动不等于后台完整模型执行；模型拆分、并行和结果合并均未实现。
- Surface ID 集合签名无法发现“ID 完全不变但拓扑已变化”的编辑事件。
