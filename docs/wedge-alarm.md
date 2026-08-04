# Away-mode injection wedge alarm

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
The active alert is pane-independent because a tmux status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.
The durable marker and tmux flash remain as additional signals.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert while retaining the durable marker and tmux flash.
- `auto` or `default` resolves to `osascript` on macOS.
  Other platforms have no built-in OS channel, so configure `command:` when a durable marker alone is insufficient.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` delivers the alarm summary to `<cmd>` on stdin and as an argument, allowing delivery to a phone or pager service.
  A directive that is nothing but one executable, with no arguments and no shell syntax, is run directly with the summary as its only argument.
  Every other directive runs through `sh -c` with the summary as `$1`, because appending an argument to a command that already carries its own can change what that command does.
  Whitespace around `<cmd>` is ignored, so `command: <cmd>` and `command:<cmd>` are the same directive and reach the same branch.
  A directive that is empty or nothing but whitespace runs nothing and logs that there was nothing to run.

## Summary format

The alarm's summary is one line, written as the marker's first line and handed verbatim to every channel:

```
FMWEDGE/1 severity=<LOW|MEDIUM|HIGH|UNKNOWN> count=<n> kinds=<a,b> age=<n>s: <prose>; see <marker>
```

Severity is assessed from the buffered escalations at the moment the alarm fires, where their content is known, and is never re-derived by a channel.
It is the strongest buffered item: a held captain decision, a blocked lane, or a failure is `HIGH`, work ready for review is `MEDIUM`, and parked-lane rechecks and idle flags are `LOW`.
An item the classifier cannot place counts as `MEDIUM` and appears in `kinds` as `unclassified`, so the alert never reports a calm it did not assess.
A buffer that cannot be read reports `severity=UNKNOWN count=0`.

The structured tokens lead so a consumer that keys a standing alert on the message text sees `severity` and `kinds` before any truncation.
`count` and `age` are numeric by design: a consumer that collapses digit runs when identifying a standing event will not treat their churn as a new alert, while a change of severity or kind does surface one.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on on macOS.
This is deliberate because the alarm fires only after a genuine max-defer wedge and is rate-limited to at most once per max-defer window.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the daemon loop.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `herdr`, and the test seam.
On timeout or daemon shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary as an argv item rather than interpolated source, so summary text cannot alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
When the daemon is sourced as a library, that seam defaults to `discard`, so a test cannot accidentally post a real notification.
`tests/wake-helpers.sh` replaces it with a recorder when a suite needs to assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, and safe `command:` summary delivery.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual macOS and Herdr channel proof.
