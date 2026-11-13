# PipePlot philosophy

PipePlot is a real-time viewer for ephemeral numbers. Its job is to get from
`command | pp` to a useful picture with as little setup as possible, then help
you answer the question that made you run the command. Design for a live
investigation with a beginning and an end. Saving local history lets you look
back, compare intervals, and pick up where you left off.

## Design for infrequent, intensive use

Assume someone comes back after months away and wants to get straight to work.
Choose defaults that produce a useful chart immediately. Make actions
discoverable in the UI, where their purpose and effect are clear. Shortcuts and
CLI flags can speed up familiar workflows. The UI should offer a clear path to
the same investigative capabilities without requiring memorised commands,
hidden settings, or an advanced mode.

The first chart is only the start. While capture is running, it should be easy
to add another signal, split it onto its own chart, mark an event, or inspect an
earlier interval. Preserve the running capture and the user's place in the
investigation as they do that. Add controls when they answer a question someone
can plausibly have while watching the data. Favour direct manipulation and
contextual controls over settings people have to configure in advance.

## Let the work outgrow PipePlot

Repeatedly checking the same charts, monitoring from another device, and
keeping long-term queryable history are jobs for a time-series database and
dashboard. Deeper offline analysis belongs in tools suited to that work. Those
workflows reward upfront configuration. PipePlot's defaults and interface should
serve the person trying to understand something happening now.

Make it easy to take the data along. Chart and selection CSV exports provide a
portable handoff. If a live investigation becomes ongoing monitoring, the user
can configure the producer for the new destination and use the captured data as
backfill where useful. Changing destinations may mean restarting or rewiring the
shell pipeline. A deliberate transition is reasonable once the work calls for a
durable setup.

When evaluating a feature, ask what live question it helps answer, how a
returning user would find it, and what it adds to the path from a running
command to a useful chart. If its main benefit comes from repeatedly opening
the same configured view or analysing the data later, treat that as a sign
the work has outgrown PipePlot. Improve the handoff where it helps.
