defmodule Aiur.ControlCall.Allowlist do
  @moduledoc false
  alias Aiur.ControlCall.Allowlist.Facade

  @agent [:Aiur, :AgentControlCLI]
  @handoff [:Aiur, :Handoff, :CLI]
  @session [:Aiur, :HarnessSessionCLI]
  @usage [:Aiur, :Usage, :CLI]
  @ticket_usage [:Aiur, :TicketUsageCLI]
  @sweep [:Aiur, :ExecutorSweep, :CLI]
  @pr_merge [:Aiur, :PrMerge, :Record]
  @feature_options %{
    op: {:enum, [:create, :add, :remove, :also, :baseline, :edit, :show]},
    slug: :non_empty_string,
    who: {:regex, ~r/^[A-Za-z0-9._-]{1,64}$/},
    ids: :feature_ids,
    move: :boolean,
    remove: :boolean,
    replace: :boolean,
    label: :non_empty_string,
    hue: {:range, 0, 359},
    end: :non_empty_string,
    epic: :string,
    source: {:enum, ["backfill-agent"]},
    epics: :epic_list,
    add_epics: :epic_list,
    epic_hues: :epic_hue_map,
    json: :boolean
  }
  @lane_options %{
    action: {:enum, [:set, :clear, :confirm, :show, :list]},
    epic: {:regex, ~r/^[a-z0-9][a-z0-9_-]{0,63}$/},
    ids: :feature_ids,
    who: {:regex, ~r/^[A-Za-z0-9._-]{1,64}$/},
    source: {:enum, [:cli, :"backfill-agent"]},
    json: :boolean
  }
  @epic_options %{
    action: {:enum, [:set, :clear, :confirm, :show, :list]},
    epic: {:regex, ~r/^[a-z0-9][a-z0-9_-]{0,63}$/},
    ids: :feature_ids,
    who: {:regex, ~r/^[A-Za-z0-9._-]{1,64}$/},
    source: {:enum, [:cli, :"backfill-agent"]},
    json: :boolean
  }

  # Keep this boundary in one place so each function's scope and argument contract are reviewed together.
  # Each signature has {scope, positional constraints, keyword constraints}.
  @agent_rows [
    {:status, 0, :read, [], %{status_timeout_ms: :positive, section_timeout_ms: :positive}},
    {:status, 1, :read, [:keyword], %{status_timeout_ms: :positive, section_timeout_ms: :positive, json: :boolean}},
    {:agents, 0, :read, [], %{}},
    {:agents, 1, :read, [:keyword], %{all: :boolean}},
    {:watch, 0, &__MODULE__.watch_category/1, [], %{mode: {:enum, [:full, :changes]}, json: :boolean}},
    {:watch, 1, &__MODULE__.watch_category/1, [:keyword], %{mode: {:enum, [:full, :changes]}, json: :boolean}},
    {:alerts, 1, &__MODULE__.alerts_category/1, [:keyword], %{argv: :literal_list, json: :boolean}},
    {:alerts, 0, :read, [], %{}},
    {:executor_sweep, 1, &__MODULE__.sweep_category/1, [:keyword], %{apply: :boolean, json: :boolean}},
    {:commands, 0, :read, [], %{}},
    {:commands, 1, :read, [:keyword],
     %{
       filter: {:enum, [:all, :open, :blocking, :resolved, :"needs-you", :"with-executor", :"from-executor"]},
       blocking: :boolean,
       json: :boolean,
       limit: :positive,
       decision_id: :string,
       ticket: :string,
       search: :string,
       cursor: :string
     }},
    {:commands_repair, 0, :config, [], %{}},
    {:commands_repair, 1, :config, [:keyword], %{json: :boolean}},
    {:units, 0, :read, [], %{}},
    {:units, 1, :read, [:keyword], %{scope: {:enum, ["live", "unfinished", "all", "none"]}, conditions: :string_list, format: {:enum, ["auto", "table", "records"]}, json: :boolean}},
    {:feature, 1, &__MODULE__.feature_category/1, [:keyword], @feature_options},
    {:feature, 0, &__MODULE__.feature_category/1, [], %{}},
    {:lane, 1, &__MODULE__.lane_category/1, [:keyword], @lane_options},
    {:lane, 0, &__MODULE__.lane_category/1, [], %{}},
    {:epic, 1, &__MODULE__.epic_category/1, [:keyword], @epic_options},
    {:epic, 0, &__MODULE__.epic_category/1, [], %{}},
    {:build_orders, 0, :read, [], %{}},
    {:build_orders, 1, :read, [:keyword], %{root: :non_empty_string, json: :boolean, contract: {:enum, ["build-order.v1"]}}},
    {:queue, 0, &__MODULE__.queue_category/1, [], %{}},
    {:queue, 1, &__MODULE__.queue_category/1, [:keyword],
     %{
       verb: {:enum, [:show, :order, :add, :set, :remove, :reorder, :hold, :release, :recover, :clear]},
       caller_agent_workspace: :string,
       force: :boolean,
       remove_markers: :boolean,
       yes: :boolean,
       json: :boolean,
       queue: :non_empty_string,
       start_on: {:enum, ["issue_closed", "pr_merged", "pr_approved", "pr_ci_green", "pr_opened", "default"]},
       build_order: :positive,
       after: {:regex, ~r/^[1-9][0-9]*$/},
       at: :non_negative,
       rank: :non_negative,
       to: :non_negative,
       ids: :ticket_id_strings
     }},
    {:analytics, 0, :read, [], %{}},
    {:analytics, 1, :read, [:keyword], %{range: {:enum, [:run, :full]}, since: :string, until: :string, build_order: {:regex, ~r/^\d+$/}, json: :boolean}},
    {:history_label_writes, 1, &__MODULE__.history_label_category/1, [:keyword],
     %{action: {:enum, [:plan, :start, :pause, :resume, :status]}, expect: :non_negative, per_hour: :non_negative, epic_labels: :boolean, json: :boolean}},
    {:github_cost, 0, :read, [], %{}},
    {:github_cost, 1, :read, [:keyword], %{budget: {:enum, ["graphql", "core", "all"]}, format: {:enum, [:auto, :table, :records]}, json: :boolean}},
    {:experiments, 0, &__MODULE__.experiment_category/1, [],
     %{argv: :string_list, verb: {:enum, [:list, :show, :create, :metrics, :freeze, :abandon, :events, :preregister, :report_submit, :stats, :analyze]}, json: :boolean}},
    {:experiments, 1, &__MODULE__.experiment_category/1, [:keyword],
     %{argv: :string_list, verb: {:enum, [:list, :show, :create, :metrics, :freeze, :abandon, :events, :preregister, :report_submit, :stats, :analyze]}, json: :boolean}},
    {:capabilities, 1, :read, [:keyword], %{json: :boolean}},
    {:capabilities, 0, :read, [], %{}},
    {:github_usage, 0, :read, [], %{}},
    {:github_usage, 1, :read, [:keyword], %{json: :boolean}},
    {:ticket_estimate, 0, &__MODULE__.estimate_category/1, [], %{}},
    {:ticket_estimate, 1, &__MODULE__.estimate_category/1, [:keyword], %{id: :positive, hours: :quarter_hour, clear: :boolean, reason: :estimate_reason, by: :estimate_actor, json: :boolean}},
    {:operator_relay_answer, 1, :executor, [:keyword],
     %{
       decision_id: :non_empty_string,
       option_id: :non_empty_string,
       custom_response: :non_empty_string,
       expected_version: :positive,
       quote: :non_empty_string,
       relayed_by: :non_empty_string,
       idempotency_key: :non_empty_string,
       auto_current: :boolean,
       supersede: :boolean
     }},
    {:command_request, 1, :message, [:keyword],
     %{
       question: :non_empty_string,
       options: :string_list,
       media: :string_list,
       recommend: :non_empty_string,
       blocking: :boolean,
       urgency: {:enum, ["low", "normal", "high", "critical"]},
       ticket: :non_empty_string,
       long_context_markdown: :string,
       short_summary: :string,
       executor_id: :non_empty_string,
       idempotency_key: :non_empty_string,
       json: :boolean
     }},
    {:executor_ack, 1, :executor, [:keyword], %{decision_id: :non_empty_string, executor_id: :non_empty_string}},
    {:executor_claim_decision, 1, :executor, [:keyword], %{decision_id: :non_empty_string, executor_id: :non_empty_string, ttl_s: :integer}},
    {:executor_release_decision, 1, :executor, [:keyword], %{decision_id: :non_empty_string, executor_id: :non_empty_string}},
    {:executor_answer, 1, :executor, [:keyword],
     %{
       decision_id: :non_empty_string,
       option_id: :non_empty_string,
       custom_response: :non_empty_string,
       expected_version: :positive,
       rationale: :non_empty_string,
       idempotency_key: :non_empty_string,
       executor_id: :non_empty_string,
       supersede: :boolean
     }},
    {:operator_answer, 1, :deny, [:keyword],
     %{decision_id: :non_empty_string, operator: :boolean, option_id: :non_empty_string, custom_response: :non_empty_string, expected_version: :positive, confirmation: :non_empty_string}},
    {:operator_answer_preview, 1, :deny, [:keyword],
     %{decision_id: :non_empty_string, operator: :boolean, option_id: :non_empty_string, custom_response: :non_empty_string, expected_version: :positive, confirmation: :non_empty_string}},
    {:executor_escalate, 1, :executor, [:keyword], %{decision_id: :non_empty_string, expected_version: :positive, reason: :non_empty_string, executor_id: :non_empty_string}},
    {:executor_reclassify, 1, :executor, [:keyword], %{decision_id: :non_empty_string, expected_version: :positive, rationale: :non_empty_string, executor_id: :string}},
    {:executor_moot, 1, :executor, [:keyword], %{decision_id: :non_empty_string, expected_version: :positive, reason_class: :non_empty_string, reason: :string, executor_id: :non_empty_string}},
    {:executor_wait, 1, &__MODULE__.wait_category/1, [:keyword],
     %{
       timeout_ms: :positive,
       json: :boolean,
       defer_ack: :boolean,
       ack_through: :non_negative,
       as: {:regex, ~r/^[A-Za-z0-9._-]+$/},
       session_id: {:regex, ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/},
       harness: {:enum, ["claude", "codex"]},
       env: :executor_env
     }},
    {:executor_wait, 0, :executor, [], %{}},
    {:executor_check, 1, :deny, [:keyword], %{json: :boolean, repo_root: :non_empty_string}},
    {:executor_attach, 1, :deny, [:keyword], %{harness: {:enum, ["claude", "codex"]}, takeover?: :boolean, print_config: :boolean, repo_root: :non_empty_string}},
    {:executor_detach, 1, :deny, [:keyword], %{repo_root: :non_empty_string}},
    {:executor_session, 1, :read, [:keyword], %{json: :boolean}},
    {:executor_roster, 0, :read, [], %{}},
    {:executor_roster, 1, :read, [:keyword], %{json: :boolean}},
    {:executor_fast_forward, 1, :executor, [:positive], %{}},
    {:executor_fast_forward, 2, :executor, [:positive, :keyword], %{as: {:regex, ~r/^[A-Za-z0-9._-]+$/}}},
    {:executor_claim, 1, :executor, [:keyword], %{as: {:regex, ~r/^(?:[A-Za-z0-9._-]+)?$/}}},
    {:executor_claim, 0, :executor, [], %{}},
    {:executor_release, 1, :executor, [:keyword], %{as: {:regex, ~r/^(?:[A-Za-z0-9._-]+)?$/}}},
    {:executor_release, 0, :executor, [], %{}},
    {:executor_revoke, 1, :executor, [{:regex, ~r/^[A-Za-z0-9._-]+$/}], %{}},
    {:executor_revoke, 2, :executor, [{:regex, ~r/^[A-Za-z0-9._-]+$/}, :keyword], %{now: :integer}},
    {:executor_emit, 2, :executor, [:string, :string], %{}},
    {:executor_subscribe, 1, :executor, [:string], %{}},
    {:executor_unsubscribe, 1, :executor, [:string], %{}},
    {:executor_subscriptions, 0, :read, [], %{}},
    {:executor_listen_validate, 1, :read, [:string], %{}},
    {:todo, 1, :tickets, [:string_list], %{only: :boolean, budget_ms: :positive, emit_exit_marker: :boolean}},
    {:todo, 2, :tickets, [:string_list, :keyword], %{only: :boolean, budget_ms: :positive, emit_exit_marker: :boolean}},
    {:redispatch, 2, :agents, [:string_list, {:nullable, :string}], %{}},
    {:reset_budget, 1, :config, [:string_list], %{}},
    {:pause_global, 0, :agents, [], %{}},
    {:pause_fleet, 0, :agents, [], %{}},
    {:pause_fleet, 1, :agents, [:keyword], %{as: {:regex, ~r/^[A-Za-z0-9._-]{1,64}$/}}},
    {:resume_fleet, 0, :agents, [], %{}},
    {:resume_fleet, 1, :agents, [:keyword], %{as: {:regex, ~r/^[A-Za-z0-9._-]{1,64}$/}}},
    {:apply_fleet_pause_change, 1, :agents, [:string], %{}},
    {:resume_global, 0, :agents, [], %{}},
    {:set_max_agents, 1, :config, [:positive], %{}},
    {:set_setting, 2, :config, [:string, :string], %{}},
    {:set_setting, 3, :config, [:string, :string, :keyword], %{caller_cwd: :string, caller_agent_workspace_env: :string}},
    {:list_settings, 0, :read, [], %{}},
    {:list_settings, 1, :read, [:keyword], %{json: :boolean}},
    {:unset_setting, 1, :config, [:string], %{}},
    {:unset_setting, 2, :config, [:string, :keyword], %{caller_cwd: :string, caller_agent_workspace_env: :string}},
    {:message, 2, :message, [{:regex, ~r/^\d+$/}, :string], %{}},
    {:message, 3, :message, [{:regex, ~r/^\d+$/}, :string, {:regex, ~r/^[A-Za-z0-9._:-]{1,128}$/}], %{}},
    {:message_status, 1, :read, [:positive], %{}},
    {:pause, 1, :agents, [{:one_of, [:string_list, {:enum, [:all]}]}], %{}},
    {:resume, 1, :agents, [{:one_of, [:string_list, {:enum, [:all]}]}], %{}},
    {:park, 1, :agents, [:string_list], %{}},
    {:take, 2, :tickets, [:string_list, :string], %{}},
    {:release, 2, :tickets, [:string_list, :string], %{}},
    {:recover_workspace, 2, :agents, [:string, :positive], %{}},
    {:usage, 0, :deny, [], %{}},
    {:usage, 1, :deny, [:atom], %{}},
    {:usage, 2, :deny, [:atom, :keyword], %{}},
    {:accounts, 1, :deny, [:boolean], %{}},
    {:accounts, 2, :deny, [:boolean, {:nullable, :string}], %{}},
    {:usage_bar, 1, :deny, [:integer], %{}},
    {:prepare_handoff, 0, :deny, [], %{}},
    {:prepare_handoff, 1, :deny, [:keyword], %{}},
    {:main_watch_state, 0, :deny, [], %{}},
    {:status_projects_json, 0, :deny, [], %{}},
    {:main_watch_inherited?, 2, :deny, [:any, :any], %{}},
    {:executor_listen, 0, :deny, [], %{}},
    {:executor_listen, 1, :deny, [:keyword], %{topic: :string}}
  ]

  @test_rows (if Mix.env() == :test do
                test_probe = [:Aiur, :ControlCallTestProbe]
                controller_probe = [:Aiur, :ControlControllerTestProbe]

                [
                  {{test_probe, :actor, 0}, %{class: :read, positional: [], options: %{}}},
                  {{test_probe, :read_wait, 1}, %{class: :read, positional: [:atom], options: %{}}},
                  {{test_probe, :write_wait, 1}, %{class: :agents, positional: [:atom], options: %{}}},
                  {{test_probe, :explode, 0}, %{class: :read, positional: [], options: %{}}},
                  {{controller_probe, :read_wait, 1}, %{class: :read, positional: [:atom], options: %{}}},
                  {{controller_probe, :write_wait, 1}, %{class: :agents, positional: [:atom], options: %{}}},
                  {{[:Aiur, :ControlReplayTestProbe], :write_wait, 1}, %{class: :agents, positional: [:atom], options: %{}}}
                ]
              else
                []
              end)

  @rows Enum.map(@agent_rows, fn {function, arity, class, positional, options} -> {{@agent, function, arity}, %{class: class, positional: positional, options: options}} end) ++
          [
            {{[:Aiur, :ListenModeCli], :run, 2}, %{class: &__MODULE__.listen_mode_category/1, positional: [:non_empty_string, :string_list], options: %{}}},
            {{@handoff, :report, 0}, %{class: :read, positional: [], options: %{json: :boolean, wait_ms: :non_negative, expected_id: :string}}},
            {{@handoff, :report, 1}, %{class: :read, positional: [:keyword], options: %{json: :boolean, wait_ms: :non_negative, expected_id: :string}}},
            {{@handoff, :prepare, 0}, %{class: :deny, positional: [], options: %{}}},
            {{@handoff, :agents, 0}, %{class: :read, positional: [], options: %{}}},
            {{@session, :rpc, 1}, %{class: :read, positional: [:keyword], options: %{json: :boolean}}},
            {{@usage, :rpc, 2}, %{class: :read, positional: [{:nullable, :string}, :boolean], options: %{}}},
            {{@usage, :legacy_accounts, 2}, %{class: :read, positional: [:boolean, {:nullable, :string}], options: %{}}},
            {{@ticket_usage, :rpc, 2}, %{class: :read, positional: [{:regex, ~r/^[1-9][0-9]*$/}, :keyword], options: %{json: :boolean}}},
            {{@sweep, :rpc, 1}, %{class: &__MODULE__.sweep_category/1, positional: [:keyword], options: %{argv: :literal_list, json: :boolean}}},
            {{@pr_merge, :print_watcher_state, 0}, %{class: :deny, positional: [], options: %{}}},
            {{@pr_merge, :publish, 1}, %{class: :deny, positional: [:string], options: %{}}}
          ] ++ @test_rows
  @table Map.new(@rows)
  @categories Enum.map(Aiur.ClientTokens.categories(), &String.to_atom/1)

  @doc "Permission categories a remote call can need. `:trust` is deliberately absent: nothing remote maps to it."
  @spec categories() :: [atom()]
  def categories, do: @categories

  @spec scope_of(atom()) :: :read | :write | :deny
  def scope_of(:read), do: :read
  def scope_of(:deny), do: :deny
  def scope_of(category) when category in @categories, do: :write

  @spec history_label_category(list()) :: atom()
  def history_label_category([opts]) do
    case Keyword.get(opts, :action, :status) do
      action when action in [:plan, :status] -> :read
      :pause -> :tickets
      _ -> :deny
    end
  end

  @spec fetch([atom()], atom(), non_neg_integer()) :: {:ok, map()} | :error
  def fetch(segments, function, arity), do: Map.fetch(@table, {segments, function, arity})

  @spec entries() :: map()
  def entries, do: @table

  @spec facade_functions() :: [{atom(), non_neg_integer()}]
  def facade_functions, do: Facade.functions()

  @spec listen_mode_category(list()) :: atom()
  def listen_mode_category([_ticket, argv]), do: if(argv in [[], ["--json"]], do: :read, else: :agents)

  @spec watch_category(list()) :: atom()
  def watch_category(args), do: if(option(args, :mode) == :full, do: :read, else: :executor)

  @spec wait_category(list()) :: atom()
  def wait_category(_args), do: :executor

  @spec estimate_category(list()) :: atom()
  def estimate_category(args), do: if(option(args, :hours) || option(args, :clear, false), do: :tickets, else: :read)

  @spec feature_category(list()) :: atom()
  def feature_category(args), do: if(option(args, :op) == :show, do: :read, else: :tickets)

  @spec lane_category(list()) :: atom()
  def lane_category(args), do: if(option(args, :action) in [:show, :list], do: :read, else: :tickets)

  @spec epic_category(list()) :: atom()
  def epic_category(args), do: lane_category(args)

  @spec queue_category(list()) :: atom()
  def queue_category(args) do
    verb = option(args, :verb, :show)

    cond do
      verb in [:add, :set, :remove, :reorder, :hold, :release, :recover, :clear] -> :deny
      verb == :order and (option(args, :queue) || option(args, :to)) -> :deny
      verb == :order -> :read
      verb == :show -> :read
      true -> :tickets
    end
  end

  @spec alerts_category(list()) :: atom()
  def alerts_category(args), do: if(Enum.any?(option(args, :argv, []), &(&1 in ["ack", :ack])), do: :deny, else: :read)

  @spec sweep_category(list()) :: atom()
  def sweep_category(args), do: if(option(args, :apply, false), do: :tickets, else: :read)

  @spec experiment_category(list()) :: atom()
  def experiment_category(args), do: if(option(args, :verb) in [:show, :list, :stats, :events, :metrics, :analyze], do: :read, else: :config)
  defp option(args, key, default \\ nil), do: Enum.find_value(List.wrap(args), default, fn item -> if is_list(item) and Keyword.keyword?(item), do: Keyword.get(item, key), else: nil end)
end
