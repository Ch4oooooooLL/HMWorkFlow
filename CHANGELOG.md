# HMWorkFlow changelog


## Unreleased - platform stabilization

- 主界面改为搜索式常用工作台：默认展示 6 个常用模块及最多 4 个非重复的最近使用模块，支持逐项收藏并将状态保存到 `%APPDATA%/HMWorkFlow/home.cfg`；搜索跨模块中英文名称、用途说明和详细说明。原先一次展开的 Geometry / Mesh / Connector 列表改为“几何准备、网格处理、焊缝、连接与载荷”业务分类页签，23 个可见模块均只归入一个主页分类。工具行精简为收藏、名称与一句话用途、快捷键状态、运行和更多菜单，设置/说明/快捷键移入更多菜单，标题栏 `?` 集中提供指南与诊断；底层模块 group、入口和快捷键配置保持兼容。

- FEM 自动焊缝 0.22 / 网格焊缝 0.71 优化大批量识别与创建稳定性：Python 并行识别默认使用最多 8 个可用核心，严格识别与宽松召回在每个 worker 内复用物理蒙皮、法向和空间索引缓存，不再重复构建；多 worker 的缺失源召回改为第二阶段全局合并，消除分区各自判断产生的额外 REVIEW 候选并保证 1/2/4/自动 worker 输出一致。可信种子创建保持 HyperMesh 安全串行，但每 10 条执行属性提交、瞬态选择清理、事件泵送与 PERF 检查点，逐条显示成功/失败数；长 Tcl 循环现在可在安全检查点响应取消，当前路径验证回滚后停止余下任务，取消不会触发尺寸重试或生成大量失败 Set。每条成功路径与整个批次记录耗时，便于定位单条慢焊缝。

- 批量赋予 Property 的失败复核从单一 `PROPERTY_ASSIGNMENT_REVIEW` assembly + 空 component 名称副本改为按稳定错误码创建 `PROPERTY_ERROR__<错误码>` component set，set 直接引用原 component，不复制/移动内容且不再创建或修改任何 assembly。名称错误细分为版本前缀、件号缺失、焊缝/普通厚度缺失、厚度非法、材料字段缺失和通用格式错误；运行错误细分为材料创建、Property 卡片、创建/查询、材料与厚度写入/校验及最终赋予校验。结果字典同步输出结构化 failure、成功 set 清单与 set 写入错误，完成提示显示错误码与 set 数量。

- 网格焊缝 0.70 将手动批次的 `SOURCE_PLAN` 失败改为任务级隔离：某组节点/目标组件在原生自由边创建、闭环识别、三点路径排序或源组件校验阶段失败时，记录带 `selection_pair_index` 的失败项并直接跳过，继续规划和执行后续 selection pair，不再让整个批次进入致命失败分支。规划失败不修改焊缝网格，按 `rollback_ok=1` 记录；最终报告、日志和完成提示分别统计输入任务、可执行路径、SOURCE_PLAN 跳过数、执行失败数与成功数。撤销初始化、工作区等批次基础设施失败仍保持整批终止。

- 网格焊缝 0.69 重定义手动多点边界输入：取消“两点自动取闭环较短弧段”，每条开放线段改由三个有序节点确定——第一个和第三个为端点，第二个为所需弧段上的途经点，因此不再依赖长度猜测闭环方向；两个相连节点会提示改选三点。恰好输入两个彼此不相连的边界节点时，改为强制提取并投影它们各自所在的完整闭合边界，同一闭环自动去重。支持按连续三元组一次定义多段，且校验每组三点属于同一闭环。新增正反两侧途经点、跨闭环拒绝、双闭环强制投影和同环去重回归。

- 网格焊缝 0.68 放宽贴片型闭合边的目标角度门禁：平面闭合自由边投影到斜面或局部不平整的目标组件时，不再因超出 `parallel_angle_max` 被提前驳回；只在闭合边平面与目标局部面达到 `perpendicular_angle_min`（默认 70°）时拒绝。其余近似贴片直接进入现有逐路径 HyperMesh history 事务尝试创建，原生命令或后续结构校验失败仍完整撤销。新增平行、45° 非平行放行与 90° 垂直拒绝的离线回归。

- 网格焊缝 0.67 修复原生局部重剖分后因“Structural boundary changed … original attachment node … lost its boundary attachment”被误回滚的问题。默认创建优先模式不再要求母板局部边界逐节点、逐边保持旧拓扑身份；边界链被 HyperMesh 合法重新剖分时记录 WARN，继续以面积、重复面、壳几何可用性和焊缝实际共享连接验收结果。显式开启 `strict_patch_boundary_check` 仍执行逐边守恒检查。新增对照回归验证：局部平滑重剖分可创建，严格模式仍拒绝，真实删除 50% 母板面的案例仍由面积守卫回滚。

- 网格焊缝 0.66 消除 `AUTOMESH` 对旧附件节点 ID/坐标守恒的整类误拦截。现场 0.65 已能接受既有焊缝壳重建，但合法的原生网格平滑会让外圈快照节点既没有旧 ID、也没有完全同坐标的新 ID，仍以 “Structural attachment node … disappeared without an exact-coordinate replacement” 回滚。现在单节点消失、重编号或移动均为诊断 WARN，不再单独决定成败；验收统一依据重绘后的结构边界、面积、重复面、壳几何可用性以及焊缝与母网格的实际共享连接。只有最终拓扑确实缺面、断开、重复或塌陷才回滚，避免继续出现同类旧实体身份误判。

- 网格焊缝 0.65 修复普通 T 型焊缝在 `AUTOMESH` 阶段被“Existing weld mesh was modified / lost element”“Structural attachment node disappeared”和“boundary node coordinates are unreadable”误拦截的问题。HyperMesh 的原生 `remesh_layers` 会越过输入 mark 的组件边界，合法地以新 ID 重建邻接 `SEAM_*` 壳及局部边界节点；旧逻辑在完整拓扑验证之前强制要求既有焊缝单元和受保护节点保持原 ID，因此将正常局部重绘当成结构损坏并立即回滚。现在仍从请求的重绘 mark 排除既有焊缝单元，但若原生邻接重绘替换了单元或在原坐标重编号了节点，只记录 WARN 并继续执行边界、面积、重复面、几何可用性和母网格附件验证；边界比较可使用重绘前的坐标快照，不再查询已经删除的旧节点 ID。结果拓扑完整则保留新焊缝，真正缺面、节点被拖离、断开、重复或塌陷时仍回滚，贯彻“创建优先，检测服务于创建”的策略。

- 网格焊缝 0.64 补上 by-adjacent 扩展层与既有焊缝保护的执行逻辑。① 扩展层（`patch_expand_layers`，imprint 局部重绘扩展层数，默认 2）：此前该设置只影响补片标记与旧路径，原生 Create Patch 的 `*imprint_nodelist` 被硬编码为 `remesh_layers 0`——对底面网格只做切分、不做 imprint 自带的质量重绘，焊缝与底面交界处的周边网格畸变严重；现在 create-patch 分支按 `remesh_layers <配置值>` 传入（0 保持纯切分），`expandTargetElementPatch` 取消 2–3 层钳制、按配置扩张补片标记（层数越大影响区越大、耗时越长），并写入 `autoJsonSettings` 随自动流程下发、随失败报告与导出清单输出。实机 HM2019.0.0.70 探针 `tools/audit_mesh_seam_weld_remesh_layers.tcl`：layers=0 时影响区内仅 41/176 个单元被重绘（接近纯切分），layers=2 时 225/276（两圈质量重绘），layers=4 时 384/384。② 既有焊缝保护（`allow_break_existing_weld`，默认关闭，「是否允许对现有焊缝网格单元进行增删」）：此前只把 `SEAM_*` 单元从重绘 mark 中剔除并假定成立，而扩展重绘环会按相邻关系越过 mark 触及旁边一行的既有焊缝条带——探针 C 例中相邻 SEAM 条带 48 个单元被原生重绘替换 43 个，模块没有任何报错；现在 `validateStructuralMesh` 路径开始时执行 `protectedWeldElementsChanged` 强制校验：保护开启时，快照范围内每个焊缝组件的既有壳必须原 id、原连接存在，否则整路径回滚（顺带验证回滚），并给出「开启 allow_break_existing_weld 或减小扩展层数」的可执行提示；保护关闭时恢复旧行为（D 例：相邻条带被重绘 43/48 且路径成功）；两行之外的既有条带（E 例）完全不受影响（48/48 原样，无误伤）。该拦截计入 `weldFailureIsStructuralDamage`，不再做无谓的尺寸重试。③ 设置均在面板（手动模式）与 `stateKeys` 中，`patch_expand_layers` 校验为非负整数；新增回归：`test_native_patch.py`（create-patch 选项携带 `$cfg(patch_expand_layers)`、不再硬编码 `remesh_layers 0`）、`test_existing_weld_protection.py`（by-adjacent 环数跟随配置 0→1 环、2→2 环、4→4 环）、`test_mesh_safety.py`（保护开启时既有焊缝单元丢失/连接被替换即拦截、开启 `allow_break_existing_weld` 后放行、按结构性破坏分类），全套 228 项离线测试通过，`hm2019_mesh_safety_smoke.tcl` 与其余实机探针继续 PASS。④ 探针备注：HM2019 的原生 `*imprint_nodelist` 一旦经 Tcl wrapper 调用即不透明失败（返回 0），模块本身不包装该命令；本条目引用的实机证据均在不包装原生命令的前提下取得。

- 网格焊缝 0.64 修复结构几何守卫把「可用但畸形的局部重绘单元」误判为网格损坏、整条焊缝被拦下的问题（2026-09-10 现场：同一批次 4 条路径中 3 条在 AUTOMESH 阶段以 `Near-collapsed shell corner` / `Folded, twisted or self-intersecting shell` 失败，0.6×/1.5× 尺寸重试仍失败并 `imprint_kept=0`，而同一位置手动 Create Patch 完全正常、HyperMesh 不报任何错误）。① 根因：patch 是固定源轨驱动的受限重网格，HyperMesh 必须按源轨形状闭合单元——闭合自由边环在粗网格上逼出 179° 平角壳（命中原 1° 夹角阈值）、源轨 0.02mm 节点对逼出 0.02mm 边（命中原 100 长宽比阈值）、密轨逼出凹壳（凹角处角点法向指向另一侧，命中原 45° 法向差阈值）；这些壳有真实面积、可承载，是重网格的合法输出而不是网格被毁。② 修正（`modules/mesh_seam_weld/tcl/mesh_safety.tcl`）：`shellGeometryAudit` 现在只把「没有可用几何」判为错误——连接塌陷（节点号重复/壳节点数非 3/4）、重合节点或零长边（含对角重合，容差取自身最长边的 1e-9）、零面积壳（全部节点共线，面积 ≤ 自身最长边平方的 1e-6）、以及边界自交壳（四边形对偶边在自身最佳拟合平面内真正交叉，Newell 法向求和为零时回退到最大角点法向；凹角/一个角点法向反向只是质量告警，不再视为自交）；针状角（含 <1°）、长宽比 >20、凹角、翘曲 >30° 全部降为 WARN，每条路径一条告警并附最差长宽比与最偏角（度），焊缝照常保留——与模块自身注释和 0.63 文档「只把网格确实被毁判为失败」的既定口径一致，此前实现把质量阈值当成了塌陷阈值。③ 实机回归：新增 `tools/audit_mesh_seam_weld_geometry_audit.tcl`（HyperMesh 2019.0.0.70 独立 hmbatch）：修复前精确复现现场两类报错（20 节点闭合环 + 粗板 → 179° 平角壳「Near-collapsed shell corner」，实测 metrics 记录于 `runtime/msw_geometry_audit_probe.before_fix.log`），记录模式下同一路径全部创建成功；修复后直轨/0.02mm 节点对/密轨/闭合环等 9 例全部 `ok=1 rollback_ok=1`，畸变按「distorted but usable（worst aspect / worst corner）the weld is kept」告警输出；`hm2019_mesh_safety_smoke.tcl` 继续 PASS（目标光晕不越界、注入失败完整回滚、重复焊缝安全拒绝）。④ 离线回归：`test_mesh_safety.py` 把原「bowtie/concave/warped/sliver 全部拒绝」拆成「几何销毁仍拒绝」（自交边界、共线零面积、重合节点）与「畸变壳放行并告警」（1° 针角、长宽比 2000、凹壳、强翘曲、179° 平角），并新增焊缝级 needle 放行 + 告警、自交焊缝壳拒绝两个回归；网格焊缝全套 223 项与 FEM 自动焊缝离线测试通过。⑤ 说明：pytest 在短时间内反复新建 Tcl 解释器时会出现与本修复无关的 `couldn't read file …: No error` 偶发（同样出现在未修改的 `test_existing_weld_protection.py` 上），仓库既有官方入口 `modules/mesh_seam_weld/tests/run_tests.py`（unittest）稳定通过。

