# LVSEngine

Layout-versus-schematic engine with a protocol-composed backend model. The native
in-process backends are the core signoff path; Netgen is an optional, headless-batch-only
adapter kept for oracle checks and PDK-deck agreement.

## Modules

| Module | Responsibility |
|---|---|
| `LVSCore` | `LVSRequest` / `LVSResult` / structured mismatch diagnostics, `LVSBackend` protocol, typed errors |
| `LVSNative` | `NativeLVSBackend` (`native`) and `LayoutGDSLVSBackend` (`native-gds`) |
| `LVSParsers` | Netgen report parsing into typed mismatches |
| `LVSAdapters` | Netgen batch invocation (`lvs.tcl`), tool-gated |
| `LVSExtractionAdapters` | LVS input preparation only: Magic layout-to-netlist extraction (`extract_lvs.tcl`) |
| `LVSPersistence` | LVS artifact persistence and compact run summary building |
| `LVSRuntime` | Backend registry and engine composition |
| `LVSEngine` | Umbrella module |
| `LVSCLICore` / `lvsengine` | Testable CLI core + executable |

## Backend IDs

`LVSNative`, `native`, and `native-gds` are the only current Swift and CLI
surfaces for the in-process LVS path. Removed implementation-language backend
IDs are rejected with a typed backend-selection error.

## Capability snapshot

Agents should use `lvsengine --capabilities --json` before selecting a backend or
claiming release readiness. The command emits `LVSCapabilitySnapshot`, a stable
JSON contract that lists the preferred backend, all current backends, whether a
backend needs an external tool, supported input formats, produced artifacts,
diagnostic coverage, corpus coverage tags, Agent-facing contracts, and open
milestones.

```bash
lvsengine --capabilities --json
```

The snapshot is intentionally separate from `--action-domain`: `--action-domain`
describes executable planning operations, while `--capabilities` describes the
trust surface and remaining capability gaps for standalone LVS.

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
`property`, and `equate pins`. `foreach dev $devices` blocks are expanded into
concrete device-specific policy rules, so the seed can be consumed without
re-running Tcl. Runtime cell-list selectors such as `$cell` stay unresolved in
the static import summary because they depend on the compared netlists, then
native LVS resolves them against observed models that also have `.subckt`
definitions during `--device-policy` application. The companion
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
treated as parity.

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
Full foundry LVS benchmark parity still needs broader device-recognition-time
policy semantics, runtime `$cell` golden agreement, and larger native-gds golden
cases.

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

`LayoutGDSLVSBackend` extracts devices from GDSII/OASIS/CIF/DXF mask data
(label-driven net naming with Magic semantics — works on pin-less post-GDS
layouts) using the same
`LayoutVerify` extraction kernel as the layout editor, then compares against a
reference `.subckt` netlist via `NetlistComparator`. Diagnostics separate
`extraction.*` issues from `compare.unmatchedExtracted` / `compare.unmatchedReference`
/ `compare.parameterMismatch`. Set `LVSRequest.technologyURL` to select it
programmatically.

```bash
# Native on standard inputs (mask data + tech deck + reference netlist)
lvsengine --layout-gds design.gds --tech technology.json --schematic-netlist top.spice

# Explicit backend override; default without --tech is netgen
lvsengine --layout-gds design.gds --backend native-gds --tech technology.json --schematic-netlist top.spice
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

The summary keeps the full report as the source of truth while exposing the
pass/fail status, active/waived mismatch counts, unused waivers, optional
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
`diagnosticSummary.errorCount` or `result.passed`.

The waiver file is saved as an input artifact with a digest. The report and
manifest both include `waiverReport`, including unused waiver IDs so stale policy
entries remain visible.

## Corpus mode

`LVSCorpusRunner` and `lvsengine --corpus <corpus.json> --out <dir> --json` run
multiple LVS cases and compare each result against expected pass/fail, active
error rule IDs, optional oracle backend agreement (`oracleBackendID`), and
optional duration budgets (`defaultMaxDurationSeconds` or per-case
`maxDurationSeconds`). Cases may also declare `coverageTags`, and a corpus
policy may require `requiredCoverageTags` so a release gate can fail when the
corpus passes but does not cover the required capability areas. A case may also
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
`required_coverage_missing`, or `oracle_execution_failed`. The summary also
includes `coverageTagCounts`. `lvsengine --corpus` uses
`qualification.qualified` for its exit status, so Agents and CI can rely on the
same persisted gate they review later.
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
structured mismatch diagnostics, confidence, coverage tags, and decision hints.
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
oracle result and required coverage tags for diode/BJT/inductor/source device
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
that a correctness-clean corpus fails when `requiredCoverageTags` are missing.
Runtime tests additionally inject disagreeing backends to prove oracle mismatch
fails the corpus gate.

## Result convention

`result.success` means the comparison **ran**. Topology and property verdicts are
separate diagnostics; only the fold of all of them counts as a match. A missing
result status is never interpreted as a match.

## Build & test

```bash
swift build
swift test   # Netgen/Magic-gated suites skip themselves when the tools are absent
```
