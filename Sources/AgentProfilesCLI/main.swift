import AgentCLI
import Foundation

exit(await CLI.run(Array(CommandLine.arguments.dropFirst()), context: .live()))
