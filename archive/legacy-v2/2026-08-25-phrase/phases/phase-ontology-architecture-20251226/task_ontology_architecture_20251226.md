# task_ontology_architecture_20251226

- task001 [x] 产出本体三层架构视图文档并明确与 automation 规则差异  
  - 产出：`doc/ONTOLOGY-ARCHITECTURE_cn.md` + phase 文档与 `.phrase/docs/CHANGE.md` 更新  
  - 验证方式：文档包含三层定义、模块映射、运行流/边界、差异说明（手动检查）  
  - 影响范围：`doc/` 与 `.phrase/` 文档

- task002 [x] 补充函数级混杂点清单与拆分建议，并解释 core-scan 作用  
  - 产出：`doc/ONTOLOGY-ARCHITECTURE_cn.md` 更新 + phase 变更记录  
  - 验证方式：文档包含函数级混杂点列表、拆分建议、`supertag-core-scan.el` 定位说明（手动检查）  
  - 影响范围：`doc/` 与 `.phrase/` 文档

- task003 [x] 提供逻辑解释与 automation dry-run 的实验脚本  
  - 产出：`supertag-test.el`（实验命令与说明）+ phase 变更记录  
  - 验证方式：`M-x supertag-test-explain-current-node` 与 `M-x supertag-test-automation-dry-run` 可加载并运行（手动检查）  
  - 影响范围：`supertag-test.el` 与 `.phrase/` 文档

- task004 [x] 澄清“逻辑层≈supertag-query”的当前态定位  
  - 产出：`doc/ONTOLOGY-ARCHITECTURE_cn.md` 增补说明 + phase 变更记录  
  - 验证方式：文档明确 `supertag-services-query.el`/`supertag-core-scan.el` 在逻辑层中的定位（手动检查）  
  - 影响范围：`doc/` 与 `.phrase/` 文档
