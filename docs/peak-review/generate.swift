import Foundation
public struct StoredSample { public var timestamp: Date; public var sequence: UInt64; public var value: Double; public var segmentID: String? = nil }
@main struct Review {
 static func main() {
  let start = Date(timeIntervalSince1970: 0)
  for scenario in 0..<5 {
   var data: [StoredSample] = []
   for i in 0...600 {
    let t = Double(i)
    let noise = 0.35 * sin(t * 1.71) + 0.18 * sin(t * 2.37)
    let value: Double
    switch scenario {
    case 0: value = 55 + 12*sin(2 * .pi * t / 600)
    case 1: value = 45 + 7*sin(t/55) + noise + 22*exp(-pow((t-310)/8, 2))
    case 2: value = 20 + 0.045*t + 10*exp(-pow((t-125)/28, 2)) - 13*exp(-pow((t-435)/35, 2)) + noise
    case 3: value = 40 + 8*sin(t/36) + noise
    default: value = 30 + 0.03*t
    }
    if scenario == 3 && i > 265 && i < 340 { continue }
    if scenario == 3 && (i % 7 != 0 && i % 19 != 0) { continue }
    data.append(StoredSample(timestamp:start.addingTimeInterval(t), sequence:UInt64(i), value:value, segmentID: scenario == 3 ? (i <= 265 ? "a" : "b") : nil))
   }
   let found = PeakFinder.extrema(samples:data, visibleRange:start...start.addingTimeInterval(600), plotWidth:800, valueRange:0...100)
   let marks = Dictionary(uniqueKeysWithValues: found.map { ($0.sampleIndex, $0.kind == .peak ? "peak" : "trough") })
   for (i, sample) in data.enumerated() { print("\(scenario),\(sample.timestamp.timeIntervalSince(start)),\(sample.value),\(sample.segmentID ?? "a"),\(marks[i] ?? "")") }
  }
 }
}
