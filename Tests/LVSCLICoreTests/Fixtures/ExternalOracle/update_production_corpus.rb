require "json"

path = File.join(__dir__, "lvs-production-corpus.json")
spec = JSON.parse(File.read(path))

cells = %w[
  sky130_fd_sc_hd__inv_1
  sky130_fd_sc_hd__nand2_1
  sky130_fd_sc_hd__nor2_1
  sky130_fd_sc_hd__and2_1
  sky130_fd_sc_hd__or2_1
  sky130_fd_sc_hd__xor2_1
  sky130_fd_sc_hd__xnor2_1
  sky130_fd_sc_hd__mux2_1
  sky130_fd_sc_hd__a21o_1
  sky130_fd_sc_hd__a21oi_1
  sky130_fd_sc_hd__o21a_1
  sky130_fd_sc_hd__o21ai_1
  sky130_fd_sc_hd__a22o_1
  sky130_fd_sc_hd__a22oi_1
  sky130_fd_sc_hd__o22a_1
  sky130_fd_sc_hd__o22ai_1
  sky130_fd_sc_hd__nand3_1
  sky130_fd_sc_hd__nor3_1
  sky130_fd_sc_hd__buf_1
  sky130_fd_sc_hd__clkbuf_1
]

commonAssertions = [
  ["verdict", "verdict", "match"],
  ["duration-budget", "durationBudget", "within-budget"],
  ["report-artifact", "reportArtifact", nil],
  ["manifest-artifact", "manifestArtifact", nil],
  ["correspondence-artifact", "correspondenceArtifact", nil],
  ["oracle-agreement", "oracleAgreement", "true"],
  ["oracle-independence", "oracleIndependence", "ready"],
  ["extraction-artifact", "extractionArtifact", nil],
  ["extraction-profile-readiness", "extractionProfileReadiness", "ready"],
  ["device-policy-import", "devicePolicyImport", "satisfied"],
  ["device-policy-application", "devicePolicyApplication", "complete"],
  ["device-policy-permute", "devicePolicyRule", "permute"],
  ["device-policy-property", "devicePolicyRule", "property"],
  ["device-policy-equate", "devicePolicyRule", "equate"],
  ["device-policy-equate-pins", "devicePolicyRule", "equate-pins"],
  ["device-policy-ignore-class", "devicePolicyRule", "ignore-class"],
  ["device-policy-blackbox", "devicePolicyRule", "blackbox"],
].map do |assertionID, kind, expectedValue|
  assertion = { "assertionID" => assertionID, "kind" => kind }
  assertion["expectedValue"] = expectedValue unless expectedValue.nil?
  assertion
end

spec["cases"].reject! do |item|
  item["caseID"] == "production-sky130-gds-inverter" ||
    item["caseID"].start_with?("production-sky130-digital-")
end

cells.each do |cell|
  shortName = cell.delete_prefix("sky130_fd_sc_hd__")
  spec["cases"] << {
    "caseID" => "production-sky130-digital-#{shortName}",
    "backendID" => "native-gds",
    "oracleBackendID" => "netgen",
    "layoutGDSPath" => "#{cell}.gds",
    "layoutFormat" => "gds",
    "schematicNetlistPath" => "pdk://libs.ref/sky130_fd_sc_hd/spice/sky130_fd_sc_hd.spice",
    "technologyPath" => "sky130-layout-tech.json",
    "extractionProfilePath" => "pdk://libs.tech/lvs/sky130A-layout-extraction-profile.json",
    "extractionDeckPath" => "pdk://libs.tech/magic/sky130A.tech",
    "devicePolicyDeckPath" => "pdk://libs.tech/netgen/sky130A_setup.tcl",
    "processProfileID" => "sky130.open-pdk.digital-mos.signoff",
    "topCell" => cell,
    "expectedPassed" => true,
    "expectedVerdict" => "match",
    "oracleComparisonMode" => "verdict",
    "hardExecutionBudget" => {
      "maximumDurationSeconds" => 30,
      "maximumSearchStates" => 100_000,
      "maximumSearchDepth" => 100_000,
      "maximumWorkingSetBytes" => 536_870_912,
      "determinismRunCount" => 1,
    },
    "requiredAssertions" => commonAssertions,
  }
end