- 网格焊缝 0.63 与 FEM 自动焊缝修复 T 型主焊缝漏识别、漏创建，以及竖板与底面网格被破坏、扭曲、重复的问题；创建策略定为“创建优先、只在真正破坏母板网格时拦截”。① 识别：同一目标面上共享节点的短碎片不再被当作“该链已上报”而压掉更完整的路径，覆盖率 ≥ 0.98 的完整主边按真实边序（含与相邻边共用的角点）交付，并替换同一目标上被它包含的短碎片行；重复路径改按“目标组件集合 + 源边集合包含”判定（`_same_target_path_contains`），相邻边共用节点不再被误判为同一焊缝。② 交付：召回优先与 `submit_all_weld_candidates` 恢复为高召回交付，覆盖率、投影跳变、法向跳变、蒙皮误差、断口等只是容差证据，不再压制用户已判定的可焊位置；仅“会建错或建重”的证据仍然保留在待复核中——目标歧义、多目标不确定、非流形区域、法向不一致、内边界源、过短以及已有焊缝（`duplicate_status` 非 `NEW`）。③ 目标范围：imprint 前对 by-adjacent 光晕再执行 `constrainTargetShells`，光晕不再把竖板/翻边拉进重绘范围。④ 失败重试：AUTOMESH 阶段失败（焊缝条带质量、patch 附件、非流形 patch、重绘为空）会自动用调整后的焊缝网格尺寸（`weld_mesh_size` 的 0.6× 与 1.5×）重试两次，每次都在独立撤销事务中执行并校验，只有回滚已验证、输出组件已清理时才继续；IMPRINT 失败仍走原有局部 T 型兜底，事务失败不重试。⑤ 结构网格守卫（新增 `modules/mesh_seam_weld/tcl/mesh_safety.tcl`）：`validateStructuralMesh` 与路径前的结构快照比对，只把“网格确实被毁”判为失败——面被删除/出现破洞或横向改接、组件壳面积变化超过 15%（2% 以上仅告警）、本路径新增的同连通或几何重合重复壳、单元塌陷/夹角小于 1°/长宽比大于 100/两三角面法向差超过 45°、跨组件共享节点与源轨节点被拖动超过局部网格尺寸的 1/4（更小仅告警）、焊缝条带完全没有边界边落在母网格上、或某条导轨仅坐标重合却与母网格不共享节点；自由的边界节点被重编号但坐标不变时按原节点归一化后再做附件判定，原地细分、曲边细分、自由端、重绘产生的轻微畸变与面积漂移都不再拦截。校验不依赖用户当前 HyperMesh 质量准则（HM2019 未加载 criteria 时 `hm_getelementsqualityinfo` 会终止会话，该路径不再调用）。⑥ 非流形与源轨：重绘前后的三所有者边在默认宽松模式下按 mod-2 外边界保留并写 WARN（与手动流程一致），仅在 `strict_patch_boundary_check` 开启时拒绝；原生 Create Patch 重构源轨只记 `native_rebuilt` 警告，不再因此拒绝已成功的原生结果。⑦ 回滚与拦截说明：取消 `KEEP_IMPRINT` 保留语义，失败路径连同 imprint、目标重绘与焊缝单元一并撤销，并按路径快照校验组件单元 ID、单元连接与节点坐标；撤销条数按“本路径开始前的撤销栈仍是当前栈的栈尾”计算（`pushedUndoActionCount`，同名重跑不会被误判为 0 条），本路径未压入任何撤销项时只做校验、不调用 `*undohistorystate`（HM2022 上失败的 `*imprint_nodelist` 不记录撤销项，旧实现会把上一条成功焊缝撤销掉），未启用 Tcl 撤销记录时拒绝开工，回滚无法验证时报 `rollback_ok 0` 并中止后续批次；失败结果新增 `block_kind`（`structural_damage` / `creation`）与 `PERF ... block_kind=` 日志，`diagnoseFailure` 对结构性拦截给出中文/英文原因与“这是创建算法需要修正的问题”及可用的临时绕行方式，使拦截成为算法改进项而不是死路；结构性判定按错误文本分类（结构边界改变、结构面积变化、结构重复壳含 `Duplicate structural shell`、附件节点缺失或被拖动、焊缝条带与母网格断开、回滚无法验证），其余失败一律按创建性问题重试。⑧ 回归：`test_mesh_safety.py`（24 项：结构面缺失/重复/重合、附件节点移动、自由边界重编号、几何退化、事务回滚、撤销条数边界，以及创建优先策略——AUTOMESH 失败按 0.6×/1.5× 调整尺寸重试并在第三次尝试成功、结构性损坏只报告不重试且给出可执行的算法修正说明、未配置焊缝网格尺寸时不重试、重试回滚无法验证时立即停止并报 `rollback_ok 0`、结构性与创建性失败文本分类）、`test_delivery_safety.py`（高召回交付与“会建错/建重”拦截对照）、`test_native_patch.py`（宽松三所有者边保留、严格模式拒绝、源轨重构仍创建）、新增实机冒烟 `modules/mesh_seam_weld/tests/hm2019_mesh_safety_smoke.tcl`（目标光晕不越界、注入失败后完整回滚且模型逐字段一致、同一导轨重复焊缝安全拒绝），HM2019.0.0.70 与 HM2022(22.0) 均 PASS；网格焊缝 220 项、FEM 自动焊缝 71 项离线测试全通过。文档见 `doc/native_patch_validation.md`。

- 网格焊缝 0.62 新增“是否允许破坏已有焊缝网格”设置（`allow_break_existing_weld`，默认关闭）。关闭时，imprint 的 `by adjacent` 光晕会跨组件边界碰到相邻 `SEAM_T*` / `MESH_SEAM_WELD*` / `^MSWE*` 焊缝壳，这些单元现在按组件归属从重绘 scope 中剔除，路径改用剩余目标壳继续执行；已有焊缝仍通过共享节点参与局部重网格（节点可随周边网格微调），但其单元不会被删除、切分或替换。过滤同时作用于 `expandTargetElementPatch` 的原生 `by adjacent` 结果与 Tcl 兜底遍历，以及 `markRefreshedLocalTargetElements` 在目标组件过滤之后再叠加的一层（覆盖 `SEAM_*` 组件本身被选为目标的情况）。每次剔除写 WARN 并给出 removed/kept 计数，patch 日志新增 `protected` 字段；若剔除后只剩焊缝单元则按暂存错误中止该路径，不再静默重绘焊缝。开启该项恢复原有行为。该键经 `stateKeys` 持久化、经 `autoJsonSettings` 与 `AUTO_DEFAULTS` 同步到自动流程。新增 11 条离线回归（焊缝/普通组件识别、`PANEL_SEAMLESS` 不误判、默认剔除、开关放行、全焊缝 patch 报错、原生光晕集成）。文档见 `doc/native_patch_validation.md`。

- 节点补片 1.1 取消“只能选 3 或 4 个节点”的限制：补片边界现在接受任意 3 个及以上按周长顺序点选的角点，四边形以外（五边形、多边形、多段包围轮廓）不再被入口直接拒绝，原有“有序角点 → 相邻角点成边 → 优先复用真实边链、缺失时追踪重构 → 耳切三角化”的基本逻辑保持不变。为控制多边界的开销，追踪与边链搜索上限由固定值改为按边数分配：3/4 条边完全保持原值（每条边 10 个单元的追踪上限、120 个搜索状态），边数更多时每条边的额度按比例下降且不低于 1，整体预算不低于原绝对值；容差判定用的网格尺度改为由全部角点邻域的中位边长效一次计算，不再受边数与各边长度差异影响。边界角点总数上限新增可配置项 `max_boundary_corners`（默认 50），超出时报 F01；不足 3 个角点、重复角点或角点不属于 TRIA3/QUAD4 壳的原有校验保持不变。UI 按钮与状态文字同步更新。离线测试新增更多角点数量校验、按边预算分配，以及 4/5 角点在 3×2 壳块上的逐边分析回归。

- 网格焊缝 0.61 调整失败语义为“保留 imprint、不保留焊缝网格”：Native Create Patch 成功后若 AUTOMESH 阶段失败（重网格非空或连接-边界/流形校验失败），不再撤销整条路径，而是删除本次路径新增到焊缝组件的全部焊缝单元（失败重网格产生的新单元一并清理），保留目标面 imprint（局部重网格、imprint 节点/边）供手动继续创建。失败带 `KEEP_IMPRINT` 错误码，`processWeldPathIsolated` 据此提交该路径 history state、不回滚整体，也不在保留的 imprint 上尝试局部 T 降级重试；焊缝单元清理自身失败时仍回退到原有整路径回滚。失败报告新增 `imprint_kept` 字段，完成提示与非流形失败诊断说明保留了多少条 imprint。新增“失败清理焊缝单元但保留 imprint、history 提交不 undo”的回归测试。

- 网格焊缝 0.60 修复 Native Create Patch 的临时三单元共边在重网格后仍被严格流形检查整路径回滚的问题：实机 T 型接头中 `*defaultremeshelems` 并不会规范该原生拓扑（重网格前后为同一对节点、3 个单元共边），而手动执行同一 Native Create Patch 结果可用。AUTOMESH 的最终边界提取现在遵循 `strict_patch_boundary_check`：默认宽松模式对残留非流形边写 WARN 并按单元所有权奇偶关系提取 mod-2 外边界（保留与手动流程一致的原生焊缝），严格模式仍整路径拒绝；连接边位移、原边界节点丢失等附件校验保持 fail closed。新增持久三单元共边宽松保留/严格拒绝回归测试。

- 网格焊缝 0.59 修复 Native Create Patch 中间结果因局部三单元共边而在 AUTOMESH 开始前被误拒的问题：重网格前允许原生 patch 的临时非流形边，并按单元所有权奇偶关系提取实际外边界，使 isolated mixed remesh 有机会规范该局部拓扑；重网格后的焊缝仍执行严格流形检查，最终结果若继续存在三单元共边仍整路径回滚。新增临时三所有者边的边界提取与最终严格拒绝回归测试。

- 网格焊缝 0.58 完善手动单点选边：单点自由边现在结合所选目标面局部法向分类。完整闭合轮廓仅在其平面与目标面平行时作为贴片焊缝；否则按所选点所在特征重新截取，直边只保留大折角之间的当前直线段，曲边保留连续曲线并在不超过 45° 的大折角处截止。若整段连续曲边可形成平面且该平面与目标面垂直，则在任何网格修改前拒绝创建。新增闭合贴片、简单 T 型直边以及垂直平面曲边拒绝的离线回归测试。

- 网格焊缝取消对 Native Create Patch 成功结果的源侧逐边同一性误拒：HM2019 的 `create_joint_elems=1` 会合法重构源侧连接轨，原输入的相邻节点对不保证继续作为某个新壳单元的直接边存在；0.56 新增的逐边硬校验因此把 64 节点开放 T 路径及 18 节点闭环等可创建输入误报为 `source attachment edge ... is absent from the native patch` 并回滚。现在源轨差异仅写入 WARN 诊断，以原生命令成功且新增 patch 非空为源侧创建依据；新 patch 重网格非空及外部连接边界保持校验继续作为硬门禁。模块版本更新为 0.57，并新增原生源轨重构仍保留焊缝结果的回归测试。

