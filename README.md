# LVSEngine

Layout-versus-schematic engine with protocol-composed backends, a canonical
hierarchical graph, deterministic bounded matching, deck-driven physical
extraction, and evidence-bound qualification. Backend selection is derived from
fresh process/profile/deck-specific ToolQualification evidence. The capability
snapshot never declares production maturity by itself. Netgen is the independent
qualification oracle for the retained Sky130 corpus.

The current production eligibility decision is deliberately narrow:

| Scope | Status | Evidence |
|---|---|---|
| `sky130.open-pdk.digital-mos.signoff` | The exact archived binary selected by the retention index is production-eligible for Sky130 1.8 V digital-MOS physical extraction | `../ci-artifacts/signoff/lvs-production/retention-index.json` |
| Any other process, deck digest, binary digest, algorithm, or physical device family | Blocked until separately qualified | `../docs/lvsengine-production-eligibility-decision.md` |

## Modules

| Module | Responsibility |
|---|---|
| `LVSCore` | `LVSRequest` / `LVSResult` / structured mismatch diagnostics, `LVSBackend` protocol, typed errors |
| `LVSNative` | `NativeLVSBackend` (`native`) and `LayoutGDSLVSBackend` (`native-gds`) |
| `LVSParsers` | Netgen report parsing into typed mismatches |
| `LVSAdapters` | Netgen batch invocation (`lvs.tcl`), tool-gated |
| `LVSExtractionAdapters` | LVS input preparation only: Magic layout-to-netlist extraction (`extract_lvs.tcl`) |
| `LVSPersistence` | Protocol-first LVS artifact persistence and compact run summary building |
| `LVSRuntime` | `LVSEngineRunning` protocol, backend registry, and default engine composition |
| `LVSEngine` | Umbrella module |
| `LVSCLICore` / `lvsengine` | Testable CLI core + executable |

Library consumers depend on `LVSEngineRunning` and `LVSArtifactPersisting`; the
provided implementations are `DefaultLVSEngine` and `LVSArtifactStore`.
Backends and layout extraction remain independently injectable through
`LVSBackend` and `LVSLayoutNetlistExtracting`.

## Backend IDs

`LVSNative`, `native`, and `native-gds` are the only current Swift and CLI
surfaces for the in-process LVS path. Removed implementation-language backend
IDs are rejected with a typed backend-selection error.

## Capability snapshot

Agents should use `lvsengine --capabilities --json` before selecting a backend or
claiming release readiness. The command emits `LVSCapabilitySnapshot`, a stable
JSON contract that lists the current backends, whether a backend needs an
external tool, supported input formats, produced artifacts, diagnostics,
required observed corpus assertions, Agent-facing contracts, and the evidence
binding used for backend selection. It describes implemented surfaces and
qualification requirements, not current production eligibility.

```bash
lvsengine --capabilities --json
```

The snapshot is intentionally separate from `--action-domain`: `--action-domain`
describes executable planning operations, while `--capabilities` describes the
trust surface and evidence contract for standalone LVS.

## Foundry deck semantic inspection

`lvsengine --foundry-deck-semantics --json` emits the shared
`signoff-foundry-deck-semantics` artifact for the LVS side of the Sky130 foundry
deck contract. The command uses `SignoffToolSupport.SignoffDeckSemanticInventory`
with the Netgen LVS requirement only, so a missing Magic DRC tech deck does not
block LVS deck inspection. Add `--pdk-root <path>` to point at an explicit PDK
root or direct `sky130A` root. Add `--require-passed` when CI or an Agent needs a
non-zero exit status for missing LVS deck readiness or missing LVS semantic
coverage.

```bash
lvsengine --foundry-deck-semantics --pdk-root ~/.volare --require-passed --json
```

## Netgen device seed import

`NetgenLVSDeviceDeckImporter` and `lvsengine --import-netgen-devices` are the
process-independent entry points for converting a Netgen setup deck into an
Agent-readable `lvs-device-policy-seed`. The import preserves device names,
inferred device families, and pin/policy declarations such as `permute`,
`property`, `equate`, `equate pins`, `ignore class`, and `blackbox`. `foreach`
blocks over device and circuit cell lists are expanded when their values are
static. Runtime `regexp` selectors such as `$cell` are retained as typed
predicates, including capture variables, then resolved against the compared
subcircuit models during `--device-policy` application. Non-semantic Tcl control
commands such as `catch` do not make an otherwise complete import partial. The companion
`lvs-foundry-device-import-report` records the source lines, counts, status, and
diagnostics.

