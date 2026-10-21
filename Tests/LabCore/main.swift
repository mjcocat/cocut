import Foundation

// Runs Cocut Lab's scoring and tuning on a lab folder (plain Swift: macOS or Linux):
//   test-lab-core <lab folder> [tries]
let args = CommandLine.arguments
let store = LabStore(folder: URL(fileURLWithPath: args[1]))
let cases = LabTuner.cases(store)
print("\(store.clips.count) clips, \(cases.count) ready")
for c in cases {
    let s = LabTuner.score(c, settings: PlayerChain.Settings())
    print("  \(s.title): in frame \(s.framed) of \(s.checked), right \(s.right), wrong \(s.wrong)")
}
let tries = args.count > 2 ? Int(args[2]) ?? 200 : 200
let started = Date()
let report = LabTuner.tune(cases, baseline: PlayerChain.Settings(), tries: tries, seed: 1) { print($0) }
print(String(format: "tuned in %.0fs", Date().timeIntervalSince(started)))
print(LabTuner.markdown(report))