- 网格焊缝单点选择的简单 T 型接头增加闭环降级路径：当所选自由边节点因默认 180° 折角上限扩展成零件整个闭合外轮廓，而 HM2019 对该长闭环 `*imprint_nodelist` 仅返回不透明错误 `0` 时，先完整回滚失败操作，再从同一个选中节点沿源边界提取首个真实拐角之间的局部平滑特征边（自动上限 45°），以开放 T 型路径重试一次。平滑圆环、角点选择、非 `0` 错误、回滚或清理不确定时均不自动缩短路径，避免把真实闭环悄悄改成局部焊缝。新增失败回滚、局部边提取和二次事务成功回归测试。

- 网格焊缝 Native Create Patch 支持闭合源环不属于新 patch 外边界的合法拓扑：此前一律要求每个源节点都是 patch 外边界节点，导致闭合 T/PATCH 环带虽已由 HyperMesh 创建，仍在首个源节点处报 `Native patch misses source boundary node`，整批同类焊缝全部回滚。现在把外边界与输入源节点一并加入重网格固定节点，并把源轨重构差异记录为诊断；新 patch 非空、重网格非空及外部连接边界保持仍为硬门禁。性能日志新增 `source_attachment=boundary|native_rebuilt`，新增非外边界闭环成功回归测试。

- BatchMesher 2.8 改为“网格输出优先、校核报告跟随”：只要目标面任务实际生成了单元，即使原生命令返回非致命诊断、质量 criteria 未满足或新增网格存在多个节点连通区域，也保留该任务的全部新增单元并参与 HM/FEM 封装及最终合并，不再因跨边界连通性校核直接判失败而丢失输出。任务新增 `validation_status`、`review_findings` 与汇总计数，`result.json` 新增整次运行的 `validation_result`、待复核任务数和发现项数；完全未生成单元以及 worker/封装基础设施失败仍保持失败语义。离线回归覆盖断连网格保留输出及报告序列化。

- FEM 自动焊缝识别按现场反馈补全召回并修正误报：① 两个 component 已在网格上连续（链级共享 GRID 节点，`mesh_continuous` 判定共享数 ≥ `max(min_continuous_nodes, ratio × 链节点数)`）时属于同一连续网格、FEM 已在该处传力，不再作为焊缝 target 产出候选，组件级 `ignore_shared_nodes` 兜底同样受此约束；② 严格扫描对一条自由边链只报出端部擦碰的短碎片（受支撑边占比 < `t_recall_min_coverage`，默认 0.5）时，该链以放宽包络重扫（部分链补扫），补扫行须达到同一覆盖率下限并按 ≥50% 节点重叠与严格行去重——端部碎片不再掩盖真实接缝，真实断口也不会被重新粘成一条连续缝。回归语料新增 TC049_mesh_continuous_seam（共享 GRID，真值 `no_candidate`，实测 0 候选；移除该判定即产出 1 条 AUTO）与 TC050_generalized_t_beside_square_t（同一腹板上 60° 斜交广义 T 与方形 T 并存，W01/W02 AUTO + W03 端边整链 REVIEW 多目标；关闭召回模式后该链完全不产出）。语料扩至 50 原子 + 4 复合 = 54 案例、177 期望焊缝（AUTO 131 / REVIEW 42 / REJECT 4）、72,078 节点 / 63,379 单元 / 290 组件，一键流水线 ALL_GREEN（generate 54、FEM 校验 54/54、几何校验 54/54 与 0 findings、回归 54 PASS / 0 FAIL，候选 465 行 / AUTO 146 行，失败类别全零，19 条 known-gap / tolerated 信息项不变）；模块离线测试 60/60 通过，断言按召回优先契约更新（每条夹具恰有一条 AUTO 行，召回补扫行必须保持非 AUTO）。

- FEM T 型候选识别扩展到斜面及长曲面构成的广义 T：高召回扫描从原 65°–115° 法向窗口扩展为无向 20°–90°，因此原始 40°/140° 等斜交关系同样保留，同时排除 0°附近共面贴片边界；独立网格/曲面接触允许一个局部网格尺度的切向残差，分段边只需存在有效采样命中即可成为候选，最短焊缝长度也只作为诊断而不再阻止识别。候选统一提交 Tcl，最终可创建性由 Native Create Patch 决定。

- FEM 自动焊缝取消识别结果的 REVIEW 交付闸门：所有带有效源边节点和目标组件的 T/PATCH 潜在候选，无论置信度、角度、间距、覆盖率、内边界、目标歧义或重复提示，均直接作为创建种子提交 Tcl；这些判据仅保留为诊断信息，不再否决创建。焊缝网格创建继续统一使用 Native Create Patch。

- FEM 自动焊缝暂时切换为现场验证所需的“召回优先”识别机制：正常精确检测无结果的源组件会自动进入第二遍高召回补扫，放宽独立网格边界的切向错位与单边采样覆盖率，并排除已有正常反向关系；补扫候选直接选择主目标送入创建队列。创建端保持不变，手动与自动 T/PATCH 焊缝网格统一使用已验证的 Native Create Patch。

- 优化 FEM 自动焊缝识别：T 型改为严格的候选边局部判定，完整受支撑子链不再被源组件其余外轮廓、远端分支或平滑整体曲率连带否决；接触包络按目标 Physical Skin + 竖板半厚 + 坡脚/坡口余量计算，厚板包络允许超过固定搜索距离，厚度放宽只作用于法向间隙、不扩大目标面平面内捕获范围。目标筛选按整条边的材料占比去除仅命中两个端点的侧壁/支架干扰，同时保留沿边持续存在的叠层目标歧义。T 型角度使用界面 `perpendicular_angle_min`（默认且含边界为 70°），成形件源法向分段阈值为 45°。贴片默认输出合格外圈及大开口内圈，小型紧固件孔只跳过自身。当前 FEM 自动焊缝模块 57 项离线测试全通过；旧 V2 语料中的 REVIEW 基线仍按原保守规则记录，因此策略放宽项不再作为当前 AUTO 真值。

- FEM 焊缝识别 V2 回归语料与「召回优先」现场策略对齐，一键流水线达到 52 PASS / 0 FAIL / status ALL_GREEN：三条旧基线按新策略重标真值——TC022 斜腹板 55° 广义 T 由 REJECT 改为 REVIEW `ANGLE_BORDERLINE`；TC030 投影跳变两侧各自独立 AUTO（仍禁止融合成一条连续缝 `MULTI_TARGET_CONTINUOUS`）；TC037 35° 倾斜板由 PATCH/REJECT 改为广义 T REVIEW `ANGLE_BORDERLINE`。语料新增 `tolerated_candidates` 机制，把召回包络允许、但解析几何不构成真实焊缝的多识别行（CM001 四道隔板端边贴侧壁、纵骨端边贴 DIA_4）显式登记为信息项而不是 FAIL（语料根汇总为 `ground_truth_tolerated.csv`）。回归报告全部失败类别归零（False AUTO / missed AUTO / wrong target / wrong type / wrong subchain / unexpected candidate / duplicate / support-run / missing reason / forbidden 违约均为 0），另如实上报 19 条 known-gap 信息项：TC024 distractor 歧义过严、TC033/TC048/CM001_W_DIA3_BOT 近皮假焊落入接触包络、TC042 连接端边被拆成两段短支撑，以及 CM001 的 9 条贴壁容忍行。

- 新增 FEM Weld Recognition V2 对抗性确定性回归语料：`examples/validation_weld_recognition_v2/`（版本化验收 fixture）+ `tools/weld_recognition_fixtures/` 生成/校验/回归工具链。48 原子（TC001–TC048）+ 4 复合（CM001 箱轨 / CM002 对抗合并 / CM003 全语料 / CM004 性能）共 171 期望焊缝（AUTO 127 / REVIEW 40 / REJECT 4）、9 forbidden，跨 70,168 节点 / 61,719 单元 / 280 组件。Ground truth 由解析几何推导、从不调用识别器；无随机数、逐位可复现；只生成真实 HyperMesh 自由场卡片。一键 `run_all_pipeline.py` 串联 generate → FEM 结构校验（52/52）→ 解析几何校验（52/52、0 findings）→ 识别回归（52 PASS / 0 FAIL，status ALL_GREEN，失败类别与 known-gap 见上条）。建库中发现并修复复合合并 ID 块冲突（>1000 节点案例覆盖相邻块 → 全局重映射）与同源组件多链焊缝 source_path 覆盖问题。`.gitignore`/`repository_audit` 白名单扩展至新语料目录。报告见 `docs/weld_recognition_v2_corpus_report_2026-09-09.md`。

- FEM 自动焊缝 Python 识别核心按 V2 Spec 升级：从 Component Pair/中面射线判定改为有序真实自由边链、CTRIA3/CQUAD4 精确三角面投影与考虑 PSHELL 厚度、Element ZOFFS、Ti 的 Physical Skin 证据；同一 Source Chain 可恢复跨多个 Target Component 的连续 `support_runs`，连续拼板保持一个 AUTO Job，叠层竞争目标、孔洞/断口、部分覆盖、角度边界、投影跳跃、曲面与非流形风险通过 Hard Gate 降为 REVIEW，不再由总 confidence 决定 AUTO。PATCH 内边界默认 REVIEW。Python 继续向 Tcl 交付原有 `trusted_seeds` 与 `potential_groups` 两类结果，并新增兼容的 `weld_recognition.json`、`recognition_summary.json`、`recognition_debug.csv` 证据产物；Tcl 现有 nodes + target components Mesh Editor 创建接口不变。

- 网格焊缝手动模式的单点边界种子改为按折角限定的完整边界展开：不再用目标最近壳单元的局部法向筛选「与目标平面平行」的边段，而是从所选边界点沿该源 component 的原生自由边图双向行走，把经过该点、相邻两段方向夹角（折角）不超过新增面板参数 `boundary_bend_angle_max`（默认 180°，仅手动模式可见，合法范围 0–180）的连续边界整体作为 nodes 输入——只要不折回上一段，直线、曲线、直角与钝角拐角都认定为同一条边界。分叉节点取折角最小的延续；两侧同样最直（含对称 Y 形分支）、坐标不可读或零长边时整条路径报错（fail closed）。开放边界从较低端点起序、闭合边界从种子起序，与既有单点流程一致。目标法向查询链路（`localTargetNormalsAtSourceNode` 及其最近节点/局部壳法向推导）随之删除，单点边界识别不再依赖目标侧几何；PERF 规划模式字符串改为 `bend-limited`。新增分叉最直延续、对称分叉拒绝、折角上限裁剪、内部点不查询目标法向回归测试。

- 网格焊缝手动模式放宽 Create Patch 重网格的连接边校验并改为可配置：实机出现"重网格前后连接边集合不完全一致"整路径回滚的误拒（remesh 在长边界边上插入固定节点做合法细分也会被旧逐边完全一致校验拒绝）。默认改为"附件保持"判定，按拓扑 + 最近边归属校验：原 patch 每条连接边要么原样保留、要么由仅含新插入节点的边界链取代，每个插入节点必须仍以它所细分的原边为最近原连接边，重绘后不得出现原附件之外的边界边。曲边导轨上的合法细分因此被接受——HM 2019/2022 在曲边弦的原弧中点插入节点，节点落在曲线上、偏离原弦约弦长的 2.2%（本机实测 0.366–0.377 mm / 16.9–17.4 mm 弦，R=97/100 同心圆环），旧实现"细分节点必须落在原边直线段上"的共线容差（1e-3×弦长）会把它误判成附件被移动并整路径回滚。任一原连接边被横向改接、原边界节点丢失、区域缺失或坐标不可读时仍整路径回滚（fail closed），失败信息附带具体诊断（如 `inserted node 38 does not belong to attachment edge 1-3`）与前后边界边数。原"重绘前后连接边集合完全一致"行为保留为面板设置项 `strict_patch_boundary_check`（默认关，仅手动模式可用），失败报告记录该校验模式，AUTOMESH 诊断建议提示可关闭严格模式重试，PERF 日志新增 `boundary_check=strict|relaxed`。新增曲边细分通过、插入节点错轨拒绝、横向改接拒绝、严格模式，以及 HM2019 实测边界回放（同心圆环条带 38 节点 / 20→38 条边界边）回归测试。