```bash
lvsengine --import-netgen-devices \
  --netgen-setup /path/to/pdk/libs.tech/netgen/process_setup.tcl \
  --policy-out /tmp/lvs-device-policy.json \
  --report-out /tmp/lvs-device-import.json \
  --json
```

Use `--require-complete` when a CI or Agent gate must fail on blocked or partial
imports. JSON stdout returns artifact paths, the import report, and a compact
`seedSummary`; the full expanded seed is written to `--policy-out` so Agent
callers do not need to parse a large policy body from stdout.

`lvsengine --audit-netgen-device-import` turns the seed and import report into a
separate `lvs-device-import-audit` artifact. Use `--require-satisfied` when the
gate must fail unless required device families, policy rule kinds, imported
counts, and unresolved policy-rule limits are all satisfied.

```bash
lvsengine --audit-netgen-device-import \
  --policy-seed /tmp/lvs-device-policy.json \
  --import-report /tmp/lvs-device-import.json \
  --audit-out /tmp/lvs-device-import-audit.json \
  --require-satisfied \
  --json
```

`lvsengine --import-foundry-netgen-devices` locates the selected installed-PDK
Netgen setup deck through the signoff profile catalog, then routes into the same
generic Netgen importer:

```bash
lvsengine --import-foundry-netgen-devices \
  --pdk-root ~/.volare \
  --policy-out /tmp/sky130-lvs-device-policy.json \
  --report-out /tmp/sky130-lvs-device-import.json \
  --json
```

JSON stdout includes the same `seedSummary` and import report plus
the foundry semantic report used to resolve the deck.

## Native device policy consumption

`NativeLVSBackend` can consume the imported `lvs-device-policy-seed` through
`LVSRequest.devicePolicyURL` or the CLI `--device-policy <path>` flag. The
current native consumer applies concrete Netgen `permute` rules, including
rules expanded from Sky130 `$dev` loops, to
`LVSTerminalEquivalencePolicy` and consumes concrete Netgen `property delete`
rules as model-scoped parameter comparison exclusions plus concrete Netgen
`property tolerance` rules as model-scoped numeric parameter tolerances. The
same native consumer handles concrete Netgen `equate pins` rules as
conservative same-family model-pair equivalence while preserving pin-order
comparison through the native terminal resolver, and concrete Netgen
`property parallel` rules for same-topology parallel device aggregation, with
`add` parameters summed and `critical` or other
non-additive comparable parameters still required to match within tolerance.
It consumes concrete Netgen `property series` rules for conservative one-chain
series aggregation: the native matcher requires the same model, same fixed pins,
a non-branching internal-node chain, additive numeric parameters, and matching
critical / non-additive comparable parameters. It also consumes concrete Netgen
`model blackbox` and model-scoped `property ... blackbox` rules conservatively:
blackboxed subcircuit models are preserved as boundary components instead of
being flattened, blackboxed model parameters are ignored, and pins / model names
/ instance counts remain checked. It writes an
`lvs-device-policy-application-report` inside the normal LVS report JSON and
emits structured `devicePolicy` diagnostics for applied and ignored policy
rules. The report carries `policyRuleCount`, `policyRuleCountsByKind`,
`appliedRuleCountsByKind`, `ignoredRuleCountsByReason`,
`unobservedRuleCountsByKind`, and `unobservedRules`, and the same compact policy
summary is projected into the artifact manifest and CLI `runSummary` so Agent
callers can gate on policy coverage without scraping full rule arrays. Runtime
`$cell` selectors that cannot resolve to a compared subcircuit model with a
`.subckt` definition remain in the application report instead of being silently
treated as parity. Runtime `equate classes` / `equate pins`, circuit-scoped
`ignore class`, Netgen `permute default` / `property default`, and named
resistor terminals are consumed without ignored rules. Policy-aware native-GDS
extraction also selects the SPICE geometry encoding convention that matches the
schematic, avoiding micron-versus-suffixed-unit mismatches.

