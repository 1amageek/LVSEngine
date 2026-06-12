# LVSEngine

Layout-versus-schematic engine with a protocol-composed backend model. The pure
Swift backends are the core signoff path; Netgen is an optional, headless-batch-only
adapter kept for oracle checks and PDK-deck compatibility.

## Modules

| Module | Responsibility |
|---|---|
| `LVSCore` | `LVSRequest` / `LVSResult` / mismatch models, `LVSBackend` protocol, typed errors |
| `LVSPureSwift` | `PureSwiftLVSBackend` (`pure-swift`) and `LayoutGDSLVSBackend` (`pure-swift-gds`) |
| `LVSParsers` | Netgen report parsing into typed mismatches |
| `LVSAdapters` | Netgen batch invocation (`lvs.tcl`), tool-gated |
| `LVSExtractionAdapters` | LVS input preparation only: Magic layout-to-netlist extraction (`extract_lvs.tcl`) |
| `LVSPersistence` | LVS artifact persistence |
| `LVSRuntime` | Backend registry and engine composition |
| `LVSEngine` | Umbrella module |
| `LVSCLICore` / `lvsengine` | Testable CLI core + executable |

## Standard-input backend: `pure-swift-gds`

`LayoutGDSLVSBackend` extracts devices from a GDSII file (label-driven net naming
with Magic semantics — works on pin-less post-GDS layouts) using the same
`LayoutVerify` extraction kernel as the layout editor, then compares against a
reference `.subckt` netlist via `NetlistComparator`. Diagnostics separate
`extraction.*` issues from `compare.unmatchedExtracted` / `compare.unmatchedReference`
/ `compare.parameterMismatch`. Set `LVSRequest.technologyURL` to select it
programmatically.

```bash
# Pure Swift on standard inputs (GDS + tech deck + reference netlist)
lvsengine --layout-gds design.gds --tech technology.json --schematic-netlist top.spice

# Explicit backend override; default without --tech is netgen
lvsengine --layout-gds design.gds --backend pure-swift-gds --tech technology.json --schematic-netlist top.spice
```

## Result convention

`result.success` means the comparison **ran**. Topology and property verdicts are
separate diagnostics; only the fold of all of them counts as a match. A missing
result status is never interpreted as a match.

## Build & test

```bash
swift build
swift test   # Netgen/Magic-gated suites skip themselves when the tools are absent
```
