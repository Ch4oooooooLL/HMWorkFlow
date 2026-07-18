# 混合架构重构验证记录

## 验证环境

- 日期：2026-07-15
- HyperMesh：Altair HyperMesh 2019.0.0.70
- Python：项目内置 CPython 3.8.10（`runtime/python/windows-x64/python.exe`）
- 依赖：仅 Python 标准库

## 自动测试结果

| 范围 | 命令/脚本 | 结果 |
| --- | --- | --- |
| 公共层 | `modules/hybrid_core/tests/run_tests.py` | 7/7 通过 |
| Auto Hole | `modules/auto_hole_rbe2/tests/run_tests.py` | 9/9 通过 |
| Shell Washer | `modules/shell_washer_hole_rbe2/tests/run_tests.py` | 12/12 通过 |
| RBE2 Bolt | `modules/rbe2_bolt_connector/tests/run_tests.py` | 14/14 通过 |
| Mesh Seam | `modules/mesh_seam_weld/tests/run_tests.py` | 13/13 通过 |
| Python 3.8 语法 | `python -m compileall` | 通过 |
| 四个 Python 入口 | 各 `main.py --help` | 通过 |
| Tcl 入口加载 | `hm_source_modules.tcl` | HM2019 退出码 0，四模块均加载成功 |
| 公共桥接 | `runtime_self_test.tcl` | operation log 记录 SUCCESS；hmbatch 固有退出码 1 |

合计 55 项 `unittest`。覆盖实体表面、自由边环、圆孔/椭圆孔、缺口/盲孔、
dependent-node 重复键、X/Y/Z 分组、容差边界、相邻配对、开放/闭合路径、反向/
旋转对齐和退化焊缝单元拒绝。

## HyperMesh 2019 实体集成冒烟测试

脚本：`modules/hybrid_core/tests/hm_hybrid_export_smoke.tcl`

该脚本在全新的 hmbatch 模型中使用 HyperMesh 命令创建真实节点、CQUAD4、CHEXA、
RBE2，再走正式 Tcl exporter、内置 Python 进程和 Tcl sidecar loader；并实际执行
Shell Washer RBE2 与 RBE2 Bolt CBEAM 创建。

最后一次结果：

```text
washer_candidates=1
washer_created=1
seam_path_nodes=8
bolt_pairs=1
bolt_created=1
auto_status=SUCCESS
```

说明：hmbatch 对若干交互显示选项输出 `*setoption: Invalid option specified`，但这些调用
均位于原有容错路径中，不影响实体导出、Python 识别或创建，最终退出码为 0。

## 对比模式与任务证据

四模块均支持 `python`、`legacy_tcl`、`compare`。任务证据位于：

```text
runtime/tasks/<module>/<run_id>/
```

包括 request、mesh、existing entities、JSON/Tcl 结果、stdout、stderr、operation log，
compare 模式另写 `comparison.json`。旧 Tcl 算法仍保留，未进入阶段 6 删除。

## 当前边界

- 已自动验证真实 HM2019 导出/进程/sidecar、Shell Washer RBE2 创建和 Bolt CBEAM 创建。
- Auto Hole 冒烟模型为无孔 CHEXA，只验证了真实实体导出与成功分析；复杂实体孔需用生产
  模型继续积累 compare 报告。
- Mesh Seam 自动验证覆盖阶段 A 的真实壳自由边导出与 Python 路径识别；阶段 B 的匹配/
  对齐由单元测试覆盖。`imprint_nodelist` 和 ruled automesh 的生产模型效果仍依赖模型网格
  与当前 solver profile，不在空白 hmbatch 模型中伪造结论。
- 因此默认后端已按任务设置为 Python，但保留 `legacy_tcl` 作为即时回退路径；旧算法暂不删除。

## 2026-07-15：响应性、进度与常驻 Python 回归

- 根因：原桥接层用同步 Tcl `exec` 等待 Python，等待期间 HyperMesh/Tk 事件循环不刷新；
  Shell Washer 又按 Component 重复调用，所以最容易表现为卡死。
- 修复：改为本地 stdin/stdout 管道的常驻 Python worker，并用 Tcl `fileevent + vwait`
  等待结果。等待期间事件循环持续工作，不使用 TCP、HTTP 或第三方服务。
- 四模块实体冒烟测试的 4 次 Python 调用已确认复用同一个 worker PID。
- worker 异常退出、请求超时或启动失败会清理管道；入口保留 one-shot 回退路径。
- 进度改为阶段预算：导出、Python 分析、实体校验/创建、刷新分别占固定区间；Python
  运行区间只显示平滑活动进度，候选创建区间使用实际 `index/total`。
- UI 刷新节流为最多约每 150 ms 一次；Shell 原有总进度仍保留 1%/500 ms 节流。

HyperMesh 2019 hmbatch 微基准（5 次平均，极小任务）：

```text
persistent_average_ms=15.800
one_shot_average_ms=48.400
speedup=3.06x
```

微基准脚本：`modules/hybrid_core/tests/hm_worker_benchmark.tcl`。实际大模型中算法耗时占比
会提高，常驻 worker 主要消除解释器启动和 Python 版本探测的重复开销。

用户实际 Shell Washer 导出回归（74,400 elements、86,401 nodes、11 MB mesh JSON）：

| 指标 | 修复前 | 修复后 |
| --- | ---: | ---: |
| mesh read/validation | 71.108 s | 0.338 s |
| detection + result validation | 1.046 s | 0.617 s |
| Python 进程总墙钟时间 | 约 72 s | 1.133 s |
| candidates | 453 | 453 |

根因是 `read_mesh` 在每个 element 上重复执行 `set(nodes)`；现改为读取节点后只构建一次
`known_node_ids`。同时缓存 Component → elements 索引，并让候选结果验证复用节点索引。
新增 12,000 nodes / 10,000 elements 性能回归测试，防止退回全节点重复扫描。
