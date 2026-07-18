# Local Mesh Optimizer 批量架构

局部网格优化按“导出、规划、执行、复检、报告”五个阶段运行。Tcl 负责读取和修改 HyperMesh 模型，Python 只处理数据、生成计划和汇总结果。

## 数据流

1. Tcl 将任务元数据、失败单元、节点坐标、单元连接和保护范围写入任务目录。
2. Python 构建区域、操作、冲突关系和无共享节点的执行批次。
3. Tcl 逐批执行已校验计划，并为每个操作写入结构化结果。
4. Python 根据复检结果生成下一轮计划或最终报告。
5. Tcl 在任何模型写入失败时按任务事务回滚。

每个结果都携带 run ID 和 task token。取消时先写入协作式取消标记；宽限期后由 detached task 服务终止对应进程树。旧任务的结果不能被新任务加载。

## 主要文件

- 输入：`task.json`、`failed_elements.txt`、`element_connectivity.csv`、`node_coordinates.csv`。
- 计划：`regions.json`、`operations.json`、`conflicts.json`、`batches.json`。
- 执行：`batches/*.tcl`、`batch_results/*.json`、`region_results.csv`。
- 报告：`summary.html`、`summary.csv`、`regions.csv`、`settings.json`。

任务目录属于运行数据，不进入 Git 或发布 ZIP。大型中间文件应放在用户配置的 SSD scratch 目录。
