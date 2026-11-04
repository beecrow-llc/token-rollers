import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "codex-hook" {
    exit(CodexHook.execute(arguments: Array(arguments.dropFirst())))
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
