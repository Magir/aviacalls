import Foundation

let args = CommandLine.arguments
if args.contains("--dump-ax") { CLI.dumpAX(); exit(0) }
print("AviaCalls: запусти с --dump-ax")
