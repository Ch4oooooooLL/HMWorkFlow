# HyperWorks 2022 BatchMesher 实机调查与并行落地报告

调查日期：2026-07-31
实机安装根目录：`D:\Program Files\Altair`
实测版本：HyperMesh `v2022.0.0.33`，`hm_info -appinfo VERSION` 返回 `22.000000`

## 1. 结论

HyperWorks 2022 可以从本项目调用 BatchMesh，也可以通过多个隔离的 HyperMesh batch 进程并行调用。已经完成以下实机闭环：

1. 两个 `hmbatch.exe` 入口均成功启动 2022，并确认 `*hm_batchmesh2`、`*batchmesh_mc`、`*hm_batchmesh` 和 BatchMesh job API 存在。
2. 普通 `hmbatch -tcl` 中使用 `*hm_batchmesh2`，真实生成并保存了 40,000 个元素。
3. 两个独立进程同时各生成 40,000 个元素，网格计算区间重叠 10.751 秒。
4. 2022 自带的 `hw_batchmesh.bat -nogui` 成功处理同一模型，报告为 0 个失败 surface、0 个失败 element。
5. 两个 worker 的独立 `.hm` 结果使用 `*mergefile` 合并后为 2 个 surface、20,000 个 element、2 个 component；保存并重新打开后计数不变。

当前 `modules/batch_mesher` 不能原样用于 2022，也没有并行调度。问题是项目代码中的版本门禁和执行架构，不是 2022 缺少 BatchMesh API。

## 2. 已确认的安装入口

| 用途 | 路径 | 结论 |
|---|---|---|
| 推荐的 HyperMesh batch 启动器 | `D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe` | 实测通过 |
| 另一个 batch 启动器 | `D:\Program Files\Altair\hwdesktop\hw\bin\win64\hmbatch.exe` | 实测通过，最终也启动下列 `hmopengl.exe` |
| 实际 HyperMesh 进程 | `D:\Program Files\Altair\hwdesktop\hw\bin\win64\hmopengl.exe` | 两个启动器的 `info nameofexecutable` 均指向此文件 |
| 官方独立 BatchMesher | `D:\Program Files\Altair\hwdesktop\hm\batchmesh\hw_batchmesh.bat` | `-nogui` 实测通过 |
| 独立 BatchMesher 配置 | `D:\Program Files\Altair\hwdesktop\hm\batchmesh\hw_batchmesh.cfg` | 内含 `<Multi_CPU Number_of_CPU="auto" />` |
| OptiStruct profile/template | `D:\Program Files\Altair\hwdesktop\templates\feoutput\optistruct\optistruct` | 外部 worker 必须加载 |
| 2022 自带 criteria | `D:\Program Files\Altair\hwdesktop\hm\batchmesh\general_10mm.criteria` | 实测使用 |
| 2022 自带 param | `D:\Program Files\Altair\hwdesktop\hm\batchmesh\general_10mm.param` | 实测使用 |

不要从安装根目录名推导版本。这套安装没有版本号子目录，可靠版本来自正在运行的 HyperMesh。

## 3. 2022 API 与启动方式

### 3.1 `*hm_batchmesh2`

2022 随附帮助给出的签名仍是：

```tcl
*hm_batchmesh2 entity_type mark_id string_array number_of_strings criteria_file param_file
```

项目当前使用的调用形状与 2022 一致：

```tcl
*createmark surfs 1 {*}$surfaceIds
*hm_batchmesh2 surfs 1 1 0 $criteriaPath $paramPath
```

但是，在全新的外部 `hmbatch -tcl` worker 中，还需要 profile 和 criteria 初始化。实测最小顺序为：

```tcl
hm_answernext "yes"
*deletemodel

set templatePath [file normalize [file join \
    [file dirname [info nameofexecutable]] .. .. .. \
    templates feoutput optistruct optistruct]]
*templatefileset $templatePath

*readqualitycriteria $criteriaPath
*createmark surfs 1 {*}$surfaceIds
*hm_batchmesh2 surfs 1 1 0 $criteriaPath $paramPath
```

在已经加载用户 profile 的交互式主会话中，不需要删除模型或重新加载 template；这些步骤是给独立 worker 的。

### 3.2 `*hm_batchmesh` 与官方独立 runner

安装自带的独立 runner 不是简单执行 `hmbatch -tcl`。它启动：

```text
hmopengl.exe -batchmesher -noconsole -c<command-file>
```

并在该专用上下文中调用：

```tcl
*readqualitycriteria $criteriaPath
*hm_batchmesh 1 $criteriaPath $paramPath
```

不要在普通 `hmbatch -tcl` worker 中直接换成 `*hm_batchmesh`。实测该组合会使进程在 Tcl 报告写出前异常结束。普通 worker 使用已经验证的 `*hm_batchmesh2`；若采用 `*hm_batchmesh`，必须完整复用官方 `hw_batchmesh.bat` 路线。

### 3.3 官方 `hw_batchmesh.bat`

单文件、无 GUI 的已验证命令形状为：

