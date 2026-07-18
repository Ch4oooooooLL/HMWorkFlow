# HMWorkFlow 仓库目录与发布规则

项目根目录只保留启动入口、全局配置、发布元数据和构建脚本。源码、文档、示例生成器、
测试与可分发运行时分别进入固定目录，运行产物不属于仓库源码。

## 目录边界

| 路径 | 用途 | Git | 发布 ZIP |
| --- | --- | --- | --- |
| `modules/` | Tcl 模块、模块 Python 与测试 | 跟踪 | 包含 |
| `python/hmworkflow/` | 统一 Python 命名空间 | 跟踪 | 包含 |
| `config/` | 默认规则文件 | 跟踪 | 包含，但排除 `*_state.txt` |
| `doc/` | 维护与使用文档 | 跟踪 | 包含，但排除 `command.tcl` |
| `examples/` | README、生成器和固定报告样例 | 跟踪 | 包含，但排除生成 FEM/manifest |
| `runtime/python/` | 便携 Python 发布文件 | 仅跟踪批准层级的文件 | 包含批准文件 |
| `runtime/python/windows-x64/python38/` | 本机解压的 Python 3.8 标准库 | 不跟踪 | 不包含 |
| `%LOCALAPPDATA%/HMWorkFlow/runtime` | 实例日志和任务工作区 | 不在仓库 | 不包含 |
| `dist/`、`temp/`、`logs/` | 构建、临时及旧日志产物 | 不跟踪 | 不包含 |

`python38.zip`、`python38.dll` 和 `python38._pth` 是便携运行时的正式发布文件；这里禁止的
是名为 `python38/` 的解压目录，而不是这些同名前缀文件。

## Git 跟踪审计

执行：

```powershell
python tools/repository_audit.py
```

审计会拒绝以下被跟踪内容：

- 本机工具目录、pytest 缓存、`dist/`、`logs/`、`temp/`；
- HyperMesh 命令捕获、求解器输出、用户 UI state；
- `__pycache__`、`.pyc`、`.pyo`；
- 示例目录中由生成器产生的 FEM 和 `*_manifest.json`；
- `runtime/` 中除批准的便携 Python 文件外的任何内容；
- `runtime/python/` 下的嵌套目录，特别是解压的 `python38/`。

该审计已接入 `tools/run_offline_tests.py`，因此 CI 和本地离线全量测试会在模块测试之前
检查 Git 跟踪列表。

## 打包规则

PowerShell 与 Bash 打包脚本使用源码白名单。便携 Python 不再递归复制整个目录，而是只
复制以下两层中的文件：

```text
runtime/python/*
runtime/python/windows-x64/*
```

任何子目录都不会进入 staging；如 staging 中出现 `python38/`，构建会直接失败。ZIP
生成后，`tools/release_audit.py` 会再次拒绝解压标准库、运行日志、任务、模型、缓存、
用户状态、绝对用户路径和非便携 ZIP entry。

标准验证命令：

```powershell
python tools/repository_audit.py
python tools/run_offline_tests.py
.\build_package.ps1 -PackageName HMWorkFlow_repository_clean.zip
python tools/release_audit.py --zip dist/HMWorkFlow_repository_clean.zip
```
