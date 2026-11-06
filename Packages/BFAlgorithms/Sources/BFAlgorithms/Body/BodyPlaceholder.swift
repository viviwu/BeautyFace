// Body 模块：M8 颈肩协调（见 dev_ledger.md 3.12）。
//
// - PersonMaskGrid.swift：纯 Swift 人像蒙版网格（行优先、y 向上采样）
// - NeckShoulderEstimator.swift：颈根 / 颈部中轴 / 肩线推断
// - BodyCoordination.swift：有向颈部走廊 + 蒙版约束的组合权重表
//
// 本目录不 import 任何 Apple 框架或 Foundation（ADR-005）。