- FEM 自动焊缝识别性能与规则修复：① 识别性能重构——检测上下文改为 T/贴片两遍共享的懒加载缓存（单元列表、AABB 网格、三角形求交预计算数据、平均法向、面积、闭环自由边均按组件首次使用时构建），T 候选新增逐边扫掠包围盒对目标单元索引的宽相位预过滤（扫掠范围是候选目标的保守超集，候选集逐字段不变），按参数缓存命中查询，并行 worker 经 spawn 初始化器共享同一份上下文；6×6 应力基准（108 组件/约 6 万单元）串行识别 38.4 s → 8.6 s（约 4.4×），候选结果逐字段一致。② 贴片方向与包容判定重做——以按闭环的双向包容证明取代组件总面积定向（一个组件承载多块贴片时总面积会翻转投影方向，出现大 component 向小 component 投影），洞与外环改为投影平面上的几何分类（候选洞的全部顶点落在容器内且面积严格更小才算洞，只测单个顶点会把重叠贴片互相误判为洞）；洞环与外环一样参与焊缝识别——孔周自由边与最外侧边界一样落在目标上，单独产出焊缝行，仅等效直径低于自动孔径上限的紧固孔跳过；歧义降级只看 source 投影到多个目标，目标板上有多块贴片不再被降级；重合足迹双向同时包容时保留小面积侧并把被抑制方向记入歧义统计，三层叠板不会把顶板直接焊穿中板到底板。③ T 规则扩展——源面（路径相邻单元的全部节点与形心）双向投影完全落在目标上时，其最近边行只要能完全投影落到目标即判完全可信（TRUSTED），覆盖带翻边翼缘使侧边部分命中污染整组完备性的 T 型焊缝；整面检查的投影射线范围覆盖面高度（不再受焊缝搜索距离限制，否则高于搜索距离的腹板必然失败），最近边行按各边自身区间端点采样（共享角点沿用所属边的命中，不借用相邻边的射线）。新增多贴片组件、多 patch 组件互不降级、翻边最近边规则与贴片孔周焊缝回归测试。④ 试运行跟进加固——T 潜在行现在逐条注明触发的具体门禁（覆盖不完整边、距离波动、法向角、距离超限、扩展规则未满足），可直接从识别结果定位降级原因；整面检查的采样上限随面尺寸自适应（max(2500, 6×相邻单元数)），大型桁材腹板不再被固定点数上限错误拒绝。

- 新增「添加 Washer」网格模块（`modules/mesh_add_washer.tcl`，主面板 Mesh 分组，入口 `::WasherTool::run`，独立测试入口 `washer_test.tcl`）：在只有壳网格、无几何的模型上选择孔边一个节点，自动定位所属 component（多 component 引用时按自由边成员资格消歧，歧义即拒绝）、用原生 `*findedges comps 1 0` 提取自由边并保留/恢复用户已有 `^edges`、按纯拓扑 BFS 回溯完整闭合孔边（每个节点度数必须为 2，开放边/分叉/节点数不足全部拒绝且不改网格），随后直接调用 HyperMesh 2019 原生 `*add_multi_washer_elements`（位置参数与 string array 格式经本机 2019 `hm/scripts/macroAddWasher.tcl` 核实）按目标 `hole_density` 重建孔周并创建指定层数与每层径向宽度的 washer，等宽层自动使用 `uniform_layers = 1`。创建前完成参数与拓扑全部校验，唯一修改步骤是 washer 命令本身；创建后自动复检新孔周节点数、闭合性、component 归属、rigid/system 未新增与 `^edges` 无残留。降密度请求（16→8、16→12 等）直接透传 `hole_density`，不复刻宏层 `max(原密度, 目标)` 逻辑，四种密度调整组合（8→12、12→12、16→12、16→8）的实机结论标记为待 HM2019 冒烟验证。离线 Tcl 自测覆盖 string array 构建、BFS 回溯、闭环/开放/分叉校验与参数校验。

- 网格焊缝改用 HyperMesh 原生撤销，整模型 `.hm` 快照方案移除：批次不再用 `*writefile` 另存 `before_*.hm`（手动批次 1 次整模写入 + 自动模式每候选 1 次），改为批次开始时启用原生撤销记录（`hm_gethistorylimit`/`*sethistorylimit`/`*sethistoryrecord 1`，HM2019 另启用 `hm_private_frwk enablehistoryfromtcl 1`）并记录 `hm_getundoactions` 基线；每条路径/候选本来就是命名 history action，成功批次把这些动作整体注册为撤回点，工具箱“撤回”按 `hm_getundoactions` 中的位置一次性 `*undohistorystate N`（老版本单步时回退为逐条），并核对撤销栈与抽样焊缝单元确认撤回生效。FAST_AUTO 每个候选在自己的 history state 中执行，失败先校验栈顶标签再用 `*undohistorystate 1` 回滚该候选，并验证母单元恢复、新增单元/节点消失后继续。批次之后的其他修改会被一并撤销，确认框会标明项数；最老撤销项被历史容量挤出时拒绝部分撤回并提示。新增原生撤销注册/撤回/容量回退回归测试并更新 FAST_AUTO 断言。

- 修复 FEM 自动焊缝在真实模型导出上被单个 `CTRIA3`/`CQUAD4` 的 `PID=0` 卡中止整个识别任务的问题（组件未分配属性时 HyperMesh OptiStruct 模板会原样导出 PID 0）：共享读取器按 Nastran/OptiStruct bulk 约定把空白或 0 的 PID 兜底为单元 ID（EID），仅负数 PID 保留报错；网格焊缝共用该读取器一并受益。新增 PID 0/空白兜底与负数报错回归测试，端到端验证第 336656 行 PID 0 卡不再中止。

- 接触创建重构为统一 `SURF / COMPONENT` 子界面，并在主面板保留两个入口：COMPONENT 链路使用 HyperMesh 2019 官方 `*detectandcreateface2facecontacts`，支持 tolerance、反向角、壳厚、相交检查、consolidate、CONTACT/TIE、内置类型/摩擦/已有 PCONT、Main/Secondary 类型和 Review；SURF 链路完整保留原双 Face 公共区域筛选、接触面/group 创建和修剪逻辑，不支持的设置在共用界面中禁用。新增 17 参数映射与原生命令调用回归测试，本机 HM2019.0.0.70 已确认命令存在。

- 网格焊缝手动模式恢复原生 Create Patch 创建链：以源 Nodes 和局部目标 Elements 调用 `*imprint_nodelist` 的 `create_joint_elems=1`，直接在 `SEAM_*` 中生成焊缝壳；只对本次新增 patch 做边界固定 mixed remesh，并校验重绘前后连接边完全一致。单边界点识别同时扩展为与目标局部平面平行的开放/闭合直线、曲线及空间边界平行子段；内部单点在边界分类后跳过目标法向查询并保留“所属组件全部闭合自由边”流程。原生自由边图按源 component 在批次内缓存，种子路径只批量读取所在连通轮廓。

- 修复网格焊缝把零件号中的 `T<数字>`（例如 `ST3000`）误识别为板厚、生成 `SEAM_T3000` 的问题：手动模式恢复使用统一的 `_T<厚度>` 命名解析器并保留小数厚度；自动模式按源/目标组件中较薄的有效厚度命名。新增几千值误识别、小数厚度及双侧取薄值回归测试。

- 实体焊缝 Auto/AutoGroup 识别准确性修复（10 接头验证模型 + 4 个网格密度对照模型实机验证，HM2019/HM2022 双版本）：① 实体组件接头分类从未生效——`localShellPatch` 只认壳单元导致 32 样本投票永远 NATIVE；现在从原生外表面提取实体焊缝节点法向（面积加权主导轴门禁 1.2×，块状实体安全降级 NATIVE，接触面内部节点回退组件主导轴），J01-03→PENTA_MIG_T、J04-05→PENTA_MIG_L、J06-07→PENTA_MIG_B 全部与地面真值一致；② 最近距离分层改用点到目标面距离（BVH），面向判定与接触带同步升级最近面点方向——4:1 网格密度失配下真实焊缝从 3×2 节点碎片恢复为 18 节点完整环链，且与均匀网格对照模型结果逐字一致（密度/重划分不变性）；③ AutoGroup 方向选择新增退化门禁（<3 节点碎片链不能作为方向证据）。T/L/B 新实现路径（feType 118/117/119）在双版本创建全部 PASS，并顺带修复 HM2022 上 J04 搭接链原生 FAILED 的问题。整批性能保持 1.378 s（优化前 5.573 s）。新增 `classification_offline.tcl` 回归。开关：`ui(automatic_solid_normals)`、`ui(automatic_face_layering)`（默认开）。

- 实体焊缝 Auto/AutoGroup 预计算性能重构（候选指纹与两版实机验证零变化）：① 识别批次开始前对全部选中组件做一次分块 connectivity 批量预取，消除逐单元查询；② `^faces`/`^edges` 临时组件回读改为分块批量读取（失败自动回退逐实体）；③ 目标表面最近邻 KD 树按组件缓存并在面向边界判定、junction 检测与 shadow 审计间复用，不再每方向重建。10 接头验证模型（20 组件/21,400 HEXA/12 对）实测：HM2019 整批中位数 5.573 s → 1.355 s（-75.7%）、HM2022 6.032 s → 1.282 s（-78.7%），`hm_getvalue` 129,967 → 4,729 次/批，KD 树构建 72 → 18；10 接头与 4 个网格密度对照模型的候选指纹及规范化文本与改动前逐字节一致。新增 `prefetch_offline.tcl` 离线回归并纳入 `test_refactor.py`。

- 实体焊缝实机研究补充：本机 hmbatch 的 OptiStruct 导入读取器只接受每行 ≤10 个逗号字段的自由场卡，单行 CHEXA（11 字段）被静默丢弃（导入返回成功但 0 单元），须写为 `+C` 续行；reader 名需用 `#optistruct`（`#optistruct\optistruct` 在新安装上报 "The translator does not exist"）。`femlib.write_fem` 对超长节点列表卡自动输出续行；`hm_speed_research.tcl` 导入增加 reader 名回退。详见 `docs/solid_seam_auto_speed_accuracy_2026-09-06.md`。

- 实体焊缝 Auto/AutoGroup 新增稳定候选指纹和分阶段识别计时；实现可选的点到目标外表面 BVH 距离 shadow 检测，只记录潜在漏识别节点和点/面距离偏差，不改变配对、路径、类型、侧向、参数或创建。增加粗/细目标网格参数化基准及指纹基线迁移校验。

- AutoGroup 预计算新增操作级只读缓存，跨有向识别和多个 pair 复用用户所选组件的坐标、原始 connectivity、element config、边界和拓扑；临时组件不缓存，创建前或异常时统一清理。HM2019 六组件基准的 `hm_getvalue` 从 38,647 降至 16,310（7 次合计），候选指纹及创建结果不变。

- AutoGroup 组件粗筛改为扩大 AABB 的保守 sweep-and-prune，随后继续执行旧精确 AABB 判定并恢复旧 pair 顺序；扫描进度按 100 ms 节流，关键事件仍立即显示。2,000 个分离组件的 1,999,000 个理论组合基准由约 17.2 s 降至 3.6 ms，混合尺寸/细长 AABB 与旧结果逐对一致。

- 实体焊缝识别复用单次调用内的原生边界、组件数据和局部壳单元几何，创建前及异常时清空缓存。HM2019 六组件 AutoGroup 样例预计算中位数从 86 ms 降至 62 ms，候选结果逐字段一致；开放边、闭环、侧向和豁口回归通过。

- 修复自动实体焊缝开放边只识别两端、漏掉中段：最近层筛选后按真实拓扑保留范围内的连续中段；分叉边界拆为独立路径，不再使整个组件对失败。Auto/AutoGroup 的 HM2019 起伏开放边及原有豁口回归通过。

