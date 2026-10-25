defmodule Aiur.CLI.ReferenceOptions do
  @moduledoc false
  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails

  @switches [
    {@acknowledgement_switch, :boolean},
    logs_root: :string,
    port: :integer,
    host: :string,
    version: :boolean,
    interactive: :boolean,
    headless: :boolean,
    executor: :boolean,
    no_dashboard: :boolean,
    max_agents: :integer,
    pause: :boolean,
    force: :boolean,
    todo: :boolean,
    only: :boolean,
    unfiled: :boolean,
    slugs: :boolean,
    scope: :string,
    record: :string,
    repo: :string,
    digest: :boolean,
    body: :string,
    body_file: :string,
    urgency: :string,
    blocking: :boolean,
    done: :string,
    note: :string,
    json: :boolean,
    open: :boolean,
    all: :boolean,
    dir: :string,
    harness: :string,
    purge: :boolean
  ]

  @switch_docs [
    {:pause, "aiur --pause", "Cold-starts with the global provisioning switch paused.", "aiur --pause"},
    {:max_agents, "aiur --max-agents 6", "Launch-only session cap. It wins over `agent.max_concurrent_agents`; Aiur warns when it exceeds that setting. `status` identifies the active binding.",
     "aiur --max-agents 6"},
    {:interactive, "aiur --interactive", "Requests the terminal UI, including from a background launch.", "aiur --bg --interactive"},
    {:headless, "aiur --headless", "Requests no terminal UI. Background launch injects it unless `--interactive` is present.", "aiur run --headless"},
    {:executor, "aiur --executor",
     "Marks the run as Executor-owned and registers its renewing principal in `executor-roster`. " <>
       "Recording is **not** gated on this flag: every run arms the supervised `executor.#` listener " <>
       "and the wake inbox, so PR-lifecycle, CI and attention records exist for a later agent to replay. " <>
       "What the flag adds is authority — created and deferred Commands are raised as " <>
       "needs-attention alerts only on an Executor-owned run. On startup it also records an " <>
       "informational, retrospective daemon heartbeat gap when the durable lifecycle journal " <>
       "confirms a clean stop or an unclosed prior start. This is not live monitoring: no alert is " <>
       "emitted while Aiur is stopped; the notice appears on the next Executor startup. " <>
       "`LISTENER absent` is therefore always a fault.", "aiur --bg --executor"},
    {:no_dashboard, "aiur --no-dashboard", "Suppresses the dashboard listener in foreground or background mode. It is rejected for Remote Control because its lifecycle hooks need the listener.",
     "aiur --bg --no-dashboard"},
    {:host, "aiur --host 127.0.0.1", "Overrides the dashboard bind host. A non-loopback host requires dashboard credentials.", "aiur --host 127.0.0.1"},
    {:port, "aiur --port 4000", "Overrides the HTTP port. `0` lets the OS choose a free port.", "aiur --port 4000"},
    {:logs_root, "aiur --logs-root /var/log/aiur", "Overrides the daemon log root for this launch.", "aiur --logs-root /var/log/aiur"},
    {:harness, "aiur --harness NAME", "Legacy parser option; does not change the configured agent harness. Use the workflow agent configuration.", "aiur --harness codex"},
    {:todo, "aiur --todo 142 143", "Requires a running daemon and one or more numeric IDs, with commas also accepted. A stopped daemon exits nonzero.", "aiur --todo 142,143"},
    {:only, "aiur --todo 142 --only",
     "Queues the named IDs and asks GitHub to remove `agent:todo` from other pending tickets. " <>
       "It is GitHub-only, is bounded to 50 cleanup targets, and stops after three consecutive " <>
       "rate-limit failures. Removing `agent:todo` from a promoted queue member creates an external " <>
       "hold, cleared with `aiur queue release`. Cleanup is skipped if a requested ID fails, so the " <>
       "operation does not silently dequeue work after a bad request.", "aiur --todo 142 --only"},
    {@acknowledgement_switch, "aiur --i-understand-that-this-will-be-running-without-the-usual-guardrails", "Required by the release parser; the launcher inserts it for normal run commands.",
     "aiur run --i-understand-that-this-will-be-running-without-the-usual-guardrails"},
    {:version, "aiur --version",
     "Prints both the release version and shell dispatcher version without contacting or claiming " <>
       "a running daemon. If they differ, update `aiur-cli` before trusting that newer subcommands " <>
       "are available.", "aiur --version"},
    {:force, "aiur init --force",
     "Recreates generated configuration for the location you choose at the first prompt; picking " <>
       "repo-local leaves an existing `~/.aiur/config` untouched. `--force` explicitly re-runs setup " <>
       "choices, including recorded declines. Re-running without it preserves existing scaffold files " <>
       "and recorded declines.", "aiur init --force"},
    {:unfiled, "aiur --unfiled", "Includes tickets without an issue identifier in supported listing commands.", "aiur --unfiled"},
    {:slugs, "aiur --slugs", "Renders ticket identifiers as tracker slugs where supported.", "aiur --slugs"},
    {:scope, "aiur --scope feature", "Filters a supported ticket listing by scope.", "aiur --scope orchestration"},
    {:record, "aiur --record PATH", "Writes a recording to the selected path.", "aiur --record run.jsonl"},
    {:repo, "aiur --repo OWNER/REPO", "Selects the repository for a supported tracker command.", "aiur --repo aiur-team/aiur"},
    {:digest, "aiur --digest", "Prints the compact digest for the current run.", "aiur --digest"},
    {:body, "aiur --body TEXT", "Uses the supplied text as a command body.", "aiur --body 'Investigate this issue'"},
    {:body_file, "aiur --body-file PATH", "Reads a command body from a file.", "aiur --body-file request.md"},
    {:urgency, "aiur --urgency LEVEL", "Sets urgency for a supported command.", "aiur --urgency high"},
    {:blocking, "aiur --blocking", "Marks a supported command as blocking.", "aiur --blocking"},
    {:done, "aiur --done TEXT", "Adds completion text to a supported command.", "aiur --done 'Merged'"},
    {:note, "aiur --note TEXT", "Attaches a note to a supported command.", "aiur --note 'Follow up tomorrow'"},
    {:json, "aiur --json", "Prints supported command output as JSON.", "aiur --json"},
    {:open, "aiur --open", "Opens the selected result in the configured browser.", "aiur --open"},
    {:all, "aiur --all", "Includes all matching results instead of the default subset.", "aiur --all"},
    {:dir, "aiur --dir PATH", "Selects a working directory for a supported command.", "aiur --dir ./project"},
    {:purge, "aiur --purge", "Removes persisted credentials for a supported account command.", "aiur accounts logout codex default --purge"}
  ]

  @type option :: %{name: atom(), type: atom(), syntax: String.t(), description: String.t(), example: String.t()}
  @spec acknowledgement_switch() :: atom()
  def acknowledgement_switch, do: @acknowledgement_switch

  @spec strict_switches() :: keyword()
  def strict_switches, do: @switches

  @spec options() :: [option()]
  def options do
    documented = @switch_docs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    accepted = Keyword.keys(@switches) |> Enum.sort()

    if documented != accepted do
      raise("CLI reference metadata does not cover strict switches: #{inspect(accepted -- documented)}")
    end

    @switch_docs
    |> Enum.uniq_by(fn {_name, syntax, _description, _example} -> syntax end)
    |> Enum.sort_by(fn {_name, syntax, _description, _example} -> String.downcase(syntax) end)
    |> Enum.map(fn {name, syntax, description, example} ->
      %{name: name, type: Keyword.fetch!(@switches, name), syntax: syntax, description: description, example: example}
    end)
  end
end
