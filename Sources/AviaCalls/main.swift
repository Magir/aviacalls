import Foundation

let args = CommandLine.arguments
if args.contains("--dump-ax") { CLI.dumpAX(); exit(0) }
if let i = args.firstIndex(of: "--record-test") { CLI.recordTest(seconds: Double(args.dropFirst(i + 1).first ?? "") ?? 10); exit(0) }
if let i = args.firstIndex(of: "--transcribe"), let dir = args.dropFirst(i + 1).first { CLI.transcribe(dir: dir); exit(0) }
if let i = args.firstIndex(of: "--screen-test") { CLI.screenTest(seconds: Double(args.dropFirst(i + 1).first ?? "") ?? 12); exit(0) }
if args.contains("--notify-test") { CLI.notifyTest(); exit(0) }
AviaCallsApp.main()