Corpus cases may set `devicePolicyDeckPath` to import and audit a Netgen deck
before native execution. The corpus persists the generated policy, import
report, and audit, and can require `devicePolicyImport`,
`devicePolicyApplication`, and `devicePolicyRule` observed assertions. A case
cannot declare both `devicePolicyPath` and `devicePolicyDeckPath`.

```bash
lvsengine \
  --layout-netlist extracted.spice \
  --schematic-netlist schematic.spice \
  --top-cell top \
  --device-policy /tmp/sky130-lvs-device-policy.json \
  --out /tmp/lvs-run \
  --json
```

When `native-gds` receives `--device-policy`, it writes the extracted layout
netlist as an intermediate SPICE artifact and reuses the same policy-aware native
comparison path, so equate pins, property blackbox, explicit model blackbox
boundary preservation, runtime `$cell` blackbox boundary preservation, and
mixed blackbox-plus-extracted-device top cells, plus property delete / tolerance
/ parallel / series behavior and applied / ignored policy diagnostics, are
still emitted from standard mask inputs.
Full foundry LVS benchmark parity still needs non-digital device-recognition
families, physical analog and hierarchical extraction qualification, broader
device-recognition-time policy semantics, and runtime `$cell` golden agreement.

## Unsupported policy handling

Unsupported or unresolved imported device-policy declarations are retained in
`lvs-device-policy-application-report.ignoredRules` with a typed `reasonCode`
and source-line metadata, and `ignoredRuleCountsByReason` gives Agent / CI gates
a compact unsupported-policy summary. Native LVS does not silently treat
unsupported Netgen policy families, unresolved device selectors, or runtime
`$cell` selectors without a matching `.subckt` definition as parity.
Selector-matched policy declarations whose target models are simply absent from
the current compared netlists are retained separately in
`lvs-device-policy-application-report.unobservedRules` with `targetModels` and
`unobservedRuleCountsByKind`; these are coverage signals for Agent planning, not
LVS mismatches.

## Standard-input backend: `native-gds`

`LayoutGDSLVSBackend` reads GDSII/OASIS/CIF/DXF mask data, materializes a
`LayoutExtractionIR` through `LayoutLVSExtraction`, adapts it into `LVSGraph`,
and compares it with the schematic graph through the shared deterministic
matcher. Extraction issues, correspondence, graph transformations, and mismatch
diagnostics retain stable source and geometry references. Set
`LVSRequest.technologyURL` and `LVSRequest.extractionDeckURL` to select the
process deck programmatically.

The retained physical production scope is
`sky130.open-pdk.digital-mos.signoff` at the exact deck digest recorded in the
evidence. The 20-cell Sky130 physical matrix exercises GDS extraction. Analog
device and hierarchy cases in the 40-case corpus qualify SPICE graph semantics;
they do not claim analog or hierarchical physical extraction. Parser support for
other mask formats likewise requires matching retained evidence before it is
production eligible.

```bash
# Native on standard inputs (mask data + tech deck + reference netlist)
lvsengine --layout-gds design.gds --tech technology.json --extraction-deck sky130A.tech --schematic-netlist top.spice

# Explicit backend override; default without --tech is netgen
lvsengine --layout-gds design.gds --backend native-gds --tech technology.json --extraction-deck sky130A.tech --schematic-netlist top.spice
```

## Agent-facing diagnostics