```powershell
& 'D:\Program Files\Altair\hwdesktop\hm\batchmesh\hw_batchmesh.bat' `
  -nogui `
  -cad_model_file 'C:\work\input.hm' `
  -cad_translator hm `
  -criteria_file 'D:\Program Files\Altair\hwdesktop\hm\batchmesh\general_10mm.criteria' `
  -param_file 'D:\Program Files\Altair\hwdesktop\hm\batchmesh\general_10mm.param' `
  -work_dir 'C:\work\result' `
  -run_results 'C:\work\result\run_results.txt' `
  -qi_post_procedure false
```

帮助中还确认：

- `-nogui` 是单个 BatchMesher job 的命令行模式。
- GUI/config 模式支持 `-batch -config_file <path> -multicpu <number>`。
- `-cad_model_dir` 与 `-cad_model_ext` 可提交一批输入文件。
- 本地 `hm_jobs_submitBatchmeshJob` server 按 2022 帮助说明是顺序执行，不能把它当成本地并行调度器。

本项目需要按几何连通域自行控制、取消和合并结果，建议使用多个隔离 `hmbatch -tcl` worker，而不是依赖 local jobs server。

## 4. 实测数据

### 4.1 API 能力探针

两个 `hmbatch.exe` 入口同时启动，均返回：

```text
hm_version=22.000000
command.*appendmark=1
command.*batchmesh_mc=1
command.*hm_batchmesh=1
command.*hm_batchmesh2=1
command.*readqualitycriteria=1
command.hm_jobs_submitBatchmeshJob=1
blank_mark_by_attached=PASS
status=PASS
```

### 4.2 两进程并行 BatchMesh

两个 worker 使用相同 criteria/param、不同工作目录，各对一个 2000 x 2000 平面划分 10 mm 网格：

| 指标 | Worker A | Worker B |
|---|---:|---:|
| 元素数 | 40,000 | 40,000 |
| BatchMesh 时间 | 10.779 s | 10.762 s |
| 总 worker 时间 | 11.065 s | 11.057 s |
| 输出模型大小 | 1,091,795 B | 1,091,794 B |
| 状态 | PASS | PASS |

两个网格计算区间重叠 `10.751 s`，整体墙钟约 `11.904 s`。这不是两个任务排队执行，而是真正的进程并行。

此结果只证明当前机器和当前许可证环境至少允许 2 个并发实例。生产环境仍需把 license denial 作为可识别失败，并允许把 worker 数降为 1。

### 4.3 官方独立 runner

`hw_batchmesh.bat -nogui` 的 `run_results.txt` 给出：

```text
HWVersion: 2022.0.0.33
surfs=1
elems=40000
failed_surfs=0
failed_elems=0
quality_index=0.00
```

生成的 `.hm` 大小为 929,851 B，随后由新的 `hmbatch` 进程重新打开，得到 1 个 surface、40,000 个 element，验证通过。

### 4.4 worker 结果合并

两个隔离 worker 分别处理位于不同位置的 1000 x 1000 平面，各生成 10,000 个元素。主进程执行：

```tcl
*mergefile $workerModelA 1 1
*mergefile $workerModelB 1 1
```

结果：

```text
after_a_surfaces=1
after_a_elements=10000
after_a_components=1
after_ab_surfaces=2
after_ab_elements=20000
after_ab_components=2
status=PASS
```

合并模型保存后由另一个进程重新打开，仍为 2 个 surface、20,000 个 element。2022 的 `*mergefile` 会以最小扰动方式重命名/重编号传入实体，可处理各 worker 从相同 ID 起点创建实体的冲突。

## 5. 当前模块必须调整的位置

另一台电脑合并 2022 实现时至少要核对以下改动：

1. `config.tcl` 当前把 `HYPERMESH_VERSION` 固定为 2019，并把 `FUTURE_PARALLEL_WORKERS` 固定为 1。
2. `executor.tcl::requireHm2019` 会拒绝 2022。2022 的版本字符串是 `22.000000`，不是包含文本 `2022`。
3. `testHmbatchStartup` 当前要求探针返回 2019，选中本机 2022 启动器也会被主动判失败。
4. `runBatchMesher2019` 应改成版本中性的 worker 调用层。
5. `runTasks` 当前在主 HyperMesh 会话中 `foreach` 顺序执行原生命令，没有创建外部进程。
6. 当前 `HMBATCH_PATH` 虽然被配置验证和启动探针使用，但实际网格任务没有用它启动 worker。
7. UI、README 和日志仍写明 HyperMesh 2019、Sequential tasks。

推荐版本归一化逻辑至少覆盖：

```tcl
set raw [string trim [hm_info -appinfo VERSION]]
if {[regexp {^22(?:\.|$)} $raw]} {
    set release 2022
} elseif {[regexp {(^|[^0-9])2019([^0-9]|$)|^19(?:\.|$)} $raw]} {
    set release 2019
} else {
    error "Unsupported HyperMesh version: $raw"
}
```

启动探针应接收 `expected_release`，不要在探针脚本内写死年份。

