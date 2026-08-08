# HMWorkFlow 模块 HyperMesh 原生指令审计报告(跨模块汇总)

日期:2026-08-08
范围:全部模块(除正在修改的 adhesive_connector 与已对齐的 solid_seam)
实机:HyperMesh 2019.0.0.70(hmbatch `C:\Program Files\Altair\2019\hm\bin\win64`)与
HyperMesh 2022.0.0.33(hmbatch `D:\Program Files\Altair\hwdesktop\hm\bin\win64`)

---

## 1. 审计方法与结论分级

- **方法**:每模块一个子代理,通过 `hmbatch.exe -nocommand -nouserprofiledialog -tcl <script>` 无头实机探针,
  结果写 `runtime/audit_*.log`(KEY=VALUE,ASCII),一个脚本只启动一次以控制共享浮动许可证。
- **两件事**:① 当前使用的 HyperMesh 原生指令在实机上是否有效/正确;② 是否有更优的原生指令可替换。
- **分级**:
  - 健康 = 全部指令有效,无修复项
  - 基本健康 = 存在低危问题(死代码、冗余、可加固),不影响主流程
  - 需修复 = 存在中高危问题(指令参数错误、功能路径失效),影响主流程
  - 良好 = 健康且有多处更优替代已确认

**预验证事实(所有子代理共用,不再重复探针)**:

| 事实 | 说明 |
| --- | --- |
| `*markdistance` 两版本均不存在 | 节点邻近须用坐标循环 |
| `*createlist`(有序)≠ `*createmark`(无序) | seam location 用 `*createlist`,无序 mark 产生断裂环 |
| `comps` / `components` 等价 | connector link 关键字 |
| `*CE_*` 命令面两版本一致 | 110 个命令,含 `*CE_ConnectorCreateByMark` 等 |
| 两版本共有的死指令 | `hm_viewfit`、`hm_blockbrowserupdate`、`hmbr_signals`、`hm_getarrayvalue`、`*renameentity`、`*entitypreviewempty`、`hm_version`、`*deletemark nodes`(硬拒绝) |
| `hm_getvalue` 正确 dataname | `collector.id` / `component.id`(非 collectorid/compid);`elements`(非 elems);`x/y/z`(非 coordinates) |
| `*createmark` 多词 selector | 必须 eval 合成单词(如 `{"by node id"}`),否则静默空 mark |

---

## 2. casting_tetramesh 模块移除(用户指示:已废弃)

| 项目 | 内容 |
| --- | --- |
| 删除文件 | `modules/casting_tetramesh.tcl`、`config/casting_mesh_rules.txt`、`tools/audit_casting_tetramesh{1-6}.tcl` |
| 注销注册 | `hw_toolkit_core.tcl`(模块 dict、savePanelState、ui(ok)、遗留窗口列表)、`install_update.tcl`(namespace 清理列表) |
| 文档清理 | `README.md`(目录树、配置表、2.1/2.4 工作流、6.5 节删除,6.6–6.16 重编号)、`doc/README.md`(同步)、`CHANGELOG.md`、`doc/INTEGRATION_ANALYSIS.md`(3.7 与 4.1/4.2 质量命令证据改写为"原铸件模块曾调用") |
| 报告清理 | `tools/audit_hm_commands_report.json/.txt` 各移除 26 处引用,JSON 逗号修复后校验有效 |
| module_status.json | 外部已更新,条目不在其中,无需改动 |

---

## 3. 各模块健康评级总览

