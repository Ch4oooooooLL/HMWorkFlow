# Local Mesh Optimizer 测试记录

日期：2026-07-15

## 当前环境

- 已发现并实机使用 `C:/Program Files/Altair/2019`；
- 已使用 `examples/test.criteria` 完成 62556 单元、11592 失败单元的原生质量检查和优化压力运行；
- 实机运行确认 split、collapse、模型任务前快照、质量恶化守卫和整任务恢复路径可达；
- 系统 PATH 没有独立 `tclsh`；离线测试使用项目捆绑 Python 3.8.10；
- 新的多 collapse 共用一次 Element Quality 会话尚需下一次实机运行确认。

## 已通过

```text
python3 -m unittest discover -s modules/local_mesh_optimizer/tests -v
```

通过 25 项；除原有邻接、区域、动作、批次、报告和控制器用例外，新增覆盖：

- 高级设置初始化和未验证 profile 的可见反馈；
- FEM 压力模型规模、washer、可处理/不可处理缺陷及规划器映射；
- 共享失败边上的危险 collapse 整簇转人工复核；
- 节点不相交区域的宏区域稳定打包，重叠区域不合并；
- 宏区域启用后的串行/多进程动作协议一致；
- 进度节流、日志缓冲、Element Quality 会话复用和回退开关静态协议。

原始覆盖清单：

1. 共享完整边邻接；
2. 角点接触不误连；
3. 失败连通区域划分；
4. 逐层扩展；
5. 组件边界阻断；
6. 区域上限不加入半层，以及离线报告生成（同一测试文件中的独立用例）。
7. Python 控制器后台完成状态文件和含中文/空格路径。
8. 四边形两种对角切分评分以及方法 2/102 双向映射；
9. 两长边瘦长三角形的短边识别；
10. 细长四边形真实自由长边的外扩动作规划。
11. 控制器生成 `optimization_actions.csv` 和 `regions.json` 动作协议（四边形切分案例）。
12. Tcl 自动流程无 `tk_messageBox`、模型读写预置 `hm_answernext`，且仅有任务前/最终两次模型写入调用。
13. criteria 上下文缓存、检查结果复用、分层进度调用及默认 Washer 排除协议的静态回归检查。
14. `MeshState` 局部删除/添加单元后反向索引、邻接和脏区更新；
15. 同一共享边候选的稳定去重；
16. 重叠一环操作的冲突识别和确定性分批；
17. 统一 `operations.json`、冲突/批次协议、生成 Tcl 批次和性能计数文件；
18. 两个节点不相交区域在串行/双进程 Python 规划下生成相同旧版动作协议。

真实压力任务只读重规划结果：5425 个原始区域合并为 33 个宏区域，7065 个实机旧批次数投影为 112 个新批次；11592 个失败单元的逐单元动作签名差异为 0。记录见 `doc/local_mesh_optimizer_ab_projection.json`。

另执行全部 Python 文件 `py_compile`、捆绑 Python 3.8.10 运行时自检、Tcl 8.6 `source modules/local_mesh_optimizer.tcl`（98 个模块过程成功加载）和 `git diff --check`。离线 2,000 操作批量基准记录在 `doc/local_mesh_optimizer_batch_benchmark.json`。

## 尚未执行

- `*splitelements 102` 反向对角在 HM2019 的独立实机确认；
- 多个互不冲突 collapse 在同一 `*elementqualitysetup`/`shutdown` 会话内连续执行；
- `*nodemodify` 自由边外扩和几何关联行为；
- RBE2/RBE3/焊缝保护节点；
- 用户取消和修改命令异常时的全任务恢复；质量恶化恢复已实机触发；
- 任务期间不存在区域/轮次 `.hm` 检查点；
- 自动流程没有 `tk_messageBox`，模型读写预置 `hm_answernext yes`；
- 完成进度窗口保留到用户主动关闭；
- quad 切分/短边合并后的失败 ID 增长额度与区域外扩散守卫；
- Washer 孔环识别、排除层数和人工处理报告与实际试验模型的一致性；
- 区域/轮次/动作百分比单调性及 ETA 在 HM2019 长任务中的显示效果；
- 中文 `.hm` 和 `.criteria` 路径的 HM 端行为；
- A/B 版本在同一压力 FEM 上的最终墙钟时间；
- 批量/旧版同模型功能等价与实机耗时对比；
- 同方法 quad mark 批量执行、批次结果状态和脏区增量复检的 HM2019 行为；
- 批次命令失败、取消和最终守卫失败后的快照恢复；
- 快速/标准/深度修改流程；
- 有效 `.hm` 测试模型和示例优化结果。

这些项目必须在目标 HyperMesh 2019 build 上完成，不能用 Python 模拟结果替代。
