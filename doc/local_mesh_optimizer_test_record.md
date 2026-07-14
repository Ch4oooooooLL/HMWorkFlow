# Local Mesh Optimizer 测试记录

日期：2026-07-14

## 当前环境

- 未发现 HyperMesh/HM Batch 可执行文件；
- 未发现 Altair/HyperMesh 环境变量；
- 未发现 `command.cmf` 或 `.criteria` 样本；
- 系统没有 `tclsh`，Python 的 Tk 绑定也缺少运行库，因此未完成独立 Tcl 解释器 source smoke test；
- Python 3 可用。

## 已通过

```text
python3 -m unittest discover -s modules/local_mesh_optimizer/tests -v
```

通过 13 项：

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

另执行 `python3 -m py_compile modules/local_mesh_optimizer/python/*.py`、运行时自检、`bash -n build_package.sh`、Linux 打包烟雾测试和 `git diff --check`。测试包确认包含 `python.exe`、`pythonw.exe`、控制器和响应性检查文档。

## 尚未执行

- HyperMesh 2019 criteria 原生检查；
- `*splitelements 2/102` 的 HM2019 对角方向和新 element ID 行为；
- `*elementqualitycollapseedge` 的 HM2019 edge index、相邻重连和 shutdown；
- `*nodemodify` 自由边外扩和几何关联行为；
- RBE2/RBE3/焊缝保护节点；
- 模型快照和恢复；
- 取消、质量恶化或修改命令异常时的全任务恢复；
- 任务期间不存在区域/轮次 `.hm` 检查点；
- 自动流程没有 `tk_messageBox`，模型读写预置 `hm_answernext yes`；
- 完成进度窗口保留到用户主动关闭；
- quad 切分/短边合并后的失败 ID 增长额度与区域外扩散守卫；
- Washer 孔环识别、排除层数和人工处理报告与实际试验模型的一致性；
- 区域/轮次/动作百分比单调性及 ETA 在 HM2019 长任务中的显示效果；
- 中文 `.hm` 和 `.criteria` 路径的 HM 端行为；
- 大模型性能；
- 快速/标准/深度修改流程；
- 有效 `.hm` 测试模型和示例优化结果。

这些项目必须在目标 HyperMesh 2019 build 上完成，不能用 Python 模拟结果替代。