Native LVS diagnostics are structured for direct API and CLI consumers. Port
mismatches populate `category`, `layoutPorts`, `schematicPorts`, and
`suggestedFix`. The SPICE backend expands defined `.subckt` instances
recursively, resolves `.include` files and selected `.lib <file> <section>`
library sections when netlists are parsed from URLs, rejects recursive includes
and library references, binds top-level `.param` values, `.subckt` default
parameters, and `X` instance overrides, evaluates braced and operator-bearing
parameter expressions with parentheses and SPICE scale suffixes, applies
top-level `.option scale` to extracted geometry-style W/L/area parameters, and substitutes
parameter references into primitive devices before comparison. A mismatch inside a hierarchical or
parameterized cell is therefore reported against the primitive topology instead
of being hidden behind a matching top-level `X` instance. Primitive comparison canonicalizes MOS
source/drain terminals and
two-terminal resistor/capacitor/inductor pins, so electrically equivalent
symmetric devices do not fail because of extraction or schematic pin ordering.
`LVSRequest.terminalEquivalenceURL` and `lvsengine --terminal-equivalence`
accept an auditable `LVSTerminalEquivalencePolicy` JSON file for PDK-specific
terminal equivalence rules. The default SPICE primitive policy stays active, and
`LVSRequest.devicePolicyURL` / `lvsengine --device-policy` can derive additional
terminal-equivalence behavior from a foundry device-policy seed while preserving
an application report for ignored policy declarations. The supplied policy is
hashed as `input-terminal-equivalence` in the artifact
manifest. Model
mismatches populate `layoutModel` and
`schematicModel`; parameter and multiplicity mismatches populate
`parameterName`, `layoutValue`, `schematicValue`, `layoutComponentName`, and
`schematicComponentName` when the native comparator can bind a unique matched
component pair; component count mismatches populate `category`,
`componentSignature`, `layoutCount`, `schematicCount`, and `suggestedFix`, so an
Agent can distinguish topology, model, parameter, and port-order failures without
scraping a text log.
The SPICE parser folds `+` continuation lines and strips boundary-delimited
inline `$` / `//` comments before tokenization, so comment text containing
`name=value` fragments cannot become false device or subcircuit parameters.
Primitive comparison also normalizes SPICE numeric scale suffixes for component
parameters and passive R/C values, so equivalent values such as `1u`, `1000n`,
and `1e-6` compare as the same value while mismatch diagnostics still report the
original netlist strings.

`lvsengine --json` emits the full diagnostics array, `runSummary`, and the report
/ manifest paths. The persisted report contains the same structured result.
`LVSRunSummaryBuilder` is the library-level contract for compact review summaries:

```swift
let runSummary = LVSRunSummaryBuilder().build(result: executionResult)
```

The summary keeps the full report as the source of truth while exposing typed
execution status, verification verdict, readiness, blocking reasons,
active/waived mismatch counts, unused waivers, optional
extracted layout netlist path, and grouped category/signature/model/parameter
mismatch buckets for Agent / CI / Human review.

Saved reports can also be converted into typed repair hints without scraping
logs:

```bash
lvsengine --repair-hints-from-report lvs-report.json --json
```

`LVSRepairHintBuilder` maps active, unwaived port diagnostics into
`layout.add-label`, model and terminal-equivalence diagnostics into
`lvs.policy-repair`, and numeric parameter or multiplicity diagnostics with a
matched layout component into `simulation.set-netlist-parameters`. Parameter
repair hints include the layout-side assignment name, SPICE-scale-normalized
target value, source/target raw values, component names, and `native-lvs` /
`artifact-integrity` gates so `Xcircuite` can turn an engine-owned mismatch into
an executable netlist edit candidate while still requiring LVS re-verification.

## Waivers

`LVSRequest.waiverURL` and `lvsengine --waivers <waivers.json>` apply
diagnostic-level waivers before pass/fail is folded. A waived error keeps
`severity = error`, gains `waiverID` / `waiverReason`, increments
`diagnosticSummary.waivedErrorCount`, and no longer contributes to
`diagnosticSummary.errorCount`. A waiver never changes a mismatch or blocked
verification verdict into a match.

The waiver file is saved as an input artifact with a digest. The report and
manifest both include `waiverReport`, including unused waiver IDs so stale policy
entries remain visible.

## Corpus mode