- 实体焊缝新增 AutoGroup：一次多选 comps，按 Auto 几何逻辑自动识别组件对及源/目标方向，预计算后批量创建；增加进度条、滚动命令流、完整批次日志和跳过/失败统计。HM2019 六组件 T/L/B 样例自动配对及创建通过。

- 实体焊缝 Auto 复用局部采样推导正/负侧，歧义时保留面板选择；组件模式增加缺单元豁口过滤，剔除凹口边段并断开焊缝路径，避免跨口连接。

- 实体焊缝支持 node path（单点闭环/多点路径）、comps+comps 和 Auto；改为两两一组缓存、源输入空选后批量执行，目标空选仅取消当前组。统一预计算各组路径和参数，逐组记录失败并继续；去掉全模型元素 mark，采用只读实体查询和空间索引。

- 预处理的“清理无关部件”支持一次选择多个 component：按各自基础名称展开 `.数字` 重名族、跨选择去重后批量归档；无效选择会安全跳过。无关组件和 SKELL 骨架归档现在会显示解析、Assembly 更新及逐组件隐藏进度。

- 网格焊缝开放路径在 `imprint -> ruled` 的目标拓扑重建中，现将源路径首尾各自的最近投影节点作为硬约束：搜索只能从首端投影锚点出发并在末端投影锚点结束，方向判断也只由两组端点对应关系决定；内部节点的整体代价不再允许把任一端滑到相邻节点行，从而消除焊缝两端斜拉和扭曲。

- BatchMesher 将原生质量失败与结果可用性解耦：对新增网格执行节点连通分量检查和质量检查，criteria 未满足时以 `needs_optimization` 完成并保留 FEM/HM 输出及待优化单元计数，供后续局部优化反复迭代；无法完全优化也不丢弃网格。只有确认同一几何连通域的新增网格跨边界不连通时才报 `BATCHMESH_CONNECTIVITY_INVALID`。

- 网格焊缝失败路径仅在失败位置创建并选中临时自由节点，不再创建 `MESH_SEAM_WELD_FAILED_MARKERS` 专用 component；手动批次首次识别为连续 `node path` 后，本次批次的后续源节点选择会持续使用原生 node-path 面板，无需逐次切换。

- 深度收紧网格焊缝 `imprint -> ruled` 后处理：即使原生 `list 2` 数量完整且拓扑连续，也会按全部源节点重新投影当前目标网格，并从该局部走廊全局重建目标路径，避免误取相邻节点行；缺少覆盖每个源节点的唯一、单调锚点时整条路径回滚，不再把完整源路径拉伸到部分目标节点形成梯形/扇形焊缝。横向分层由无条件向上取整改为带半层滞回的最近层数，并消除孤立中间/端部尖峰、限制相邻位置最多变化一层，避免无必要多层及窄端密集叠网格。

- 网格焊缝投影后的局部 element 层扩展改为优先使用 HyperMesh 原生 `*appendmark ... "by adjacent"`：只在投影建种时确认 element 位于所选目标 components，随后两至三层 support halo 允许自然扩展到相邻未选组件或不同平面的共享节点壳单元；这些单元与目标 patch 一并进入 imprint，不再触发共享外部壳单元拒绝或跳过任务。预制 element ID 失效时同样按源路径重新投影并重建完整 halo，不会在刷新分支过滤掉外部 support。后续 ruled 仍保留目标路径连续性、方向/闭环起点对齐、等数量一一对应细化与不等数量弧长锚定；不支持该 selector 的版本自动回退到有界 Tcl 邻接遍历。目标准备保留 path、target mark、closest-node projection 与 patch 四级耗时日志。

- 所有命令流提示统一为英文：默认/出厂语言切换为 `en_US`（`config.yaml` 的 `workflow.language`、代码默认与 `normalizeLanguage` 缺省均为英文），所有经 `::HWFlow::txt` 的双语文案一律显示英文；同时修复原本绕过双语机制的中文提示（BatchMesher 树形列头、批量赋予 Property 的进度/失败信息、Local Mesh Optimizer 的 Python 进度与 HTML 报告），并给网格焊缝失败报告补充 `reason_en/action_en` 字段。All command-stream prompts are now unified to English.

- 修复 `auto_hole_rbe2` 在实际贯穿孔任务中必失败的两段链路：HyperMesh 2019/2022 的 OptiStruct exporter 会把内部 `^faces` 当作显示数据，只写 GRID 而静默省略 CTRIA3/CQUAD4；现在仅在导出事务内将该临时 component 改为唯一普通名称，完整写出自由面后无论成功失败都恢复 `^faces`。同时补回候选创建阶段缺失的 `hybridNodeExists`，避免识别成功后在 solver/internal node ID 校验处中断。默认开启内壁法向过滤，防止实体外圆柱面被当成孔。双版本实机环形 HEXA 贯穿孔端到端验证均得到 1 个候选并成功创建 1 个 RBE2。

- 修复沉台清理将正常贯穿孔壁误判为沉台外壁并删除的问题：外环/内环不再按两侧壁高排序，而是使用 `hm_linelength` 计算真实边界周长（包括端点重合的完整圆边），将较大边界确定为沉台外环、较小边界确定为贯穿孔内环。删除集合仍只包含沉台底面与外壁，并新增孔壁分类重叠检查及删除后孔壁存活硬校验；一旦孔壁受损，会在 ruled 前中止并通过原生 history 回滚。

- 几何清理的沉台/凹槽流程现在在修改模型前显式启用 HyperMesh 原生 history recorder，并在撤销容量被关闭时恢复容量；每次清理作为一个命名原生撤销项提交，因此可直接使用 `Ctrl+Z` 撤销。若当前 HyperMesh 无法建立或提交原生撤销项，流程会停止或回滚，不再产生“清理成功但不可撤销”的结果。新增 HM2019/HM2022 实机 `hmbatch` 冒烟验证，覆盖成功后的原生撤销及失败路径自动回滚。

- BatchMesher 2.7 修复 HM2019 自定义孔识别规格在后台误报 `cleanup parameters file is not valid in the holes recognition section`：依据本机 HM2019.0.0.70 独立 BatchMesher 的 `EventsLog.txt` 与安装目录 `hmbm.tcl`，2019 改用其真实接口 `*hm_batchmesh 1 criteria param`，2022 保持 `*hm_batchmesh2`。HM2019 旧接口的带空格 Windows 路径同时转换为 Altair 官方脚本使用的正斜杠形式。配置“验证”和正式 worker 按目标 hmbatch 的实际版本选择同一接口；验证缓存绑定 hmbatch 与两个规格文件的路径、mtime、size。原生错误输出会写入失败信息，任务状态补齐实际 `created_elements`。实机 HM2019.0.0.70、HM2022.0.0.33 的预检、双任务、FEM/HM 输出与合并均通过。

- 本机双版本 BatchMesher CLI 端到端验证：新增 `tools/verify_batch_mesher_cli.py`，用本机 HyperMesh 2019.0.0.70 与 HyperWorks 2022.0.0.33 的 `hmbatch.exe` 按模块真实启动方式运行 `background_worker.tcl`（2019 使用 `*hm_batchmesh`，2022 使用 `*hm_batchmesh2`）与 `background_merge_worker.tcl`。两版本的双任务、HM/FEM 输出与合并均通过；`PARALLEL_WORKERS=2` 双 worker 并发在两版本上也通过。`doc/batch_mesher.md` 相应更新。

- BatchMesher worker 改为在各自私有 `run_dir` 中执行版本对应的原生 BatchMesh 命令（`invokeFromWorkerDirectory`）：BatchMesh 会相对进程工作目录写 `ModelBuild/`、`productBatchMesher.ico`、`hw_batchmesh.bat` 等临时产物，原实现把 cwd 切到共享的 criteria/param 目录（通常位于 Program Files 且被多 worker 共享），并行 worker 会互相覆盖，受限目录下还会直接失败。solver profile 初始化仍可从规格源目录读取 quality criteria；原生调用使用两个规格的绝对路径。

- 修复 `hm_hybrid_export_smoke.tcl` 的过时调用：`mesh_seam_weld.tcl` 自 6dcb491 起将 Python/FEM bridge（`tcl/bridge.tcl`、`tcl/exporter.tcl`）改为按需 opt-in，冒烟测试仍直接调用 `runPythonPathStage`/`exportHybridInputs`，导致矩阵在 seam 阶段即失败；测试现在按模块设计显式 opt-in 加载这两个文件。注意：解除该遮蔽后暴露了 `auto_hole_rbe2` 既有的 `*findfaces` 自由面 GRID-only 导出问题（`*feoutput_select` 与 `*feoutputwithdata` 均只写出 8 个 GRID、无 CTRIA3/CQUAD4，2019/2022 复现一致），该模块的 `hm_hybrid_export_smoke` 阶段仍失败，需另行修复。

- 对齐新安装的 HyperMesh 2022.0.0.33：BatchMesher 安装发现不再假定目录名必须为 `2022`，支持实际存在的 `Altair/2020/hwdesktop/hm` 布局，并将 Default 自动规格迁移到该安装自带的 `general_8mm.criteria/.param`；2019 经典布局和自定义预设继续保留。

- 按当前实机重新对齐几何焊缝的 HyperMesh 2019.0.0.70 与 2022.0.0.33：两版分别在 12 个独立 hmbatch 进程中跑完全部公开功能，创建 ID、面积、包围盒、边归属拓扑、消息、警告与最终 Surface 集合逐项一致；命令审计同时通过。修复 T_LIST 校准包装器未转发匹配模式/容差、以及 `*edgesmarkaddpoints` 重编号后审计仍使用旧 Line ID 导致 `*createlist` 假失败的问题。

- 修复 BatchMesher 首次使用时因 `hmbatch.exe`、Criteria 和 Param 均为空而无法调用的问题：面板现在自动发现本机受支持的 HyperWorks 2019/2022，并使用安装自带的 `general_8mm.criteria` / `general_8mm.param` 默认规格；已有有效自定义规格保持不变。

- 优化 FEM 自动焊缝的 Python 规划阶段：候选复核后的创建规划复用同一任务检测阶段已生成且按模型、现有焊缝、所选组件和检测参数校验的候选缓存，不再对完整 FEM 重复执行一次候选检测；缓存缺失或输入不一致时仍安全回退到完整检测。

- 修复 T 列表/连接边线在跨 Surface line list 上执行 ruled 后无结果：共享 Connect Edges 执行器现在与 HyperMesh 手动 Ruled 面板一致，在创建 line list 和调用 `*linearsurfacebetweenlines` 前显式执行 `*surfacemode 4`（surface only），不再继承此前残留的 automesh/surfaceless 全局模式。

- T 列表的 Project/Split 与 Connect Edges 现在使用两个独立的原生 history action：切分阶段一旦开始，无论后续候选筛选、排序或 ruled 连接成功与否，本次 trim 都会提交并保留；连接失败只回滚连接阶段。连接准备改为“严格匹配 → 多目标面 trim 片段沿投影轨迹排序 → 本次 trim 集合内最佳匹配”的分层链路；投影参考不可读时也会在本次 trim 集合内继续执行与手动 Connect Edges 相同的路径判断，不再直接停止。切分阶段确定的两组 line ID 顺序会原样写入 `*createlist lines 1/2`，连接阶段不再二次重排。

- Project/Split 现在在每一次 `*surfacemarksplitwithlines` 内部单独开启 `hm_entityrecorder lines`，并记录该目标面切分前后的边线差集。T 列表的第二组候选只由“本次 trim 新建且属于该目标分片的 Lines”与“本次 trim 后新附着到该目标的 Lines”组成，不再使用整个模型的新 Line 差集。Ruled 前将最终 `list1/list2` 顺序写入日志便于核对。

- 继续收紧 T 列表交给 Connect Edges 的两组 lines：严格阶段要求第二组候选覆盖投影前记录的目标面落点；若 HyperMesh 实际 trim 与最近点参考存在差异，则只在本次 trim 记录集内按全路径误差选取最佳 ruled 兼容路径。多目标面产生的非拓扑连续片段按投影弧长统一排序，并排除只在交点附近横穿投影轨迹的边界线。两组路径的方向/循环起点不再只用首尾判定，而是沿完整路径按弧长等比采样，比较正向、反向及闭合路径所有循环起点的全路径对应误差，再将最优 ID 顺序写入 line list 1/2。