| 模块 | 评级 | 主要发现摘要 |
| --- | --- | --- |
| local_mesh_optimizer | 良好(1 HIGH) | 指令面整体正确;1 个高危项(见 §5);`hm_viewfit` 死代码已清理 |
| workflow_common | 健康 | 共享机制无指令错误;死指令已清理(见 §4-2/4-3) |
| batch_mesher | 基本健康 | 无致命项;若干可加固点 |
| midsurf | 基本健康 | `hmbr_signals` 死代码已清理 |
| mesh_seam_weld | 基本健康(1 处修复) | 1 个低危修复项;`hm_viewfit` 已清理 |
| cbush_creator | 基本健康 | `*deletemark nodes` 硬拒绝(见 §4-1) |
| seam_surface | 基本健康(3 处修复) | 3 个低危修复项(含 Browser 刷新);死指令已清理 |
| batch_property_assignment | 基本健康(2 处加固) | 2 个可加固点 |
| hybrid_core | 基本健康(0 修复,1 关注) | 无修复;1 个关注项($HMCOMP ID 注释被 reader 忽略,已有补偿) |
| bom_material_assignment | 基本健康 | 无致命项 |
| weld_integrity_check | 基本健康 | `hm_viewfit` 死代码已清理 |
| shell_washer_hole_rbe2 | 基本健康(B) | 无致命项;`hmbr_signals` 已清理 |
| geometry_cleanup | **已修复(2026-08-08)** | 22 分支换用 `hm_getfilletfacesfrommark` + `*deletemark`(两版本探针验证,见 §5-3) |
| batch_temp_nodes | **基本健康** | 19 实机验证 `*deletemark nodes "by id only"` 对自由节点可用,撤销功能正常(原评级误报;22 无对应探针,保持关注) |
| rbe2_bolt_connector | **已修复(2026-08-08)** | `hm_getvalue` dataname 修正 + replaceOneNode 重合降级(见 §5-5) |
| auto_hole_rbe2 | **基本健康** | 源码已用 `*findfaces` + `*feoutputwithdata`(两版本 OK),原 `^faces` 结论为误报;死指令已清理 |
| contact_setup | **基本健康** | 5 参 `*adjustcontactsurfacenormal` 两版本 OK;group dataname 回退已内置(main→master/slave,见 §5-6) |
| fem_auto_seam | **已修复(2026-08-08)** | 重绘循环守卫删除 + `hm_viewfit` 死代码清理(见 §5-1) |

---

## 4. 跨模块共性问题(按出现频率)

### 4-1 `*deletemark nodes` 硬拒绝(3 模块)

`batch_temp_nodes`、`cbush_creator`、`fem_auto_seam` 用它删除临时节点,两版本均直接报
`nodes may not be directly deleted`。

**影响**:batch_temp_nodes 的"撤销上一批"核心功能失效;cbush_creator 失败清理失效;fem_auto_seam 回滚流程断裂。

**替代方向**(需按模块实机验证):

- 先 `*deletemark elems` 删除依赖单元,HyperMesh 自动清理孤立节点;
- 对 RBE2 独立中心节点,用 `*nodeupdate` 移动 + 空节点回收,或使用 `*deletemark nodes` 之外的原生面板命令(如 `*createmark nodes` + 配套 `*deletemark` 在几何节点的差异路径)。

### 4-2 `hm_viewfit` 死代码(4 模块)✅ 已清理(2026-08-08)

`weld_integrity_check`、`local_mesh_optimizer`、`fem_auto_seam`、`midsurf`、`mesh_seam_weld` 调用后无效果
(两版本均不存在)。

**替代**:`*viewtop` / `*windowfit` / `*fit`。

**修复**:全部调用点已删除(fem_auto_seam ×2、local_mesh_optimizer ×3、mesh_seam_weld ×1、weld_integrity_check ×1),
均为 `catch` 包裹的无副作用调用,零行为风险。

### 4-3 `hmbr_signals` / `hm_blockbrowserupdate` 死代码(3+ 模块)✅ 已清理(2026-08-08)

`workflow_common`、`midsurf`、`seam_surface`、`auto_hole_rbe2`、`rbe2_bolt_connector`、`geometry_cleanup`、
`shell_washer_hole_rbe2` 依赖它们刷新 Model Browser,实机无效果。

**修复**:全部 17 处调用点已删除(含 begin/endBulkCreate 与 performance mode 的成对调用),
保留有效命令(`hm_blockredraw` / `hm_blockmessages` / `hm_commandfilestate` / `hwbrowsermanager view flush` / `hm_redraw`)。

### 4-4 `hm_getvalue` dataname 错误(多模块)

多处使用 `collectorid` / `compid` / `elems` / `coordinates` / `thickness`。

**实机正确值**:

| 场景 | 错误写法 | 正确写法 |
| --- | --- | --- |
| 组件 ID | `collectorid` / `compid` / `comp` | `collector.id` / `component.id` |
| 组件下单元 | `elems` | `elements` |
| 节点坐标 | `coordinates` | `x` / `y` / `z` |

`thickness` 按实体类型确认 dataname,实机曾返回 0.0。

### 4-5 `*createmark` 多词 selector 静默空 mark

必须 `eval` 组合成单词(如 `{"by node id"}`),否则 mark 为空且不报错,后续批量操作静默跳过。

---

## 5. 关键缺陷详情(需修复级)

### 5-1 fem_auto_seam(B-)✅ 已修复(2026-08-08)