`LVSCorpusRunner` and `lvsengine --corpus <corpus.json> --out <dir> --json` run
multiple LVS cases and compare each result against expected pass/fail, active
error rule IDs, optional oracle backend agreement (`oracleBackendID`), and
optional duration budgets (`defaultMaxDurationSeconds` or per-case
`maxDurationSeconds`). Cases declare typed assertion requirements. The runner
records each assertion as `passed`, `failed`, or `blocked` with source artifact
references, and qualification coverage is derived only from passed observations.
A case may also
declare a `generatedLayoutFixture` so the corpus runner writes a deterministic
standard-layout input, such as a GDSII/OASIS/CIF/DXF file plus technology deck,
before invoking the backend. This keeps the `native-gds` device/connectivity extraction lane
under the same qualification policy as SPICE-layout comparison semantics. Each case writes
its normal LVS report and artifact manifest under the corpus output directory. If
an oracle backend is specified, its report, manifest, and extracted-layout netlist
path are written under the case directory as separate artifacts. The top-level
`lvs-corpus-report.json` includes
per-case results, an aggregate `summary`, and a durable `qualification` result
for Agent / CI consumers. Corpus specs may declare `qualificationPolicy`; when
absent, the strict policy requires every case, duration budget, and oracle
agreement gate to pass. The summary exposes pass rate, expectation-matched case
count, duration-budget pass count, primary/oracle execution failure counts,
oracle agreement rate, and `failureCategoryCounts`. The qualification result
records the policy, a boolean `qualified` verdict, and typed failure codes such
as `pass_rate_below_minimum`, `duration_budget_pass_rate_below_minimum`, or
`required_observed_assertion_missing`, or `oracle_execution_failed`. The summary also
includes `observedAssertionCounts`, failed assertion count, and blocked assertion
count. `lvsengine --corpus` uses
`qualification.qualified` for its exit status, so Agents and CI can rely on the
same persisted gate they review later.

A mixed production corpus declares `qualificationScopeCaseID`. The referenced
case selects the exact process/deck/build identity exported to ToolQualification.
Other process-specific cases must have the same identity. Process-neutral
semantic cases are accepted only when they use the same implementation ID and
binary digest; they support matcher qualification but cannot become the selected
physical production scope.
Saved reports can be rechecked without rerunning the corpus:

```bash
lvsengine --qualify-corpus-report lvs-corpus-report.json --json
lvsengine --qualify-corpus-report lvs-corpus-report.json \
  --qualification-policy qualification-policy.json --json
```

The same immutable report can also be exported as ToolQualification-compatible
evidence for an Agent or flow runtime config:

```bash
lvsengine --evidence-from-corpus-report lvs-corpus-report.json \
  --evidence-id lvs-release-corpus \
  --out /tmp/lvs-tool-evidence.json \
  --checked-at 2026-06-18T00:00:00Z \
  --json
```

The JSON includes `toolEvidence.kind == "corpus"`, an ISO 8601 `checkedAt`, the
report artifact reference and digest, and a generic `qualification` summary with
pass-rate, duration-budget, oracle-agreement, coverage-count, count, and typed
failure-code fields. The command exits with the same pass/fail convention as the embedded
qualification verdict, so CI can gate on it while Agents can copy the
`toolEvidence` object into `XcircuiteFlowToolSpec.evidence`.

For richer Agent and human decision material, the same retained corpus report can
also be exported as an LVS evidence packet:

```bash
lvsengine --evidence-packet-from-corpus-report lvs-corpus-report.json \
  --out /tmp/lvs-evidence-packet.json \
  --packet-id lvs-evidence-release \
  --json
```

`LVSEvidencePacket` includes corpus readiness, extracted layout netlist
references, oracle comparison readiness, normalized summary views, metrics,
structured mismatch diagnostics, confidence derived from observed assertions,
and decision hints.
It is decision material for inspection, repair planning, waiver review, or
rerun selection; it is not a fixed flow or an automatic repair plan. A failing
corpus report can still export a packet when retained diagnostics or extracted
layout-netlist artifacts are usable.

The optional policy file uses the same `LVSCorpusQualificationPolicy` JSON shape
as `qualificationPolicy` in a corpus spec. This lets CI or an Agent apply a
stricter or looser release gate to immutable corpus evidence without changing the
original run artifacts.

A primary backend failure is recorded as `primary_execution_failed:*` on the case
result. An oracle backend failure is recorded inside `oracleResult` as
`oracle_execution_failed:*` and also fails the case agreement gate, so missing
external tools leave a reviewable report instead of aborting the corpus run.

Corpus paths are resolved relative to the corpus spec file, which makes committed
fixtures portable across machines and CI runners.

Saved corpus reports can be audited against a same-case observed-assertion
coverage policy:

```bash
lvsengine --audit-corpus-coverage lvs-corpus-report.json \
  --coverage-policy coverage-policy.json \
  --checked-at 2026-07-12T00:00:00Z \
  --out lvs-corpus-coverage-audit.json \
  --json
```

