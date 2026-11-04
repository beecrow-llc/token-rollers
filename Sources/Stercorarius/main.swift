import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "codex-hook" {
    exit(CodexHook.execute(arguments: Array(arguments.dropFirst())))
}
