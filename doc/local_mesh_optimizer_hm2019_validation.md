# Local Mesh Optimizer：HyperMesh 2019 命令验证记录

本文件用于在目标 HyperMesh 2019 安装上记录实际命令。未完成本验证前，不得把修改模型的能力标记为已实现。

静态候选签名来自 Altair 官方旧版 `*splitelements`、`*elementqualitycollapseedge`、`*nodemodify` 和 `*readqualitycriteria` 参考。`*quad_split` 的版本历史始于 2020.1，本模块明确不使用它。所有候选仍必须在实际 HM2019 安装上录制和重放。

## 环境信息

| 项目 | 记录 |
| --- | --- |
| HyperMesh 完整版本/build | 待填写 |
| 操作系统 | 待填写 |
| Solver profile | 待填写 |
| Tcl 版本 | 待填写 |
| Python 3 路径和版本 | 待填写 |
| 测试 criteria | 待填写 |
| `command.cmf` 路径 | 待填写 |

## 测试模型

建立一个另存副本，至少包含规则 quad、skew/aspect 失败、孔边、自由边、组件边界、RBE2、RBE3 和两个互不相连失败区。原始模型不得用于命令试验。

## 1. Criteria 和质量检查

1. 清空 `command.cmf` 的观察范围或记下当前行号。
2. 在 Element Quality 面板读取目标 `.criteria`。
3. 只选择少量已知壳单元执行检查。
4. 记录读取 criteria、建立输入 mark、生成失败 mark 和摘要的完整命令。
5. 在 Tcl Console 中用 `catch` 重放。
6. 分别验证：有效文件、路径含空格、中文路径、文件不存在、损坏文件。

必须记录：

```text
criteria 命令：
输入 mark：
失败 mark：
摘要返回结构：
错误返回：
```

失败摘要数量必须与失败 mark 数量一致。读取失败不能解释为零失败。

## 2. 四边形最优对角切分

1. 选择一个已知失败 quad，沿第一条对角切分并记录 `command.cmf`。
2. 重载模型，沿另一条对角切分并记录反向方法。
3. 确认 HM2019 是否使用 `*splitelements 2 1` 和 `*splitelements 102 1`。
4. 检查新 tria 的组件、属性、法向、几何关联和 criteria 结果。

```text
普通对角命令：
反向对角命令：
新 element ID 行为：
组件/属性/法向是否保持：
错误行为：
```

## 3. 瘦长单元短边塌缩

分别对瘦长 tria 和非自由边细长 quad 执行一次 F3/短边合并，记录 setup、edge index、collapse 和 shutdown。确认 edge index 与 element 节点顺序的对应关系是否为 1-based；故意传入无效 element ID，确认异常后 shutdown 仍能执行。

```text
setup：
tria 短边命令和 edge index：
quad 内部短边命令和 edge index：
shutdown：
相邻 element 重连/删除行为：
返回/错误：
```

## 4. 细长条带自由边外扩

1. 使用至少三个相连细长 quad 的条带，确认目标长边为真实自由边。
2. 沿每个节点对应短边从内部节点指向自由边节点的方向移动。
3. 记录 `*nodemodify` 或 HM2019 实际命令。
4. 检查共享自由边节点是否只移动一次、非自由边是否不动、几何关联是否保持。
5. 保持几何关联无法证明时，该动作必须跳过并转人工处理。

```text
节点移动命令：
真实自由边确认方式：
几何关联前后：
相邻单元质量：
```

## 5. 模型快照和恢复

1. 另存 `before.hm`。
2. 修改一个测试节点。
3. 读取 `before.hm`。
4. 确认模型路径、组件、节点坐标、显示状态和当前 collector。
5. 记录 `*writefile` / `*readfile` 或目标版本实际命令。
6. 确认整个任务只产生一次 `before.hm`；区域和轮次处理中不产生 `.hm` 检查点。
7. 正常完成时确认只生成一个带时间戳的最终优化模型；取消或质量恶化时确认恢复 `before.hm` 并终止任务。
8. 连续运行两次，确认覆盖 `before.hm` 以及读回已修改模型时没有原生确认弹窗；`command.cmf` 中应能看到 `hm_answernext yes` 紧邻模型读写命令。
9. 确认任务完成后的进度窗口保留并显示最终状态，点击“关闭”后才消失。

```text
保存命令：
读取命令：
是否产生非空 HM 文件：
节点是否恢复：
显示/collector 是否恢复：
```

## 6. 显示状态

记录并验证失败 element mark 的隔离、上一处/下一处视角、全部恢复命令。确认不会永久改变非目标 component 的显示状态。

## 7. 能力启用门禁

只有以上各项通过且命令已回填到受版本检查保护的适配层后，才允许把：

```text
HM2019_PROFILE hm2019_recorded
```

写入模块状态。仅修改该字符串不会自动启用 guessed command；源码中仍必须存在对应的已录制适配实现、错误捕获和回退测试。

## 当前结果

截至 2026-07-14，本仓库所在环境没有 HyperMesh/HM Batch、`command.cmf` 或 `.criteria` 样本。本表尚未实机执行，修改模型的优化流程因此保持禁用。
