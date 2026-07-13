# LVSEngine Requirements

## Required boundary

- Depend on `CircuiteFoundation` for the engine and cross-engine evidence
  vocabulary.
- Expose `LVSEngineRunning` as a Foundation `Engine` contract.
- Keep extraction, graph, matching, waiver, correspondence, and qualification
  models in LVSEngine.
- Provide `LVSFoundationEvidence` with typed diagnostics and explicit
  provenance/artifact inputs.
- Provide `LVSRequest.designObjectReference()` for top-cell addressing.
- Preserve blocked and mismatch states; never collapse extraction failure or
  incomplete readiness into `match`.

## Non-goals

- Foundation does not own netlist semantics or matching policy.
- LVS does not own project lifecycle or human approval.
- A native result is not automatically a foundry-qualified signoff result.

## Verification

`swift build` must pass. LVS tests must continue to cover parser boundaries,
graph matching budgets, native extraction, external adapters, persistence,
qualification evidence, and fail-closed diagnostics.