`LVSCorpusCoverageAuditPolicy` is a current-only schema-v2 trust contract.
Unsupported schema versions, empty or duplicate requirement IDs, empty
assertion sets, invalid case thresholds, and invalid freshness thresholds are
rejected when decoded. Programmatically constructed invalid policies produce an
incomplete audit instead of weakening the gate. Netgen device-import audit
policies apply the same fail-closed rules to schema and count thresholds.

The LVS action domain describes both engine-owned operations and the approved
policy-repair handoff. Policy mutation, planning-problem generation, and design
diff persistence are owned by `Xcircuite`; LVSEngine produces the diagnostics
and typed repair hints consumed by that executor.

For hierarchical standard-layout extraction, descendant labels and pins name
their local flattened conductor nets but do not declare top-level LVS ports.
Only labels and pins owned by the selected top cell define the top-port contract.
Hierarchy, array, and blackbox fixtures therefore declare their externally
visible labels on the top cell explicitly. The extractor and GDS round-trip
tests retain a child-only label to prevent descendant-port leakage from
regressing.

The committed CLI golden corpus lives under
`Tests/LVSCLICoreTests/Fixtures/LVSCorpus`. It covers native standard-mask
extraction for sample-process NMOS across GDSII/OASIS/CIF/DXF, PMOS and flat
CMOS inverter layouts through GDSII, native-gds policy cases proving extracted
parallel and series NMOS arrays consume persisted Netgen-style device policy
seeds, a matching pair, an active
port-order mismatch, an active model/signature mismatch, an active primitive
parameter mismatch, a hierarchical subcircuit model mismatch detected after
recursive flattening, a subcircuit-parameter override mismatch detected after
parameter binding, a symmetric-terminal match case for MOS source/drain and
passive two-terminal pin order, a policy-driven diode terminal-equivalence case
whose policy is persisted as an input artifact, a numeric-equivalent
parameter/passive value case using SPICE scale suffixes, a `.lib` section case
that resolves a selected standard-cell library corner, a SPICE parameter
expression case that resolves `.param`, `.subckt`, and primitive-device
expressions before comparison, a `.global` supply net case that matches against explicit top supply
ports, a diode/BJT device breadth case, an inductor and source-device breadth
case covering `L`, `V`, `I`, `E`, `G`, `F`, and `H` SPICE primitives, a
multiplicity case proving `M=2` is equivalent to two parallel devices, a model
equivalence policy case that hashes the alias policy as an input artifact, a
SPICE continuation / inline-comment case that prevents comment parameters from
affecting comparison, and the model/signature mismatch
accepted only through an explicit diagnostic waiver, each with a public CLI
oracle result and observed assertions for diode/BJT/inductor/source device
breadth, standard mask input (GDSII/OASIS/CIF/DXF), NMOS/PMOS/CMOS inverter
extraction, standard-input policy extraction, multiplicity/parallel/series-device
equivalence, model alias policy, global nets, hierarchy, match, port mismatch, model mismatch, primitive parameter
mismatch, numeric parameter normalization, subcircuit parameter binding,
symmetric terminal handling, MOS source/drain permutation, passive
two-terminal permutation, terminal-equivalence policy, SPICE include resolution,
SPICE library section resolution, top-level parameter binding, SPICE parameter
expression evaluation, continuation-line folding, inline-comment
stripping, and waiver behavior. The
tight-budget fixture proves that a correctness-clean run still fails the corpus
gate when it exceeds its declared benchmark budget. CLI tests additionally prove
that a correctness-clean corpus fails when required observed assertions are missing.
Runtime tests additionally inject disagreeing backends to prove oracle mismatch
fails the corpus gate.

## Result convention

`result.executionStatus` records whether execution completed, while
`result.verdict` records `match`, `mismatch`, or `blocked`. A pass requires
completed execution, a match verdict, ready tool state, no blocking reasons, and
no active unwaived error. Missing or uncertain state is never interpreted as a
match.

## Build & test

```bash
perl -e 'alarm 180; exec @ARGV' xcodebuild build \
  -scheme LVSEngine-Package -destination 'platform=macOS'
perl -e 'alarm 300; exec @ARGV' xcodebuild test \
  -scheme LVSEngine-Package -destination 'platform=macOS'
```

Netgen/Magic-gated suites skip themselves when the tools are absent. Release
qualification must additionally run the committed 40-case production corpus
with the independent Netgen oracle and retain the exact executable digest.
