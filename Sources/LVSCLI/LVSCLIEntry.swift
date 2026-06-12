import Foundation
import LVSCLICore

@main
struct LVSCLIEntry {
    static func main() async {
        let exitCode = await LVSCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        Foundation.exit(exitCode)
    }
}
