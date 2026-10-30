# Daily newsletter

One designated machine per repository prepares a newsletter at **05:00
America/Los_Angeles**. The user timer runs the package's automatic `preprocess`
and `compile` stages. It does not send mail. The Executor handles the
`system.newsletter.ready` wake with `/aiur-newsletter`, adds its findings,
recompiles, and sends the PDF in chat with a notification.

Python 3.9+, Chromium (or Google Chrome), the `aiur` CLI and this checkout are
required. The timer user's CLI must target the running daemon for the selected
repository and have its normal tracker authentication. Set the user manager's
PATH if `aiur`, Chromium or tracker tools live outside its default PATH.

## Install on one machine

Choose the scheduling machine by enabling **this user timer only on that
machine**. `NEWSLETTER_REPO` selects the repository; `NEWSLETTER_CHECKOUT`
selects its source checkout. There is no cross-machine scheduler election.

The report combines the configured sources; do not install a second timer for
another machine's contribution. Disable the old timer before moving it.

From the checkout root:

```sh
mkdir -p ~/.config/systemd/user ~/.config/aiur
cp scripts/newsletter/systemd/aiur-newsletter.{service,timer} ~/.config/systemd/user/
${EDITOR:-vi} ~/.config/aiur/newsletter.env
```

Put these settings in the local file, replacing the example values:

```ini
NEWSLETTER_CHECKOUT=/absolute/path/to/checkout
NEWSLETTER_REPO=owner/repo
```

Use an absolute checkout path. This file stays local; it needs no email address
or SMTP credentials. Then enable the timer:

```sh
systemctl --user daemon-reload
systemctl --user enable --now aiur-newsletter.timer
systemctl --user list-timers aiur-newsletter.timer
```

`Persistent=true` catches a missed run when the user manager next starts.
For runs while logged out, arrange user lingering with the machine's operator.

The service retries a failed run every five minutes, with at most six starts
in three hours (`StartLimitIntervalSec=3h`, `StartLimitBurst=6`). Failures appear
in both its journal and the dated `run.log`.

Failures also attempt an `executor.newsletter.failed` notification carrying
`repo`, `date`, `stage`, `reason` and `log_path`. Notification is best effort:
if the daemon is down, the notification failure is logged too.

## Change the send time

```sh
systemctl --user edit aiur-newsletter.timer
```

Clear the inherited calendar before setting the new one; otherwise both times run:

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 06:30 America/Los_Angeles
```

```sh
systemctl --user daemon-reload
systemctl --user restart aiur-newsletter.timer
systemctl --user list-timers aiur-newsletter.timer
```

This changes preparation time; delivery follows when the Executor handles the
wake. The default prepares the preceding 24-hour window at 05:00 Pacific,
including daylight saving changes.

## Run once and inspect outputs

```sh
systemctl --user start aiur-newsletter.service
journalctl --user -u aiur-newsletter.service -n 50
# Or run from the checkout directly:
scripts/newsletter/run-daily.sh --repo owner/repo
```

Outputs live in `~/.aiur/repo/<owner>/<repo>/newsletter/<local-date>/`:
`snapshot.json`, `report.json`, `newsletter.html`, `newsletter.pdf`, `run.log` and, after successful
publication, `wake-sent.json`. Snapshots live in `newsletter/snapshots/` and the
latest automatic outputs in `newsletter/latest/`. The package verifies that
the PDF has one page.

The directory and completion marker use the date in `--timezone`, defaulting
to `America/Los_Angeles`. Snapshot filenames and daily baselines remain keyed
by UTC date; report window timestamps remain UTC instants.

Use `--state-dir` to override the per-repo state root,
`--instance <name>` repeatedly for additional configured daemon sources, and
`--aiur /absolute/path/to/aiur` to choose the CLI executable.

Successful runs skip subsequent invocations on the same local date. A per-repo
file lock prevents overlapping local invocations. A crash between wake
publication and writing the completion marker can redeliver the wake; the
Executor should treat the repository and date as its delivery identity.

A stopped Executor does not lose the wake: the daemon journals it and keeps
it pending for `executor-wait`. If the daemon itself is stopped, preparation
still leaves the PDF, publication fails visibly, and systemd retries. The
Executor's newsletter skill is responsible for final notes and chat delivery.

For fixture verification without tracker access, email settings or a daemon:

```sh
scripts/newsletter/run-daily.sh --repo owner/repo --state-dir /path/to/scratch \
  --dry-run --fixture /path/to/snapshot.json
scripts/test-newsletter-run-daily.sh
```

The fixture is a collector snapshot JSON. `--dry-run` suppresses wake
publication and the completion marker. It uses live collection unless a fixture
is supplied; fixtures require an explicit scratch state directory.

## Uninstall

Stop the timer and service before removing their local configuration:

```sh
systemctl --user disable --now aiur-newsletter.timer
systemctl --user stop aiur-newsletter.service
rm -f ~/.config/systemd/user/aiur-newsletter.service \
  ~/.config/systemd/user/aiur-newsletter.timer ~/.config/aiur/newsletter.env
rm -rf ~/.config/systemd/user/aiur-newsletter.service.d \
  ~/.config/systemd/user/aiur-newsletter.timer.d
systemctl --user daemon-reload
```

The `.d` directories hold overrides created with `systemctl --user edit`.
Newsletter outputs under the per-repository state directory stay until you
delete them explicitly.
