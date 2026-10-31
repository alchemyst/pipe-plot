# Peak selection review

The PNG shows synthetic observations and the extrema returned by the actual Swift `PeakFinder`, not screenshots of the app. The labels are drawn by Matplotlib for review; app placement and appearance differ. The pressure example uses uneven sample times and two explicitly disconnected capture segments.

For each visible segment, the finder ranks observed turning points by topographic prominence (the smaller of the drops to the basin on each side, bounded by a higher point or the segment edge). Peaks and troughs compete for three slots per stream, with a 56-pixel horizontal spacing; equal-height plateaus use their middle observation. There is no minimum prominence threshold, so a noisy otherwise-flat signal can receive noise labels. A chart with more than six streams suppresses these callouts. The app suppresses a label when neither of its two positions fits without colliding with a previously placed extrema label.

Datadog documents [rollup aggregation](https://docs.datadoghq.com/dashboards/guide/query-to-the-graph/) and [anomaly detection](https://docs.datadoghq.com/dashboards/graph_insights/investigate_anomalies/), but neither specifies an algorithm for selecting ordinary numeric extrema labels. This implementation is an independent policy, not a claim of Datadog parity.

Regenerate from the repository root (requires Swift and Matplotlib):

```sh
swiftc Sources/PipePlotCore/PeakFinder.swift docs/peak-review/generate.swift -o /tmp/peak_review
/tmp/peak_review > docs/peak-review/samples.csv
python3 docs/peak-review/plot.py
```