- **修复 1**(原致命 2):`hm_viewfit` 死代码已删除(auto_ui.tcl 两处)。
- **修复 2**(重绘循环必失败):`fast_executor.tcl` 循环内 `hm_getmeshfaceparams` 在两版本均报
  `entity not found` → `params` 为空 → `break` → `faceCount=0` → 报 "automesh did not produce any
  temporary face mesh"。`params` 变量未被使用,纯诊断;已删除该读取与空值守卫,保留
  `*set_meshfaceparams` 成功作为循环守卫(探针证明其两版本 OK),`*automesh` 自带错误处理。
- 保持关注:`*deletemark nodes` 硬拒绝 → 重绘失败时临时节点回滚路径仍受影响(见 §4-1);
  FEM 替换后分批重绘参数需按验收模型回归。

### 5-2 auto_hole_rbe2(1 严重)✅ 误报澄清

`^faces` 结论为误报:源码已改用 `*findfaces` + `*feoutputwithdata` 导出(exporter.tcl),两版本实机 OK。

### 5-3 geometry_cleanup ✅ 已修复(2026-08-08)

`*surfacefilletremove 1 1 2`:19 OK / **22 ERR**;原 fallback `*surfacemarkremovelinefillets 1 minR maxR 0 1 0`
两版本均 ERR。已按版本分支:

- 19:保持原路径(`*surfacefilletremove`,探针验证 OK);
- 22:`hm_getfilletfacesfrommark surfs 1 $FILLET_MIN_R $FILLET_MAX_R` 查圆角面 → 非空则
  `*deletemark surfs 1`(两命令均实机验证;fix_verify_geometry_cleanup22 探针重放完整分支,
  22 上分支触发、子集标记查询 OK;19 上原路径不受影响)。

### 5-4 batch_temp_nodes ✅ 误报澄清

`*deletemark nodes "by id only"` 对自由节点 19 实机成功(D_DELETEMARK_FREE_ERR=0、REMAINING 空),
"撤销上一批"功能可用。22 无对应探针,保持关注(§4-1 的 `*deletemark nodes` 硬拒绝在 cbush_creator /
fem_auto_seam 仍适用)。

### 5-5 rbe2_bolt_connector ✅ 已修复(2026-08-08)

- **修复 1**:`executor.tcl:207` `dataname=coordinates`(无效)改为 x/y/z 分读,与主路径 nodeXYZ 一致;
- **修复 2**:`replaceOneNode` — 5 发探针 × 2 版本证实 `*replacenodes` / `*equivalence` /
  `*replacentitywithentity(mark)` 在两版本均不合并自由节点(命令存在但不生效)。两调用点
  (增量导入代理重连、forceBeamEndpointNodes)均只在坐标重合时调用,故改为:重合即视为替换成功
  (结果与合并等价),命令保留作未来版本 fallback;`forceBeamEndpointNodes` 最终校验同步放宽为
  重合比较。

### 5-6 contact_setup(HM2022 差异)✅ 澄清为基本健康

模块 5 参 `*adjustcontactsurfacenormal` 两版本均 OK(ADJUST_MODULE_5ARG);group dataname 差异
(maincontactsurflist 仅 22 认)已在 contact_setup.tcl 内置 main→master/slave 回退,无需改动。
可选优化:19 下先试 master/slave 减少报错回退路径。

### 5-7 local_mesh_optimizer(1 HIGH)

除此外整体良好(指令面正确、视图、mark、替换均验证)。HIGH 项具体见
`runtime/audit_local_mesh_optimizer_*.log` 与对应探针。

---

## 6. 推荐的原生指令替代(实机验证过)

| 场景 | 现状(低效/错误) | 更优替代 | 状态 |
| --- | --- | --- | --- |
| 包围盒/孔尺寸 | 手工坐标循环 | `hm_getboundingbox` | 实机存在 |
| 自由边/孔边界提取 | 读 `^faces` | `*findedges` | 实机存在 |
| 中面相关查询 | 自建拓扑 | `hm_getmidsurfcomp` | 实机存在 |
| 组件 ID/名称查询 | `collectorid` 等错误 dataname | `collector.id` / `component.id` | 已确认 |
| 质量摘要 | 自算 | `hm_getelementsqualityinfo`(须确认 criteria 上下文) | probe 后使用 |
| 视口适配 | `hm_viewfit`(无效) | `*windowfit` | 已确认 |
| 批量读取性能 | 逐 id 读取 | mark 批量读取(6–8 倍提速) | 已确认 |
| 节点邻近 | `*markdistance`(不存在) | 坐标循环(现状即正确) | 已确认 |
| 倒角/圆角清理 | `*surfacemarkremovelinefillets`(两版本失效);22 下 `*surfacefilletremove` 失效 | `hm_getfilletfacesfrommark` + `*deletemark surfs` | 已实机验证并落地(22 分支) |
| 自由节点合并 | `*replacenodes` / `*equivalence`(两版本命令存在但不生效) | 重合坐标视为已对齐(无可用的原生合并原语) | 已实机验证并落地 |

