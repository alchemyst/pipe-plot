# Similar projects

PipePlot is a native macOS companion for a shell pipeline. Run `sampler | pp` to collect numeric observations, then inspect the locally saved history with linked charts, guides, selection statistics and forecasts. If you need a terminal display, a browser chart or a full scientific workspace, there are good tools for those workflows too.

## Live plotting

| Project | How to get data in | What makes it a good fit |
| --- | --- | --- |
| [ttyplot](https://github.com/tenox7/ttyplot) | Pipe numeric stdin directly into a terminal plot | A quick view in a shell or remote terminal, with optional second series and rate display. |
| [wesplot](https://github.com/cactusdynamics/wesplot) | Pipe stdin to a local server that sends samples over WebSocket to the browser | An interactive browser chart launched from a pipeline. |
| [feedgnuplot](https://github.com/dkogan/feedgnuplot) | Pipe stdin into gnuplot through the command-line wrapper. Use `--stream` for live redraws. | Scriptable plots with control over the streaming window and hardcopy output. |
| [LabPlot](https://labplot.org/) | Add a [Live Data Source](https://docs.labplot.org/en/import_export/import_live_data.html) to a project. Choose **File or Named Pipe** for a FIFO, or configure a socket or serial source. | A scientific workspace with reference lines and ranges, fitting, data transformations and publication-oriented plots. |
| [Kst](https://kst-plot.kde.org/) | Open a supported streaming data source such as ASCII or Dirfile | Interactive plots of large scientific datasets, with filtering, fits and spectra. |
| [PlotJuggler](https://github.com/PlotJuggler/PlotJuggler) | Open recorded data or connect through a supported streamer such as ROS, MQTT or UDP. Check the plugins and packages for your version. | Exploring and transforming multiple time series, especially robotics telemetry. |
| [Serial Studio](https://github.com/Serial-Studio/Serial-Studio/blob/master/doc/help/Getting-Started.md) | Choose a device or network connection and configure how frames are decoded | Building live dashboards for devices and sensors. |

LabPlot’s named pipe is a filesystem endpoint created with `mkfifo`. Select the endpoint’s path and data format in LabPlot, then point the producer’s output at that path. PipePlot’s `pp` reads ordinary shell stdin, so the producer can use an anonymous pipeline. The [LabPlot manual](https://docs.labplot.org/en/import_export/import_live_data.html) covers the project setup and options.

## Related workflows

| Project | Where the workflows meet |
| --- | --- |
| [Perfetto](https://perfetto.dev/docs/visualization/perfetto-ui) | Trace exploration with linked tracks, keyboard navigation and time-range selection. It is a reference for PipePlot’s timeline interaction. |
| [Grafana](https://grafana.com/docs/grafana/latest/datasources/) | Dashboards and monitoring over configured data sources. [Grafana Cloud forecasting](https://grafana.com/docs/grafana-cloud/ai-tools/machine-learning/forecasting/) produces forecast metrics from a configured source. |

The table describes documented workflows. Platform and plugin availability can vary by release. Links to corrections or additional projects are welcome through the [PipePlot issue tracker](https://github.com/alchemyst/pipe-plot/issues).