- T 列表仅组织现有 Project/Split 与 Connect Edges 两个流程，不改动两者的原生执行方式。T 列表通过现有 `_split_surface ... PROJECT` 执行完整切分和 no-op 判定；切分前记录源线在所选目标面上的预期投影点，切分后依据这些目标面落点识别第二组 lines，避免误选源线附近或远处的其他新边。在交给 Connect Edges 前，分别按端点连续关系重排两组 lines，并根据两组起点/终点的几何距离统一行进方向；重排结果按顺序写入 HyperMesh line list 1/2。投影仍直接修改原 Surface，整个 T 列表保留原生 history action 供 `Ctrl+Z` 撤销。

- 根据第二轮 HM2019 手工日志澄清搭接曲面的输入边界：C03 与 C04 均已成功；两次所谓“部分失败”都来自把 C06 投影/切分几何送入搭接曲面，候选面未同时连接两侧，严格拓扑门禁正确回滚。按钮、原生选择提示和错误信息现在明确要求“两张近似平行且投影区域重叠的面”，并引导边到面改用“搭接边线”、投影几何改用“投影切分”，不通过放宽门禁保留游离曲面。

- 根据 HM2019 验证模型的首轮手工反馈修复几何焊缝 T 曲面与搭接曲面：导入 CAD 无 Property/`_Txx` 厚度时，T 曲面不再在 selector 层静默停止，而是与其他创建功能一致弹出厚度输入；搭接曲面不再把 50 mm 实体偏置产生的远端构造盖板/侧壁全部移入 `SEAM_T*_Surf`，新增原始两面包络过滤（可调 `lap_result_envelope_tolerance`），本机两版本均由原 9 张混杂面收敛为间隙内 4 张真实连接面。成功后统一显式显示并同步输出 component，避免“日志成功但图形/Browser 看不到”。T 曲面、搭接曲面、T 列表在 HM2019.0.0.70/HW2022.0.0.33 重新通过。

- 重新按本机 HyperMesh 2019.0.0.70 与 HyperWorks 2022.0.0.33 逐策略验证“几何焊缝”：修复非交互执行器对 UI selector 的错误依赖；T 列表不再把切分后完整目标面边界形成的分支图整体拒绝，而是枚举无分支路径、按源路径几何覆盖评分选出真实投影边，并在 ruled 创建后执行 merge/equivalence，验证焊缝边同时归属源面与目标面，杜绝游离曲面假成功。EXTEND 改用帮助文档规定的 trim mode 1，并将 offset type、偏置/搜索距离、投影距离等真实可调参数接入设置；设置面板补齐投影路径、拓扑、质量、T/搭接、延伸、点编辑、厚度、兼容与诊断参数，配置文件保存时保留参数说明。两版本各 12/12 策略独立 hmbatch 通过，模块离线测试 44 passed + 16 subtests。

- 在几何板块新增独立的 `预处理` 面板：支持将当前显示组件按全局 X +90°、全局 Z -90° 转为车辆坐标系；按所选 component 的基础名称归档本体及 `.数字` 重名族；以及归档名称中包含 `SKELL` 的骨架组件。归档统一进入 `USELESS` Assembly 并隐藏，不删除模型实体。

- 提交 2026-08-08 跨模块原生指令审计的探针脚本：`tools/audit_*.tcl`（103 个，每模块一组，见 `docs/module_command_audit_2026-08-08.md` §7 证据清单）、`tools/fix_probe_bolt_*.tcl`（修复探针）、`tools/fix_probe_geometry_cleanup22.tcl` 及实机探针 `tools/probe_*.tcl`（rbe2/bolt/adhesive/solid_seam/quadratic 等），可复用于修复验证。`.gitignore` 同步覆盖探针运行产物：`runtime/` 下的导出模型与 KEY=VALUE 日志（`*.fem/*.hm/*.inp/*.txt/*.tcl` 及 `audit_batch_mesher_work_*/`）不入库；一次性调试文件 `tools/diag_*.tcl` 与根目录临时探针（`_probe_asm*`、`command1.tcl`、求解器 .msg）按约定忽略；`/.zcode/` 本地记忆目录忽略。

- 新增验证模型生成体系：`doc/validation_model_generation_conventions.md` 定义全项目验证模型统一约定（FEM 格式、manifest schema、自检要求、正常+失败双覆盖）；`examples/` 下新增 13 个验证目录（GeometryCleanup / Midsurface+BOM / SeamSurface / SolidSeam_Extended / MeshSeamWeld / FemAutoSeam / WasherHoleRBE2 / SolidHoleRBE2 / BoltConnector / LocalMeshOptimizer / WeldIntegrityCheck / AdhesiveConnector / ContactSetup）。全部为确定性生成器（网格纯 stdlib 便携 python38；几何 cadquery 开发期工具），内嵌拓扑自检，产物 .fem/.step/_manifest.json/.criteria 遵循 gitignore 约定不入库，仅提交生成器与中文 README。

- 实体焊缝节点源改为显式的第一组件：选择流程拆为“节点来源组件”和“几何/连接目标组件”两次单选；Shell 按平行边界或最近边线取节点，Solid 按距第二组件最近外表面的边线取节点，并阻止组件 ID 排序颠倒两者角色。

- Fix the cross-module command audit findings (docs/module_command_audit_2026-08-08.md,
  probes verified headless on 2019.0.0.70 and 2022.0.0.33):
  (1) fem_auto_seam: the batch remesh loop guarded on `hm_getmeshfaceparams`,
  which reports "entity not found" on both builds right after a successful
  `*set_meshfaceparams`, so `faceCount` always reached 0 and every remesh
  failed with "automesh did not produce any temporary face mesh" - the
  unused diagnostic read and its empty-check break are removed; the two
  dead `hm_viewfit` calls in the review UI are removed as well.
  (2) geometry_cleanup: `*surfacefilletremove` works on 2019 but errors on
  2022, and the old `*surfacemarkremovelinefillets` fallback errors on both
  builds - the 2022 branch now queries `hm_getfilletfacesfrommark` on the
  chamfer-chain mark and deletes the found faces via `*deletemark surfs`
  (both commands verified on both builds; the 2019 path is unchanged).
  (3) rbe2_bolt_connector: `verifyEndpointCoordinates` read
  `dataname=coordinates`, which is not a valid node dataname on either
  build - it now reads x/y/z like the main path; `replaceOneNode` no longer
  errors when the native merge is unavailable, because five probes on both
  builds proved `*replacenodes`, `*equivalence` and
  `*replacentitywithentity(mark)` never merge coincident free nodes headless
  - coincident pairs now count as replaced (callers only invoke it with
  coordinate-identical nodes) and `forceBeamEndpointNodes` accepts the
  coincident originals in its final check.
  (4) Dead-command cleanup across modules: all 17 `hm_viewfit` /
  `hmbr_signals` / `hm_blockbrowserupdate` calls removed from
  workflow_common, midsurf, fem_auto_seam, mesh_seam_weld, seam_surface,
  auto_hole_rbe2, geometry_cleanup, rbe2_bolt_connector,
  shell_washer_hole_rbe2, local_mesh_optimizer and weld_integrity_check.
  (5) Audit rating corrections backed by probes: batch_temp_nodes
  (`*deletemark nodes "by id only"` works on 2019 for free nodes, undo is
  functional), contact_setup (5-arg `*adjustcontactsurfacenormal` works on
  both builds; group dataname fallback already in place) and auto_hole_rbe2
  (`*findfaces` + `*feoutputwithdata` export verified on both builds) are
  healthy; the `^faces` and deletemark findings were false positives.
  Verification: 13 edited files pass Tcl syntax checks; the offline suite
  passes (34 tests + 9 subtests; the sole batch_mesher failure is a
  pre-existing flaky test interaction, it passes in isolation); the
  geometry_cleanup 22 branch was replayed headless on both builds with
  tools/fix_verify_geometry_cleanup22.tcl (19 keeps the original path,
  22 takes the new branch, both without errors).
- Fix the adhesive area connector (打胶连接) on the installed HyperMesh builds
  (2019.0.0.70 / 2022.0.0.33).  The module now reliably creates a realized
  1D Connector of type Area with realization type `adhesives` (OptiStruct
  FE type 121, realized as RBE3 + HEXA8) using the constrained options
  (tolerance 50, 1 coat, constant thickness 1.0).  Three defects fixed:
  (1) the pure-Tcl location cleaning fallback evaluated the dominant normal
  axis with the literal string `abs(...)` instead of `expr {abs(...)}`, so
  every polygon grid expanded by the tolerance on the wrong axis and all
  location elements were rejected; (2) `primeGeometryCache` assumed
  `hm_getvalue ... mark=N` returns rows in mark-creation order, but rows are
  ordered by entity ID on both builds - element/node caches were misaligned,
  corrupting coordinates for elements whose IDs are not contiguous with the
  mark (98/2400 elements rejected in the 10k-element scale model);
  (3) the polygon spatial grid used the tolerance as cell size, collapsing a
  large plate into a handful of cells with up to 10k polygons each - the
  cell size is now derived from the local mesh density (2x typical in-plane
  span) with the tolerance applied only along the normal axis.  Verified
  headless on both builds: the 10k-element scale model cleans 2400 location
  elements to exactly 2000 kept / 400 rejected in ~9-10 s (was 847 s), the
  15 offline unit tests pass, and the full end-to-end probe (dialog flow
  through `createAdhesive` with connector realization) passes on 2019 and
  2022.
- Fix the solid seam connector (实体焊缝) creation on the installed HyperMesh
  builds: the native seam realization requires a tolerance large enough to
  cover the local mesh and joint gap.  A tolerance of 1-2 mm fails
  (`connector_state=failed`, no elements) while 3 mm and above realize
  PENTA6+RBE3 on the same model; the command profile now computes an adaptive
  tolerance floor `max(6.0, 1.5*mesh_size, max_gap+mesh_size)` from the model
  instead of trusting the candidate value.  The main flow no longer goes
  through the Python pipeline: the user picks two components and a new pure
  Tcl detector (`modules/solid_seam/tcl/auto_detect.tcl`) finds the junction
  node chains taken from the first selected component with a mutual-nearest + largest-gap layer filter (the manual node list matches the user's 239-247 exactly; a fixed tolerance cut the curved seam's ends),
  classifies the joint (T/LAP/BUTT/ANGLED -> PENTA_MIG_T/L/B/MIG) from
  component normals, and derives width/spacing (default 6, clamped to the
  mesh) and the adaptive tolerance.  Weld nodes always come from the FIRST
  selected component and are restricted to its boundary: free-edge nodes for
  shells; for solid components the boundary of the outer face layer closest
  to the target (pitch-adaptive bands + per-face facing dot test so a curved
  contact face keeps its whole outline while perpendicular side faces stay
  excluded; pyramid5 now emits its full 5-face set and the solid free-edge
  threshold was fixed from 1 to 2).  Chain building ranks candidates by
  distance with the turn penalty applied after the gap gate, so ring-shaped
  contact outlines stay a single chain.  Verified headless on 2019.0.0.70
  and 2022.0.0.33: F03 curved-T with the web picked first picks exactly the
  manual node list 239-247 (9 nodes, T_JOINT, 14 PENTA6 + 45 RBE3, PASS,
  output SEAM_SOLID); with the base picked first the strict first-component
  rule yields the base-side contact rows (2 x 3 nodes, REALIZED PASS).  The
  C01 solid-plate validation case now finds the full 20-node bottom ring as
  one LAP_JOINT chain (30 PENTA6 + 90 RBE3, PASS on both builds); see
  docs/solid_seam_dual_version_alignment_2026-08-08.md.  The Python
  detection pipeline and its tests are kept as legacy and are not used by
  the main flow.  module_status solid_seam_connector.runtime = native.