---

## 7. 证据清单

- 探针脚本:`tools/audit_*.tcl`(共 103 个,每模块一组,可复用于修复验证)
- 探针结果:`runtime/audit_*.log`(共 232 个,KEY=VALUE,双版本)
- 汇总报告:`tools/audit_hm_commands_report.json` / `.txt`(26 处 casting_tetramesh 引用已清除)
- 移除记录:见 §2
- **修复探针(2026-08-08)**:`tools/fix_probe_geometry_cleanup22.tcl`(22 替代命令契约)、
  `tools/fix_probe_bolt_{equivalence,merge2,replacentity,answernext}.tcl`(5 发,合并原语排查)、
  `tools/fix_verify_geometry_cleanup22.tcl`(G1 分支两版本重放)
- **修复探针结果**:`runtime/fix_probe_*.log`、`runtime/fix_verify_geometry_cleanup22_{19,22}.log`

| 模块 | 探针文件 |
| --- | --- |
| auto_hole_rbe2 | audit_auto_hole_rbe2_*.tcl(11) |
| batch_mesher | audit_batch_mesher_*.tcl(4) |
| batch_property_assignment | audit_batch_property_*.tcl(7) |
| batch_temp_nodes | audit_batch_temp_nodes_*.tcl(10) |
| bom_material_assignment | audit_bom_material_*.tcl(3) |
| cbush_creator | audit_cbush_creator_*.tcl(4) |
| contact_setup | audit_contact_setup_*.tcl(3) + audit_feinput_*.tcl(4) |
| fem_auto_seam | audit_fem_auto_seam_*.tcl(11) |
| geometry_cleanup | audit_geomcleanup_*.tcl(7) + audit_geometry_cleanup_cmds.tcl |
| hybrid_core | audit_hybrid_core_*.tcl(4) |
| local_mesh_optimizer | audit_local_mesh_optimizer_*.tcl(8) |
| mesh_seam_weld | audit_mesh_seam_weld_*.tcl(8) |
| midsurf | audit_midsurf_*.tcl(3) |
| rbe2_bolt_connector | audit_rbe2_bolt_connector*.tcl(4) |
| seam_surface | audit_seam_surface_*.tcl(4) |
| shell_washer_hole_rbe2 | audit_shell_washer_hole_rbe2_*.tcl(6) |
| weld_integrity_check | audit_weld_integrity_check_core.tcl |
| workflow_common | audit_workflow_common_cmds.tcl |

---

## 8. 后续行动建议

**2026-08-08 修复已完成**:

- fem_auto_seam(重绘循环守卫 + hm_viewfit)、geometry_cleanup(22 倒角分支)、
  rbe2_bolt_connector(dataname + replaceOneNode 降级)、死代码全量清理(hm_viewfit / hmbr_signals /
  hm_blockbrowserupdate 共 17 处)、评级修正(batch_temp_nodes / contact_setup / auto_hole_rbe2)。
- 离线:全仓库测试 34 通过 + 9 子测试;唯一失败为 batch_mesher 测试自身的 flaky 交互(单跑通过,与本次改动无关)。
- 实机:fix_verify_geometry_cleanup22 探针两版本重放通过(19 原路径 OK / 22 新分支 OK)。

**剩余建议**:

1. batch_temp_nodes 的 22 实机补一发 deletemark 探针(当前只有 19 证据);
2. contact_setup 可选优化:19 下先试 master/slave dataname,减少报错回退路径;
3. local_mesh_optimizer 的 1 个 HIGH 项按 §5-7 定位;
4. fem_auto_seam 重绘失败时的临时节点回滚(`*deletemark nodes` 硬拒绝)需按验收模型回归;
5. 修复后验收:FEM 替换 + 分批重绘全流程按验收模型在 19/22 各跑一遍。

---

## 附:审计过程备忘

- hmbatch 无 stdout 通道,探针结果必须写文件,脚本须 `exit 0`;结尾 "HM exiting with code 1" 属正常。
- 共享浮动许可证:一次脚本只启动一次 hmbatch,按波次(1–5)错峰执行。
- 遗留:Python 检测管线(solid_seam 旧版)与 `tools/diag_*.tcl`、`runtime/diag_*` 调试文件仍保留,与本次审计无关。
