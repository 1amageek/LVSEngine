# ADR 0001: LVS result v2 and canonical verification authority

- Status: accepted
- Date: 2026-07-12

## Context

The previous native implementations inferred pass from process completion and active diagnostics. The SPICE path grouped components by signatures containing literal net names, while the standard-layout path also exposed a direct comparator. Policy or extraction uncertainty could therefore be represented as a warning and still pass. Corpus and capability claims were not sufficient production evidence.

## Decision

1. The authoritative final state is `LVSExecutionStatus × LVSVerificationVerdict × LVSReadinessStatus`.
2. `passed` is true only for `completed × match × ready` with no active error.
3. Policy, extraction, matcher-budget, timeout, cancellation, artifact, and trust uncertainty are `blocked` and non-waivable.
4. `LVSGraph` is the canonical semantic IR. `LVSMatching` is the only production comparison authority.
5. Device, net, and port correspondence is a required retained artifact.
6. Layout extraction owns a neutral, process-deck-derived extraction IR. LVSEngine adapts that IR into `LVSGraph`; the extraction package does not depend on LVSEngine.
7. Production eligibility is process-profile and deck-digest specific. Native capabilities remain production-blocked until independent-oracle, bounded-execution, retained-run, consumer-migration, and legacy-removal gates pass.

## Current contract

Result v2 is the only decodable result contract. Literal-signature and direct-comparator paths have been removed after graph-local policy transformations and consumer migration.

## Removal gate

The migration is complete only when source inventory proves there is no authoritative literal topology signature, direct standard-layout comparator, self-oracle promotion, tag-only qualification, or static native production maturity path.