- Fix the repository tracking audit vs `.gitignore` conflict: the audit tool
  (tools/repository_audit.py) now exempts the versioned acceptance fixtures
  under `examples/AutoShellSeamBackend/test_fem/` exactly like the `.gitignore`
  `!/examples/AutoShellSeamBackend/test_fem/` negation rules, so
  `python tools/run_offline_tests.py` no longer aborts at the audit step and
  the CI "Run offline tests" step and hybrid_core
  `test_git_tracking_policy_is_clean` pass again. Doc note added to
  doc/repository_layout.md.
- Record the five modules that were missing from `modules/module_status.json`
  (batch_mesher, fem_auto_seam, midsurf, geometry_cleanup, cbush_creator); the
  file now covers all 18 registered modules. batch_mesher is production
  (dual-version verified with hmbatch smoke tests), fem_auto_seam is controlled
  (HM2019 validation protocol pending), the legacy Tcl modules are production.
- Remove the deprecated casting_tetramesh module (its registration, module
  file, `config/casting_mesh_rules.txt`, and all documentation references).
- Add the FEM Automatic Seam section to the offline guide (guide.html): new
  sidebar entry, dashboard card, and a full module section (function,
  steps, parameter table with defaults, safety notes) mirroring the Mesh
  Seam Weld layout; it was the only module missing from the guide.
- Point the stale `modules/batch_mesh_washer.tcl` reference in
  doc/INTEGRATION_ANALYSIS.md at the current `modules/batch_mesher/`
  location (the old file was merged into the BatchMesher module).
- Align the geometry seam module with the locally installed HyperMesh builds
  (2019.0.0.70 and 2022.0.0.33, verified headless with the same fixtures on
  both; see docs/geometry_seam_dual_version_alignment_2026-08-07.md). Both
  builds accept only mark slots 1/2/3, so the mark-5 internal snapshots used
  since the mark-99 fix silently returned empty on every strategy; the module
  now detects a usable internal slot at runtime (`internal_mark_slot` config
  override, probes 5 then 3). `hm_info currentcomponent` returns the
  component name on both builds, so `native::current_component` converts it
  to an id before the collector re-read verification. `*offset_surfaces_and_modify`
  parses with the signed distance last on both builds (measured z=+2 for the
  previous "recorded" layout vs z=-12 documented); EXTEND now calls
  `surfaces 2 0 1 2 -<distance>` so the configured `extend_offset_distance`
  actually applies. `*connect_surfaces_11` extend-mode-3 consumes the source
  surface (rebuilds it with a new id) and creates seam strips sharing the
  target's edge lines; T_PATH/T_LIST/L_LIST identify the strips, re-home them
  into the seam component and use the rebuilt source as the source-side
  topology partner. A headless 12-strategy harness
  (tools/probe_geometry_seam_harness.tcl) passes all functions on both
  versions with identical created-entity ids; offline suite 40 passed.
- Audit every HyperMesh Tcl command used by the production modules against
  the two local builds (238 native candidates probed headless on both;
  tools/audit_hm_commands.py + tools/check_hm_command_signatures.py). All
  documented commands match their call sites. Corrected commands that exist
  on neither build: `*viewfit` -> `hm_viewfit` (fem_auto_seam, mesh_seam_weld,
  weld_integrity_check, local_mesh_optimizer), `*redraw` -> `hm_redraw`
  (batch_temp_nodes, cbush_creator), `*shownumbers` removed (local_mesh_optimizer,
  `*numbersmark` already covers it), `*contactsurfremoveelems` fallback
  removed (contact_setup; `*removeelemsfromcontactsurf` is the documented
  command), `hm_getsurfacesfromline` fallback removed (geometry_cleanup),
  and `*surface_patch` is now guarded by an existence check because it exists
  on 2022 but not on 2019 (geometry_cleanup). GUI-only commands that cannot
  be verified headless (hm_viewfit, hm_registerkeyproc, hm_blockbrowserupdate)
  remain catch/existence-guarded. The mesh_seam_weld offline suite keeps a
  pre-existing order-dependent failure pair unrelated to these changes.
- Fix the geometry seam "everything succeeds but nothing appears" failure on
  HyperMesh 2019. The on-machine diagnostic showed mark 99 is rejected by
  HM2019 (`hm_getmark: markmask should be ...`), and the module used mark 99
  for every internal snapshot/existence/component-surface fallback query, so
  those queries silently returned empty: REPLACE_POINT reported success
  without moving anything, DISTRIBUTE_POINTS reported failure even when points
  were created, and creation flows lost their model-wide new-entity
  detection. All internal mark 99 uses now use mark 5 (business marks 1/2 are
  untouched). `set_current_component_checked` no longer hard-fails when the
  current component cannot be re-read after `*currentcollector` (HM2019 has
  no `hm_getcurrentcollector`); it logs a warning and continues, while the
  created-surface owner check still catches wrong-component results. The
  diagnostic gained probes for `hm_info currentcomponent`, component
  surface-list datanames (`surfaces`/`surfs`), `collector.id`, list creation
  and a mark-slot sweep (slots 1/2/3/5/9/10/20/99) so the supported mark
  range can be confirmed directly on the target machine.
- Add a built-in command diagnostic to the geometry seam module (new
  `modules/seam_surface/diagnose.tcl`, "诊断" button on the panel). It probes
  every HyperMesh Tcl command the module relies on (62 commands): read-only
  queries are exercised with safe arguments and reported as OK/ERR with the
  returned value or error; destructive, panel and history commands are
  checked for existence only (EXIST/MISS) so the diagnostic never modifies
  the model. The compact per-line report is shown in a narrow Tk window sized
  for a phone photo, echoed to the HyperMesh command window, and saved to
  `%APPDATA%\HMWorkFlow\logs\geometry_seam_diagnose_*.log` for sharing.
- Remove every geometry seam feature that depended on behavior verified only
  on HyperMesh 2022.3, because the target workstations run 2019 and 2022.2:
  the projection + ruled T_LIST pipeline (`*surfacemarksplitwithlines` normal
  trim, path matching, `*surfacemode 4` + `*linearsurfacebetweenlines`,
  endpoint-gap repair) and its candidate helpers are deleted; the
  two-surface-group T Surface flow (`*connect_surfaces_11 1 2 1 ... 59 0`) is
  deleted; the `hm_entityinfo geometryvisible/elementsvisible` display queries
  and `hm_entityinfo exist -byid` existence query fall back to the legacy
  `hm_getvalue ... dataname=visible/displayed` and mark-based lookups;
  `suggest_extend_distance` (adaptive T extend distance) is deleted. The
  settings panel no longer offers the 2022.3-only knobs (adaptive extend
  distance, extend offset type, extend connect trim mode, point projection
  tolerance, public query API switch) and its validation list matches the
  retained 2019/2022.2 configuration keys. Tests were reduced to the baseline
  routes (38 geometry seam tests, all passing).
- Restore the geometry seam module's HM2019 baseline native calls. The
  2026-08-07 audit corrected `*connect_surfaces_11`, `*offset_surfaces_and_modify`
  and `*projectpointstoedges` argument layouts against the HM2022.3
  documentation, but the project baseline (and the offline workstations) is
  HyperMesh 2019.0.0.70, where the legacy layouts are the ones that produced
  results. The T Path / T List entries now route through the line-based
  `*connect_surfaces_11 1 2 3 ... 59 0` flow again (seam lines + target
  surfaces, thickness prompt restored), EXTEND uses the recorded
  `*offset_surfaces_and_modify surfaces 2 2 1 <dist> 2` + `*connect_surfaces_11
  1 1 3 2 ...` layout, and REPLACE_POINT uses the legacy `-1` projection
  distance. The projection + ruled pipeline and the audit-corrected wrappers
  are retained in the codebase (with their tests) for later HM2022 validation,
  but are no longer the active 2019 route. Settings that only apply to the
  retained 2022 flows (adaptive extend distance, extend offset type, extend
  connect trim mode) were removed from the settings panel so users are not
  misled by knobs that do not affect the 2019 baseline.
- Fix geometry seam operations that previously reported success while producing
  no usable result: EXTEND now fails when the native extension created no seam
  surface and left the source surface untouched (previously it returned the
  unchanged source surfaces as the "extended" result); DISTRIBUTE_POINTS now
  fails when no point was created instead of completing with zero points;
  PROJECT/SPLIT now fails when the split command neither created nor modified
  the selected surfaces; the T Surface flow now runs the same topology
  equivalence gate as the other creation flows so a disconnected seam is
  rejected (or downgraded to a warning with `topology_connection_required=0`)
  instead of being reported as a success. The module panel is reopened after
  each precise operation (and after leaving continuous mode) so the result
  message and warnings are actually visible, and operation warnings are now
  appended to the status message instead of being silently dropped.
