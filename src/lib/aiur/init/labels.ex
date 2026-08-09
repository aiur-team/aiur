defmodule Aiur.Init.Labels do
  @moduledoc """
  GitHub label provisioning for the `aiur init` wizard — staged, idempotent,
  token-gated label creation with fallback `gh` commands when the token lacks
  the required scope.
  """

  alias Aiur.CodingAgent
  alias Aiur.GitHub.Labels
  alias Aiur.Init.Format
  alias Aiur.Init.Questions

  @default_label_prefix "agent"
  @config_file_name ".aiur/config"

  @spec setup_labels(Aiur.Init.io(), Aiur.Init.deps(), map(), [String.t()], {String.t(), String.t() | nil}) :: :ok | :error
  def setup_labels(io, deps, %{kind: "github"} = tracker, agents, {primary, fallback}) do
    kinds = Questions.agent_kinds(agents)
    existing = fetch_existing_labels(deps, tracker)
    required = required_labels(Map.get(tracker, :label_prefix, @default_label_prefix), primary, fallback)

    with :ok <- create_required_labels(io, deps, tracker, existing, required),
         existing = Enum.uniq(existing ++ required),
         :ok <- maybe_create_complexity_labels(io, deps, tracker, existing),
         :ok <- maybe_create_model_labels(io, deps, tracker, existing, kinds),
         :ok <- maybe_offer_discovered_model_labels(io, deps, tracker, existing, kinds),
         :ok <- maybe_create_effort_labels(io, deps, tracker, existing) do
      maybe_create_remote_label(io, deps, tracker, existing, kinds)
    end
  end

  def setup_labels(_io, _deps, _tracker, _agents, _pair), do: :ok

  @spec setup_labels(Aiur.Init.io(), Aiur.Init.deps(), map(), [String.t()]) :: :ok | :error
  def setup_labels(io, deps, tracker, agents) do
    setup_labels(io, deps, tracker, agents, {CodingAgent.default_backend(), CodingAgent.default_rate_limit_fallback()})
  end

  # Existing repo labels, fetched once. If we can't read them, treat all as
  # missing — create_labels is idempotent, so already-present labels are skipped.
  defp fetch_existing_labels(deps, tracker) do
    case deps.list_labels.(tracker) do
      {:ok, existing} -> existing
      {:error, _reason} -> []
    end
  end

  # Stage 1 — labels required for workflow state and the default rate-limit fallback.
  defp create_required_labels(io, deps, tracker, existing, labels) do
    case labels -- existing do
      [] ->
        io.puts.(label_status_line("Required agent tags"))
        :ok

      missing ->
        io.puts.("\nAiur uses ticket labels to route agents. Next we'll use your GITHUB_TOKEN to create the following labels in the repo:")
        print_label_list(io, labels)
        Format.print_hint(io, "These workflow and automatic-fallback labels are required.")
        io.input.("Press Enter to create them", "", nil)
        create_labels_request(io, deps, tracker, labels, missing)
    end
  end

  defp required_labels(prefix, primary, fallback) do
    Labels.state_labels(prefix) ++ Labels.required_rate_limit_fallback_labels(prefix, primary, fallback)
  end

  # Stage 2 — optional complexity labels.
  defp maybe_create_complexity_labels(io, deps, tracker, existing) do
    labels = Labels.complexity_labels()

    case labels -- existing do
      [] ->
        io.puts.(label_status_line("Complexity tags"))
        :ok

      missing ->
        io.puts.("\nNext you can create story point complexity labels:")
        print_label_list(io, labels)
        Format.print_hint(io, "Optional: Used to optimize effort. You can add point-specific prompts in #{@config_file_name} to have the agent use different skills and models based on complexity.")
        create_or_skip(io, deps, tracker, labels, missing, "Create the complexity labels?", true)
    end
  end

  # Stage 3 — optional model-override labels for the chosen backends (the remote
  # flag is its own stage). These override complexity-routed model choices.
  defp maybe_create_model_labels(io, deps, tracker, existing, kinds) do
    labels = Labels.model_labels(kinds)

    case labels -- existing do
      [] ->
        io.puts.(label_status_line("Model tags"))
        :ok

      missing ->
        io.puts.("\nNext you can create model labels to route specific issues to different models:")
        print_label_list(io, labels)
        Format.print_hint(io, "Optional: These will override complexity label model choices.")
        create_or_skip(io, deps, tracker, labels, missing, "Create the model labels?", true)
    end
  end

  # Stage 3a — model tags for models the installed CLIs advertise but this build
  # of aiur has no tag for yet. Asking each backend's own CLI is what stops the
  # model list from being hand-maintained: a model released after this aiur was
  # built shows up here with no code change. Always an offer, never a silent
  # creation, and silent in the other direction too — when discovery can't
  # answer (CLI absent, offline, unreadable reply) `init` continues without it.
  defp maybe_offer_discovered_model_labels(io, deps, tracker, existing, kinds) do
    case discovered_model_labels(deps, kinds) -- existing do
      [] ->
        :ok

      missing ->
        io.puts.("\nYour installed agent CLIs report models aiur has no tags for yet:")
        print_label_list(io, missing)
        Format.print_hint(io, "Optional: discovered from the installed CLIs, so these are current even if this aiur build predates them.")
        create_or_skip(io, deps, tracker, missing, missing, "Create the newly discovered model labels?", true)
    end
  end

  # One probe per backend family — `claude` and `claude-repl` share a CLI, so
  # the answer is reused rather than paying a second app-server start. Which
  # of those models is "new" is still decided per backend, against that
  # backend's own registry entry.
  defp discovered_model_labels(deps, kinds) do
    {labels, _cache} =
      Enum.flat_map_reduce(kinds, %{}, fn backend, cache ->
        {discovered, cache} = discover_models(deps, backend, cache)
        unknown = Enum.reject(discovered, &CodingAgent.known_model?(backend, &1))

        {Enum.map(unknown, &"model:#{backend}-#{&1}"), cache}
      end)

    Enum.uniq(labels)
  end

  defp discover_models(deps, backend, cache) do
    family = CodingAgent.family_for(backend) || backend

    case Map.fetch(cache, family) do
      {:ok, cached} ->
        {cached, cache}

      :error ->
        discovered =
          case deps.discover_models.(backend) do
            {:ok, models} -> models
            {:error, _reason} -> []
          end

        {discovered, Map.put(cache, family, discovered)}
    end
  end

  # Stage 3b — optional per-ticket effort override labels (backend-independent).
  # These set an issue's reasoning effort independent of complexity routing.
  defp maybe_create_effort_labels(io, deps, tracker, existing) do
    labels = Labels.effort_labels()

    case labels -- existing do
      [] ->
        io.puts.(label_status_line("Effort tags"))
        :ok

      missing ->
        io.puts.("\nNext you can create effort labels to override reasoning effort per issue:")
        print_label_list(io, labels)
        Format.print_hint(io, "Optional: These set reasoning effort independent of complexity routing.")
        create_or_skip(io, deps, tracker, labels, missing, "Create the effort labels?", true)
    end
  end

  # Stage 4 — optional remote-control flag label, only when claude is supported.
  defp maybe_create_remote_label(io, deps, tracker, existing, kinds) do
    case Labels.alias_labels(kinds) do
      [] ->
        :ok

      labels ->
        case labels -- existing do
          [] ->
            io.puts.(label_status_line("Remote-control tag"))
            :ok

          missing ->
            io.puts.("\nFinally, if you'd like the agent to open a ticket in remote-control mode, add this label:")
            print_label_list(io, labels)
            Format.print_hint(io, "Optional: Supports claude remote-control")
            create_or_skip(io, deps, tracker, labels, missing, "Create the model:remote label?", false)
        end
    end
  end

  defp create_or_skip(io, deps, tracker, labels, missing, prompt, default) do
    if io.confirm.(prompt, default) do
      create_labels_request(io, deps, tracker, labels, missing)
    else
      io.puts.("Skipped.")
      :ok
    end
  end

  # Reported in the saved-selections style when a stage's labels all already
  # exist, so a re-run confirms them instead of prompting to create them again.
  defp label_status_line(name), do: IO.ANSI.format([:faint, "  #{name}: created."])

  defp create_labels_request(io, deps, tracker, labels, missing) do
    case deps.create_labels.(tracker, missing) do
      :ok ->
        io.puts.("Created #{length(missing)} (#{length(labels) - length(missing)} already existed).")
        :ok

      {:error, message} ->
        emit_gh_label_fallback(io, tracker, missing, message)
        :error
    end
  end

  # Pad each label to the widest in the list so the `—` descriptions align.
  defp print_label_list(io, labels) do
    width = Enum.reduce(labels, 0, fn label, acc -> max(acc, String.length(label)) end)

    Enum.each(labels, fn label ->
      io.puts.(["  ", String.pad_trailing(label, width), " — ", Labels.describe(label)])
    end)
  end

  # When the token can't create labels (e.g. missing scope), hand the Executor
  # a copy-paste command to create them, then ask them to re-run to confirm.
  defp emit_gh_label_fallback(io, tracker, labels, message) do
    repo = tracker[:repo] || "<owner/name>"

    io.puts.("\n⚠️ Couldn't create labels automatically (#{message}).")
    io.puts.("Run these to create them yourself (existing ones are skipped):")

    Enum.each(labels, fn label ->
      io.puts.("  gh label create #{shell_arg(label)} --repo #{repo} --description #{shell_arg(Labels.describe(label))} --force")
    end)

    io.puts.("Then run `aiur init` again to confirm all labels exist.")
  end

  defp shell_arg(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
end
