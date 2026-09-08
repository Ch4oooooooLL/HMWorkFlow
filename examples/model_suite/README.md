# HMWorkFlow 验证模型套件（model_suite）

本目录由 `tools/model_generation/` 下的生成器**全新生成**（确定性、可一键重建）：

    python tools/model_generation/generate_all.py

每个模型文件夹含模型文件（.fem / .step）、`*_manifest.json`（机器可读描述）与 README.md（中文操作说明）。
本目录产物已在 `.gitignore` 覆盖（`/examples/**`），不参与打包。

## 模型清单

| 目录 | 模块 | 文件数 | 大小(MB) | 规模摘要 |
|---|---|---|---|---|
| adhesive_8patches | adhesive_connector | 1 | 5.83 | node_count=88824 element_count=87600 component_count=4 |
| batch_mesher_surfaces_12parts | batch_mesher | 12 | 0.33 | part_count=12 |
| batch_property_50comp | batch_property_assignment | 1 | 0.15 | node_count=2898 element_count=2208 component_count=50 |
| bolt_chain_576rbe2 | rbe2_bolt_connector | 1 | 7.63 | node_count=91198 element_count=109624 component_count=5 |
| bom_material_40comp | bom_material_assignment | 1 | 0.21 | node_count=3960 element_count=3200 component_count=40 |
| cbush_200nodes | cbush_creator | 1 | 0.21 | node_count=3844 element_count=3600 component_count=5 |
| contact_setup_10pairs | contact_setup | 1 | 3.97 | node_count=55900 element_count=53844 component_count=20 |
| fem_auto_seam_large | fem_auto_seam | 1 | 6.07 | node_count=81413 element_count=84932 component_count=46 |
| geom_cleanup_multi_feature | geometry_cleanup | 2 | 0.5 | - |
| local_mesh_opt_80k | local_mesh_optimizer | 1 | 16.99 | node_count=243242 element_count=241122 component_count=34 |
| mesh_seam_weld_large | mesh_seam_weld | 1 | 10.82 | node_count=137023 element_count=155092 component_count=46 |
| midsurf_sheetmetal_24parts | midsurf | 24 | 2.62 | part_count=24 |
| preprocess_40comp | geometry_preprocess | 1 | 0.11 | node_count=2160 element_count=1600 component_count=40 |
| seam_surface_13regions | seam_surface | 36 | 0.19 | face_count=36 region_count=13 |
| shell_washer_large | shell_washer_hole_rbe2 | 1 | 5.11 | node_count=63130 element_count=75239 washer_hole_count=401 component_count=6 |
| solid_hole_large | auto_hole_rbe2 | 1 | 9.63 | node_count=99056 element_count=98621 hole_count=52 component_count=4 |
| solid_seam_10joints | solid_seam_connector | 1 | 2.04 | node_count=30063 element_count=21400 component_count=20 |
| temp_nodes_500coords | batch_temp_nodes | 1 | 0.12 | node_count=2109 element_count=2016 component_count=1 |
| weld_integrity_30pairs | weld_integrity_check | 1 | 9.18 | node_count=123277 element_count=142472 component_count=74 |

## 生成器

| 生成器 | 输出目录 | 说明 |
|---|---|---|
| gen_midsurf.py | midsurf_sheetmetal_24parts | 抽中面：24 件钣金实体 |
| gen_geom_cleanup.py | geom_cleanup_multi_feature | 几何清理：倒角/沉台实体 |
| gen_seam_surface.py | seam_surface_13regions | 几何焊缝：13 区域开放曲面 |
| gen_batch_mesher.py | batch_mesher_surfaces_12parts | BatchMesher：12 部件曲面 |
| gen_preprocess.py | preprocess_40comp | 预处理：40 组件（同名族/SKELL） |
| gen_bom_material.py | bom_material_40comp | BOM 材料：40 组件 + setup.tcl |
| gen_batch_property.py | batch_property_50comp | 批量属性：50 组件命名矩阵 |
| gen_mesh_seam_weld.py | mesh_seam_weld_large | 网格焊缝：T/搭接 + 600 孔性能 |
| gen_fem_auto_seam.py | fem_auto_seam_large | FEM 自动焊缝：T/贴片/近边 |
| gen_weld_integrity.py | weld_integrity_30pairs | 焊缝完整性：30 组件对 |
| gen_local_mesh_opt.py | local_mesh_opt_80k | 局部网格优化：24 万单元 + 缺陷 |
| gen_shell_washer.py | shell_washer_large | 壳孔 RIGIDS：401 孔 |
| gen_solid_hole.py | solid_hole_large | 实体孔 RIGIDS：52 孔 |
| gen_bolt_chain.py | bolt_chain_576rbe2 | 螺栓连接：576 共轴 RBE2 |
| gen_cbush.py | cbush_200nodes | CBUSH：200 源节点 |
| gen_temp_nodes.py | temp_nodes_500coords | 批量临时节点：500 坐标 |
| gen_contact_setup.py | contact_setup_10pairs | 接触创建：10 对相向板 |
| gen_adhesive.py | adhesive_8patches | 模型打胶：8 条胶带 |
| gen_solid_seam.py | solid_seam_10joints | 实体焊缝：10 组接头 |
