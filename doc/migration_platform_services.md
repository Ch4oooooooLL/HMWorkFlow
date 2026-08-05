# HMWorkFlow 平台服务迁移说明

本轮稳定化保留现有 Tcl 业务流程和旧路径作为兼容基线，把工程上下文、任务目录、
Python 执行和结果读取收敛到 HybridCore。目标运行基线为 HyperMesh 2019.0.0.70、
OptiStruct、`mm_N_s_tonne`。

## 1. 工程上下文与执行前检查

`config.yaml` 的 `project` 段明确声明求解器和基本单位。任何会修改模型的工具入口会先
执行统一预检，并返回 `PASS`、`WARNING` 或 `BLOCKED`。切换项目单位制时必须同时更新
各单位字段，然后重新设置：

```yaml
project:
  unit_system: mm_N_s_tonne
  solver_profile: OptiStruct
  length_unit: mm
  force_unit: N
  time_unit: s
  mass_unit: tonne
  stress_unit: MPa
  density_unit: tonne_per_mm3
  units_confirmed: true
```

`units_confirmed: false`、不支持的求解器或不可写的任务目录会阻止模型修改。诊断包会记录
当前工程上下文、预检结果和实际存储根目录。

## 2. 用户数据和任务目录

安装目录只保存可发布代码与静态配置，不再作为正常任务输出目录。Windows 默认位置为：

| 数据 | 默认目录 |
| --- | --- |
| 用户配置与 UI 状态 | `%APPDATA%\HMWorkFlow` |
| 缓存 | `%LOCALAPPDATA%\HMWorkFlow\cache` |
| 运行实例日志 | `%LOCALAPPDATA%\HMWorkFlow\runtime\instances` |
| 任务工作区 | `%LOCALAPPDATA%\HMWorkFlow\runtime\tasks` |

如需把大任务放到高速盘，在 `config.yaml` 的 `storage.scratch_dir` 中填写绝对路径；留空时
使用上述默认位置。状态读取会兼容安装目录中已有的 `config/*_state.txt`，新状态只写入
用户配置目录。

每个任务都有不可复用的 task token、`task.meta` 和状态文件。任务成功或失败时必须完成
状态收口；Detached Python 任务还支持合作式取消标记、超时和 Windows 进程树终止。
结果读取会校验 task token、任务边界、文件类型、大小和协议标记，避免从任意路径直接
`source` Tcl sidecar。

## 3. 保留、固定与磁盘配额

默认策略位于 `config.yaml`：

```yaml
storage:
  scratch_dir: ""
  success_retention_days: 7
  failure_retention_days: 30
  success_keep_latest: 10
  max_disk_gb: 20
```

启动后会安排清理：成功任务保留 7 天且至少保留最近 10 个，失败任务保留 30 天；超过
总配额时优先删除较旧且未固定的任务。存在 `.pinned` 标记的任务不参与自动清理。所有
删除操作都再次验证目标位于任务根目录内。

## 4. 模块迁移状态

机器可读状态见 `modules/module_status.json`。其中：

- Auto Hole、Shell Washer-Hole、RBE2 Bolt、Mesh Seam Weld 已使用 HybridCore 生产路径。
- Local Mesh Optimizer 使用共享 detached task 服务和 task token；原控制器协议保留兼容。
- Solid Seam Connector 使用共享任务工作区及二进制结果包络；实现命令仍受已验证命令配置约束。
- Weld Integrity Check 保持 review-only，不扩大为自动模型修改。
- Contact Setup 和 Batch Property Assignment 继续使用已验证的 Tcl 路径。

## 5. 验证与发布

离线全量验证、统一收集和 HM2019 实机矩阵分别执行：

```powershell
python tools/run_offline_tests.py
python -m pytest modules -q
python tools/run_hm2019_matrix.py
```

HM2019 矩阵包含平台服务、Hybrid FEM 导入、Mesh Seam Weld imprint 和 Contact Surface 四个
空模型烟雾场景，报告生成到忽略跟踪的 `runtime/hm2019_matrix_report.json`。它用于确认
真实 HM 命令可执行，但不能替代 Solid Seam 或 Local Mesh 在生产模型上的几何与质量复核。

发布包必须通过白名单构建和 ZIP 审计：

```powershell
.\build_package.ps1 -PackageName HMWorkFlow_platform_stabilization.zip
python tools/release_audit.py --zip dist/HMWorkFlow_platform_stabilization.zip
```

发布包不包含任务目录、日志、缓存、生成的 FEM、manifest 或本机解压的 Python 标准库。
