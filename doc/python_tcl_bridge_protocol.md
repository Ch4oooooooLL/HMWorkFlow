# Python/Tcl 桥接协议

## 1. 版本与职责

当前协议版本为 `1.0`，兼容 Python 3.8 和 Tcl 8.5 风格。Python 进程只读取任务
目录中的文件并写入结果，不读取或修改 HyperMesh 模型。Tcl 是模型数据和模型修改的
唯一所有者。

公共实现位于：

- `modules/hybrid_core/python/`
- `modules/hybrid_core/tcl/`

## 2. 运行目录

每次调用通过 `::HybridCore::createTaskWorkspace <module>` 创建：

```text
runtime/tasks/<module>/<YYYYMMDD_HHMMSS_pid_suffix>/
```

不得复用先前任务。启动前 `clearTaskOutputs` 只清理当前新任务中的输出文件，不跨任务
删除数据。

## 3. 输入

`request.json` 必须包含：

```json
{
  "schema_version": "1.0",
  "module": "auto_hole_rbe2",
  "run_id": "20260715_163501_1234",
  "hypermesh_version": "2019",
  "selected_component_ids": [1, 2],
  "settings": {},
  "options": {
    "debug": false,
    "keep_runtime_files": true
  }
}
```

`mesh.json` 使用紧凑节点数组：

```json
{
  "schema_version": "1.0",
  "components": [
    {"component_id": 1, "component_name": "COMP_A", "mesh_class": "SOLID"}
  ],
  "nodes": [[1001, 0.0, 0.0, 0.0]],
  "elements": [
    {
      "element_id": 2001,
      "component_id": 1,
      "element_type": "CHEXA",
      "node_ids": [1, 2, 3, 4, 5, 6, 7, 8]
    }
  ]
}
```

已有连接实体写入 `existing_entities.json`。所有 ID 保留 HyperMesh 原始值。

## 4. 输出

`result.json` 固定顶层字段：

```json
{
  "schema_version": "1.0",
  "module": "auto_hole_rbe2",
  "run_id": "20260715_163501_1234",
  "status": "SUCCESS",
  "summary": {},
  "candidates": [],
  "warnings": [],
  "errors": [],
  "performance": {
    "read_seconds": 0.0,
    "detect_seconds": 0.0,
    "write_seconds": 0.0
  }
}
```

状态为 `SUCCESS`、`PARTIAL` 或 `ERROR`。每个 candidate 必须有本次结果内唯一且稳定的
`candidate_id`。

`result.tcl` 以 `# HYBRID_CORE_RESULT_V1` 开头，只设置调用方指定的全局变量。生成器
对反斜杠、美元符号、方括号、引号、换行和制表符转义；内容使用 Tcl `dict`/`list`
结构，不包含 HyperMesh 命令。

## 5. 进程与日志

Python 解析顺序：

1. `runtime/python/windows-x64/python.exe`

不允许回退到系统 `python3` 或 `python`。`shortcut_bootstrap.tcl` 在每个 HyperMesh
实例启动时预热一个独占 worker；该 worker 的父进程就是对应的 HyperMesh，stdin/stdout
管道也只属于该实例。HyperMesh 退出后管道关闭，worker 自动退出。

候选运行时必须通过 Python 3.8+ 探测。执行时分别重定向：

- stdout → `python_stdout.log`
- stderr → `python_stderr.log`
- Python/Tcl 操作日志 → `operation.log`

非零退出码、缺少输出、schema 不匹配、module 不匹配、run_id 不匹配或 ERROR 状态均
阻止模型创建。错误提示必须包含 stderr 或其路径。

## 6. Tcl 加载顺序

1. 新建任务目录。
2. 写入全部输入并记录数量。
3. 删除当前任务的旧输出（通常为空）。
4. 启动 Python 并等待退出。
5. 检查 `result.json` 和 `result.tcl` 均存在。
6. 通过 `loadResultSidecar` 校验 marker、schema、module、run_id、status。
7. 创建每个候选前再次检查相关 HM 实体仍存在。
8. 单候选错误只计入失败项并继续；结构级错误终止本次任务。

## 7. 后端模式

- `legacy_tcl`：只运行旧 Tcl 识别和创建。
- `python`：Python 识别，Tcl 创建。
- `compare`：旧 Tcl 与 Python 都识别，写 `comparison.json`；只有配置指定的一侧可以
  执行创建，禁止两侧重复创建。

后端开关属于开发/高级配置，不改变主界面按钮语义。