- Complete the geometry seam `T_LIST` connection stage and repair projected-path endpoint gaps. The ruled surface creation keeps the HyperMesh kernel API (`*surfacemode 4` + `*linearsurfacebetweenlines 1 1 2 2 1`), but the post-processing now reuses the CONNECT strategy's verified connection chain: the preliminary ruled surfaces are merged with `*multi_surfs_lines_merge 1 0 0` under the pinned session cleanup tolerance (shared `merge_ruled_surfaces` helper, CONNECT and T_LIST both use it) before topology equivalence, so the seam is topologically connected instead of a free-standing sheet. When one source path is trimmed across adjacent Target Surfaces and the kernel leaves nearly-coincident-but-not-identical segment endpoints at the surface transition, the pipeline now detects those gaps (configurable `projected_path_merge_tolerance`, default 0.5) and merges each pair through the existing Replace Seam Point flow (`*projectpointstoedges` + `*verticescombine`), then rebuilds the projected candidate paths so one source path maps to one continuous path before the ruled call. Add tests for the merge step and the endpoint-gap repair (tests 78 -> 80).
- Replace the geometry seam `T_LIST` algorithm with the projection + ruled pipeline from the 2026-08-07 refactor spec: source lines are partitioned into connected unbranched paths (branches rejected, disconnected groups handled independently), all selected Target Surfaces are trimmed in one grouped `*surfacemarksplitwithlines 1 2 0 13 0` call (Normal to Surface + Entire Surface + Keep Line Endpoints), the projected trim path is re-identified from the real post-trim target fragments via edge-diff + owner topology + multi-sample arc-length coverage scoring (ambiguous matches are refused), the target path is aligned with same/reverse multi-sample orientation scoring, and one ruled surface per path pair is created with `*surfacemode 4` + `*linearsurfacebetweenlines 1 1 2 2 1` (kernel bow-tie protection). `*connect_surfaces_11` is no longer used on the T_LIST code path (L_LIST keeps the old extend route via `_create_t`), topology equivalence runs against the surviving fragments instead of stale target IDs, and every fatal stage (NORMAL_TRIM_FAILED / PROJECTED_PATH_NOT_FOUND / PROJECTED_PATH_AMBIGUOUS / BRANCHED_SOURCE_PATH / RULED_CREATION_FAILED / TOPOLOGY_EQUIVALENCE_FAILED) rolls the whole transaction back. Add `split_connected_line_paths`, `simple_paths_from_lines`, `sample_ordered_path`, `path_distance_score`, `path_orientation_scores` and `align_ruled_paths` to candidate.tcl, and rewrite the T_LIST unit tests around projection, path ordering, different segmentation counts, reversal, branches, ambiguity, fragment re-identification and rollback.
- Remove the undocumented `*setoption block_browser_update` calls from the shared browser-reset path (`workflow_common.tcl`) and the Auto Hole RBE2 / RBE2 Bolt bulk-create paths, so HyperMesh no longer prints `setoption: Invalid option specified` in the status bar on every run regardless of module outcome; browser throttling now uses the documented `hm_blockbrowserupdate` command exclusively.
- Fix the geometry seam module's HyperMesh API usage found by the 2026-08-07 audit: correct `*offset_surfaces_and_modify` argument order in EXTEND (reserved `surf_mark_id`/`line_mark`, legal `offset_type`, real signed offset), restore distinct source/target marks and a legal `trim_mode` for `*connect_surfaces_11`, verify the Current Component before every native call instead of swallowing `*currentcollector` failures, fail fast on critical `*createmark` failures, source plate thickness from `hm_getthickness` with the Component-name `_Txx` parser as a logged fallback, pin and restore the session `cleanup_tolerance` around `*multi_surfs_lines_merge`, make T-surface distance/angles configuration-driven with an optional gap-adaptive distance, and report global surface diffs with owner/area diagnostics so "nothing was created" is distinguishable from "created in the wrong component". L_SURF's Boolean error message no longer claims an intersection for the reviewed Union opcode (switch via `lap_boolean_opcode` after real-kernel Experiment 1), undocumented commands (`*trim_solids_by_surfaces`, `*edgesmarkaddpoints`, `hm_private_frwk`) are isolated in the new `native_compat.tcl`, state restore uses `hm_entityinfo geometryvisible/elementsvisible` and only touches pre-existing components, `*projectpointstoedges` uses an explicit positive tolerance, component creation no longer opens nested history blocks under the seam transaction, and candidate-mode failures surface through `show_result`. Add API-contract, EXTEND wrapper, mark-ownership, current-component, thickness-source and cleanup-tolerance tests (43 -> 56).
- Remove the geometry seam module's automatic recognition and automatic seam-building flows (analyze/candidate/classifier UI, auto-confidence settings, forced joint/strategy, shortcut scope selector); only precise, manually confirmed creation remains. Extend the settings panel with the remaining audit-configurable parameters: `extend_offset_type`, `extend_connect_trim_mode`, `t_surface_trim_mode`, `topology_connection_required`, `private_history_api` and `use_public_query_apis` for HM2019/HM2022 behavior comparison, plus judgement-strictness controls (`area_tolerance`, `volume_tolerance`, `cleanup_tolerance`, `endpoint_merge_tolerance`) and geometry parameters (`geometry_offset_distance`, `connect_*`, `lap_connect_distance`, `replace_point_projection_distance`, `diagnostic_preserve_failed_geometry`) (tests 56 -> 64).
- Replace FEM Automatic Seam's incremental import-merge with a file-level pipeline: the standalone `before.hm` backup is the only rollback point, the whole model is exported once, Python edits the FEM file itself (shell topology plus verbatim passthrough of non-shell cards), HyperMesh reopens the modified FEM with File > Open semantics to replace the current model, and the ordered chunked native remesh runs directly on the new model. Detection stays scoped to the selected components even though the input FEM now covers the complete model, per-candidate delta files and the combined delta are no longer written, and the second full-model snapshot during execution was removed.
- Add a Batch Temporary Nodes module with multiline `X,Y,Z` input, full-batch validation, rollback on creation failure, and undo for the most recent batch.
- Accelerate FEM Automatic Seam detection with component AABB pruning plus conservative uniform-grid indexes for ray/element and free-edge searches, while retaining the original exact geometry tests and deterministic candidate ordering. Record mesh read, detection, duplicate-check, planning and artifact-write timings separately.
- Scale FEM Automatic Seam to whole-vehicle selections: discover T targets from each free-edge sweep, run large detection jobs in configurable multi-process partitions, cap pathological spatial-index expansion, keep the HyperMesh UI event loop and cancellation active while Python runs, force-terminate timed-out worker trees without blocking on pipe close, and remesh connected regions in bounded native chunks. Remove the redundant whole-model restore after planning/transfer failures and the second restore after native execution has already rolled back.
- Make post-detection FEM Automatic Seam planning linear in vehicle size plus local candidate work: clone the selected model once, realize all accepted candidates sequentially in that single accumulated model, journal and roll back only each candidate's local source edits, preserve per-candidate delta rows at creation time, and maintain the component-element index incrementally instead of copying, set-differencing and rescanning the complete vehicle for every candidate.
- Launch FEM Automatic Seam multiprocessing children through the bundled `pythonw.exe` on Windows so parallel detection no longer flashes CMD windows. Publish the actual worker count through a task-local stage file and show it with continuously updating elapsed time in the existing progress command stream.
- Make FEM Automatic Seam candidate imports resilient to HM2019 partial reads: retry only missing GRID/shell cards through a focused repair FEM; reject degenerate shells and connectivity duplicates against both the current model and the same candidate during Python planning; verify all external GRID dependencies before mutation; and report the candidate/FEM/card/component/connectivity details if the focused retry still fails. Preserve the complete failed-task diagnostics for the configured 30-day failure-retention window instead of immediately deleting everything except `before.hm`; the task-level snapshot remains the final safety boundary.
- Replace FEM Automatic Seam's Python neighborhood smoothing and per-candidate checkpoints with topology-only Python planning followed by one task-scoped HyperMesh element automesh batch. Expand replacement-shell seeds in the live model, fix seam/interface and patch-boundary nodes, commit all temporary faces once, retain native criteria validation, and restore only the task-level `before.hm` on failure.
- Advance BatchMesher to 2.6 and standardize every HM2019/2022 launch on Altair's non-interactive `-nocommand -nouserprofiledialog -tcl` form. The ordinary Validate action and every production run now execute a real hmbatch Tcl/API preflight before any connectivity worker can launch, recording the reported version, actual executable and working directory; warn when a saved concurrency above the two-process live-validation limit is reused.
- Make `install_update.tcl` perform a verified live-session replacement: terminate known BatchMesher children and the persistent Python worker, cancel old HMWorkFlow callbacks, remove stale module namespaces, reload all modules from the selected update root, validate the current BatchMesher launch/profile fixes, and write a per-HyperMesh `install_update.log`. Mark BatchMesher hmbatch children so `shortcut_bootstrap.tcl` skips interactive shortcuts and the unrelated warm Python worker.
- Fix the HyperMesh 2022 worker profile initializer so it reads the shared worker configuration from its Tcl namespace before loading the OptiStruct template and quality criteria; previously every 2022 task failed before `*hm_batchmesh2`, while the 2019 path bypassed the faulty branch.
- Start every BatchMesher hmbatch process from its own worker directory, distinguish an Altair launcher PID from the real worker state handshake, allow HM2022 up to 120 seconds to initialize, and always write manager-side `launch.log` / `manager_failure.log` diagnostics even when hmbatch stdout and stderr remain empty.
- Move BatchMesher execution to detached HyperMesh workers with polled per-group progress, actionable failure summaries, real process-tree cancellation, and one-shot automatic import of the complete merged result with delta verification and rollback.
- Fix the Windows background-process liveness regex so Tcl does not interpret the `[^0-9]` character class as command substitution during progress polling.
- Give hmbatch a startup grace period and make the generated launcher persist pre-worker source errors to `launcher_error.log` and `background.state` instead of reporting only a missing FEM.
- Restore the proven direct Tcl launch path for `hmbatch.exe -tcl ...`, without a PowerShell wrapper or PID handshake.
- Show one optional consolidated CMD monitor for the entire run; it refreshes phase/PIDs/task counts and closes automatically three seconds after completion without controlling worker lifetime.
- Execute independent Surface connectivity groups in isolated parallel hmbatch workers with a configurable concurrency limit, retain each task FEM, combine the results into one archival FEM, and automatically import the complete result once.
- Integrate the real-machine findings: accept `22.000000`, support 2019/2022 worker releases, initialize the 2022 OptiStruct profile and quality criteria, track the actual hmopengl PID, default to two workers, and detect configuration changes. Every worker strips its native model to the newly created mesh without re-importing FEM; `*mergefile` combines those models, exports `batchmesh_result.fem`, and merges the native result into the current session once. Remove the HM2019 FEM translator fallback after it returned zero imported elements, and prevent embedded hmbatch `exit` behavior from overwriting failed states with false completion.
- Decouple the selected hmbatch release from the interactive HyperMesh release. Accept any supported 2019/2022 pairing, detect the worker release inside hmbatch, and use that installation's OptiStruct template and profile initialization.
- Rebuild BatchMesher result handling around native semantics: any newly created elements are a usable mesh even when quality optimization reports a warning; meshing, native packaging and FEM archival statuses are independent; workers no longer delete geometry, nodes or collectors; and every successful task uses the same native merge stage.
- Replace full-snapshot HM aggregation after a production HM2019 run proved that the second `*mergefile` can terminate hmbatch outside Tcl error handling. Aggregate each independently valid worker FEM in a blank model with documented `overwrite_flag=0` ID offsetting, verify every Element delta, save a clean merged HM, export one final FEM, and retain worker HM files only for recovery.
- Fix worker decks that imported only GRID cards in HM2019: replace per-entity `*feoutput_select` with custom Component-state `*feoutputwithdata`, verify the created-element mark before export, use the OptiStruct reader's default property handling during aggregation, and log the selected export/import modes explicitly.
- Replace end-of-poll batch replenishment with a fixed-capacity sliding worker pool. A terminal or dead worker now releases its slot and launches the next pending connectivity group immediately, before slower process-liveness checks for the remaining workers; expose active/target/queued pool counts in the CMD monitor.
- Add the reviewed `FAST_AUTO` mesh-seam mode: shared shell topology detection, T/CONNECT/lap classification, existing/optionally adjusted edge paths, bounded node movement with geometry guards, quad-dominant zipper planning, per-candidate incremental FEM creation and checkpoints, native-quality baseline verification, rollback, reports, and the Weld Integrity Check creation bridge. The legacy imprint/ruled workflow remains available as `LEGACY_MANUAL`; target-node movement and local split are default-off pending HM2019 validation.
- Add the default-off V3 conservative local split for a single planar CTRIA3/CQUAD4 crossed between two unshared boundary edges. It emits stable GRID/replacement/weld IDs, preserves mother PID/component and area/winding, validates stale connectivity before deletion, and participates in candidate rollback. Add execution timing/cancellation audit, richer HTML output, three generated smoke cases, and a JSON/memory benchmark. Multi-shell split propagation remains manual and real HM2019 verification is still required.
- Local Mesh Optimizer now grows narrow-quad expansion plans from failed seeds across non-failed contiguous strip cells, exports one-ring shell topology context for cross-component weld classification, and allows prevalidated support cells to execute in the coordinated Tcl move batch.
- Add HyperWorks 2022 new-interface detection and explicit UTF-8 Tcl loading across startup and nested module loaders to prevent Chinese UI mojibake.
- Make HyperWorks 2022 entity selection fall back to the guide-bar edit widget when panel-mark creation fails, and serialize native FEM import/export while handling hidden translator prompts and stale output files.
- Stabilize persistent-worker startup, heartbeat, shutdown, log compaction, and diagnostics.
- Move user state to `%APPDATA%` and cache/task data to `%LOCALAPPDATA%` or an explicit scratch directory.
- Add task tokens, metadata, success/failure retention, pinning, quota cleanup, detached cancellation, timeout, and process-tree termination.
- Add explicit OptiStruct engineering context and block model mutations when project units are not confirmed.
- Migrate Local Mesh Optimizer and Solid Seam Connector to shared HybridCore task/result services while retaining their legacy compatibility paths.
- Add Local Mesh Optimizer criteria-based Python quality simulation, minimum-step narrow-cell expansion, and region-by-region rollback instead of whole-task rollback.
- Bound Local Mesh Optimizer quality simulation to each candidate's local submesh, index duplicate triangle lookups, and expose detailed Python build-stage progress for large models.
- Coordinate continuous boundary and weld-strip quad expansion as whole node chains; detect one-sided versus two-sided weld movement from adjacent component shell normals.
- Add a safe, size-limited sidecar loader and a binary result envelope for migrated production paths.
- Add the `hmworkflow` Python namespace so all module tests can be collected together without same-name import collisions.
- Correct HM2019 PBEAM/PBAR HyperBeam association and verify it through real `hmbatch.exe` import.
- Add module capability metadata and a repeatable four-case HM2019 integration matrix.
- Add release metadata, whitelist packaging, archive auditing, offline test gates, and markdown-link checks.
- Audit the Git tracking list, remove generated Local Mesh fixtures and a machine-specific runtime validation script from the index, and enforce repository hygiene in the offline test gate.
- Package portable Python from approved file levels only; the locally unpacked `python38/` directory is rejected by both staging and release audit.