## 6. 推荐的并行架构

### 6.1 主会话职责

1. 校验模型已保存，做一次不可变备份。
2. 按最终拓扑连接关系分组；一个连通域绝不能再拆给多个 worker。
3. 为每个 group 生成独立输入 `.hm`，只保留该 group 所需 geometry、相邻约束数据和目标 component。不要让每个 worker 输出完整基础模型，否则合并时会重复所有未修改数据。
4. 为每个任务建立独立目录，写入 manifest：surface IDs、criteria/param 哈希、输入模型、期望输出和 worker 状态。
5. 按最大 worker 数启动进程，异步读取完成文件；Tk 主线程不能用同步 `exec` 等待。
6. 所有 worker 完成后，在主会话中按任务顺序 `*mergefile <worker.hm> 1 1`。
7. 检查 surface/element/component 增量，保存合并模型，并用重新打开或回滚机制验证。

### 6.2 worker 职责

1. 仅在自己的工作目录运行。HyperMesh 会生成 `command1.tcl`；多个 worker 共用目录会发生覆盖。
2. 加载输入 `.hm` 和正确 profile。
3. 调用 `*readqualitycriteria`。
4. 重新检查 manifest 中的 surface IDs 全部存在。
5. 调用 `*hm_batchmesh2`，记录开始/结束绝对时间、元素前后计数和 Tcl error info。
6. 将 component 改为带 group ID 的唯一名称，保存独立 `.hm`。
7. 用原子完成标志通知主进程；stdout 仅作诊断，不作为成功依据。

### 6.3 进程控制注意事项

- `hmbatch.exe` 是 launcher，Tcl 的 `[pid]` 是实际 `hmopengl.exe`，两个 PID 不相同。取消时要终止整个进程树，不能只杀 launcher。
- 当前机器的启动脚本会自动加载 HMWorkFlow 并输出快捷键注册警告。worker 必须忽略这类 stdout 噪声，以结构化结果文件和进程退出状态为准。
- `*hm_batchmesh2` 在单个 HyperMesh 进程内是同步、不可安全中断的。外部 worker 架构允许通过终止该 worker 进程来取消当前任务，而不破坏主会话。
- 每个 worker 都要独立保存 stderr、stdout、Tcl 报告和输出模型。
- 默认 worker 数建议保守设为 2，并允许用户改为 1；CPU 数不是 license 并发数。

## 7. 必须保留的失败处理

实测得到的 2022 特有或 batch 特有陷阱：

1. `*deletemodel` 前没有 `hm_answernext "yes"` 会触发不可由普通 Tcl `catch` 接住的 FatalError。
2. 新 worker 没有加载 profile 时，`*hm_batchmesh2` 报 `No user profile or template file loaded.`。
3. 加载 profile 但没有先执行 `*readqualitycriteria` 时，本机返回 Tcl error 值 `0`，没有有用错误文本。
4. 普通 `hmbatch -tcl` 直接调用旧 `*hm_batchmesh` 会异常退出；它属于官方 `-batchmesher` 专用上下文。
5. 主会话内原生命令失败不能靠并行重试覆盖；失败 group 必须保留独立输入、日志和可单独重跑入口。
6. 并行合并前必须保证 worker 输出只包含该 group，component 名称唯一，并验证合并增量。

## 8. 验收清单

在真实项目模型上完成 2022 功能前，应全部通过：

- [ ] `hm2022_capability_probe.tcl` 返回所有必需命令可用。
- [ ] 单 group worker 使用用户 criteria/param 成功，且结果重新打开有效。
- [ ] 两个断开的真实 group 并发，时间区间确实重叠。
- [ ] worker 目录、日志、模型和完成标志完全隔离。
- [ ] 两个 worker `.hm` 合并后，几何、元素、component 和属性增量正确。
- [ ] 合并模型重新打开后计数和质量报告一致。
- [ ] 同一拓扑连通域不拆分，公共边网格连续性与串行基线一致。
- [ ] 一个 worker 失败时，其他 worker 结果不丢失，主模型不被部分合并。
- [ ] 取消可终止实际 `hmopengl.exe` 进程树。
- [ ] license 不允许并发时给出明确提示，并能降级到单 worker。
- [ ] criteria/param 在运行中被修改时，通过哈希或 mtime 检出并阻止混用。

## 9. 本次留下的可复用探针

- `modules/batch_mesher/tests/hm2022_capability_probe.tcl`：版本、命令和 `by attached` 能力检查。
- `modules/batch_mesher/tests/hm2022_batchmesh_smoke.tcl`：生成最小几何并真实调用 `*hm_batchmesh2`。
- `modules/batch_mesher/tests/hm2022_model_verify.tcl`：重新打开 `.hm` 并验证实体计数。
- `modules/batch_mesher/tests/hm2022_merge_verify.tcl`：合并两个 worker `.hm` 并验证增量。

本次实机原始产物位于 `runtime/tasks/batch_mesher/hm2022_research/`，包括并行报告、stdout/stderr、官方 runner 报告、worker 模型和合并模型。