baseAssertions = [
  ["verdict", "verdict", "match"],
  ["duration-budget", "durationBudget", "within-budget"],
  ["report-artifact", "reportArtifact", nil],
  ["manifest-artifact", "manifestArtifact", nil],
  ["correspondence-artifact", "correspondenceArtifact", nil],
  ["oracle-agreement", "oracleAgreement", "true"],
  ["oracle-independence", "oracleIndependence", "ready"],
].map do |assertionID, kind, expectedValue|
  assertion = { "assertionID" => assertionID, "kind" => kind }
  assertion["expectedValue"] = expectedValue unless expectedValue.nil?
  assertion
end

hierarchyCases = %w[
  hierarchy_chain
  hierarchy_repeated
  hierarchy_three_level
  hierarchy_parameterized
]
spec["cases"].reject! { |item| item["caseID"].start_with?("production-hierarchy-matrix-") }
hierarchyCases.each do |topCell|
  spec["cases"] << {
    "caseID" => "production-hierarchy-matrix-#{topCell}",
    "backendID" => "native",
    "oracleBackendID" => "netgen",
    "layoutNetlistPath" => "hierarchy-matrix-layout.spice",
    "schematicNetlistPath" => "hierarchy-matrix-schematic.spice",
    "topCell" => topCell,
    "expectedPassed" => true,
    "expectedVerdict" => "match",
    "oracleComparisonMode" => "verdict",
    "hardExecutionBudget" => {
      "maximumDurationSeconds" => 30,
      "maximumSearchStates" => 100_000,
      "maximumSearchDepth" => 100_000,
      "maximumWorkingSetBytes" => 536_870_912,
      "determinismRunCount" => 1,
    },
    "requiredAssertions" => baseAssertions + [{
      "assertionID" => "hierarchy-depth",
      "kind" => "hierarchyDepth",
      "expectedValue" => "1",
    }],
  }
end

existingHierarchy = spec["cases"].find do |item|
  item["caseID"] == "production-hierarchical-model-mismatch"
end
if existingHierarchy
  existingHierarchy["requiredAssertions"].reject! do |assertion|
    assertion["assertionID"] == "hierarchy-depth"
  end
  existingHierarchy["requiredAssertions"] << {
    "assertionID" => "hierarchy-depth",
    "kind" => "hierarchyDepth",
    "expectedValue" => "1",
  }
end

analogCases = %w[
  analog_resistor_divider
  analog_rc_filter
  analog_rlc_network
  analog_diode_clamp
  analog_bjt_pair
  analog_nmos_bias
  analog_pmos_bias
  analog_differential_pair
  analog_controlled_voltage
  analog_controlled_current
]
spec["cases"].reject! { |item| item["caseID"].start_with?("production-analog-matrix-") }
analogCases.each do |topCell|
  spec["cases"] << {
    "caseID" => "production-analog-matrix-#{topCell}",
    "backendID" => "native",
    "oracleBackendID" => "netgen",
    "layoutNetlistPath" => "analog-matrix-layout.spice",
    "schematicNetlistPath" => "analog-matrix-schematic.spice",
    "topCell" => topCell,
    "expectedPassed" => true,
    "expectedVerdict" => "match",
    "oracleComparisonMode" => "verdict",
    "hardExecutionBudget" => {
      "maximumDurationSeconds" => 30,
      "maximumSearchStates" => 100_000,
      "maximumSearchDepth" => 100_000,
      "maximumWorkingSetBytes" => 536_870_912,
      "determinismRunCount" => 1,
    },
    "requiredAssertions" => baseAssertions + [{
      "assertionID" => "structure-class",
      "kind" => "structureClass",
      "expectedValue" => "analog",
    }],
  }
end

requiredAssertions = spec["acceptanceCriteria"]["requiredObservedAssertions"]
requiredAssertions |= [
  "hierarchyDepth:1",
  "structureClass:analog",
  "devicePolicyImport:satisfied",
  "devicePolicyApplication:complete",
  "devicePolicyRule:permute",
  "devicePolicyRule:property",
  "devicePolicyRule:equate",
  "devicePolicyRule:equate-pins",
  "devicePolicyRule:ignore-class",
  "devicePolicyRule:blackbox",
]
spec["acceptanceCriteria"]["requiredObservedAssertions"] = requiredAssertions.sort

spec["acceptanceCriteria"]["minimumOracleCaseCount"] = spec["cases"].length
File.write(path, JSON.pretty_generate(spec) + "\n")
