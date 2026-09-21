# plan_extractor_plugins_20251216: 抽取器插件体系计划

## Milestones

1. 从现有实现中抽象出“抽取器插件”的概念与职责边界（文档化现状）
2. 设计最小可行的 extractor 接口与注册机制（tech-refer 级别）
3. 在核心解析流程中接入 extractor pipeline（先做一个试点，如 tags/properties 抽取）
4. 确保与现有 sync/队列/事务架构兼容，并补充必要的测试与文档

## Scope

- 聚焦于 per-headline / per-file 的数据抽取逻辑（标签、属性、链接等）；
- 不修改现有 sync 队列与 auto-sync 维护策略，最多在需要时增加少量 hook；
- 不引入外部依赖（例如 SQL 或异步进程），优先用现有 hash-table + transaction 体系。

## Priorities

1. 先保证抽取器接口清晰、职责单一（parse once, extract many）；  
2. 再在有限范围内做一两个 extractor 试点，验证接口易用性与性能；  
3. 最后再考虑如何将更多现有逻辑迁移到插件体系下（视本阶段时间与复杂度而定）。

## Risks & Dependencies

- 抽象不当可能导致与现有代码大面积重复/冲突，需要在 tech-refer 中先画清现有调用链；
- 需要谨慎处理“现有内嵌逻辑 vs 新 extractor”的过渡期，避免双写/重复计算；
- 与 sync 阶段已有的“Read-Many, Write-Once” 约束需要保持一致，不能为插件化牺牲事务一致性。

