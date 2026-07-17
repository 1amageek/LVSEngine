# LVSEngine Design Contract

## Responsibility

LVSEngine compares schematic and layout connectivity, performs optional
layout-netlist extraction, applies device and terminal equivalence policy,
and records a fail-closed verdict with readiness and blocking reasons.

```mermaid
flowchart TD
    Input["Layout + schematic + process artifacts"] --> Validate["Request / budget / profile integrity validation"]
    Validate --> Extract["Native extraction or external extraction adapter"]
    Extract --> Match["Hierarchical graph match"]
    Match --> Domain["LVSResult + correspondence"]
    Domain --> Persist["LVS artifact manifest"]
    Domain --> Flow["Flow coordinator / Agent"]
```

## Foundation integration

`LVSExecuting` refines `CircuiteFoundation.Engine` with
`LVSRequest`/`LVSExecutionResult`. `DefaultLVSEngine.execute` delegates to the
existing `run` path so timeout, cancellation, extraction, waiver, and
persistence behavior remains unchanged.

The domain result retains its fail-closed verdict, diagnostics, correspondence,
and artifact manifest directly. No projection silently hashes or blesses an
unverified report URL.

`LVSRequest.designObjectReference()` gives the requested top cell a stable
Foundation identity. Hierarchical correspondence remains an LVS concern.

## Responsibility boundary

| Concern | Owner |
|---|---|
| Extraction, graph matching, equivalence policy | LVSEngine |
| Raw execution evidence and independent-oracle observations | LVSEngine |
| Tool/deck qualification and trust policy | ToolQualification / flow policy |
| Shared evidence/artifact vocabulary | CircuiteFoundation |
| Project state, approvals, resume orchestration | Xcircuite / DesignFlowKernel |

Native LVS may establish a useful development result, but production
qualification still requires the existing independent-oracle and PDK gates.
Native layout extraction consumes a versioned process-owned profile and its
source deck. Profile schema, semantic completeness, identity, and deck digest
must validate before geometry extraction begins; no process default is embedded
in the engine.
