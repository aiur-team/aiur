defmodule Aiur.BuildQueue.MutationCLI do
  @moduledoc false
  alias Aiur.BuildQueue

  @spec run(keyword()) :: 0 | 1 | 64 | 124
  def run(opts) do
    case execute(opts) do
      {:ok, results} ->
        if Keyword.get(opts, :json, false), do: print_json(results), else: print_results(results)

        cond do
          Enum.any?(results, &match?({_, {:error, :outcome_unknown}}, &1)) -> 124
          Enum.all?(results, &successful?/1) -> 0
          true -> 1
        end

      {:error, reason} ->
        Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1)).("aiur: queue #{message({:error, reason})}")
        if reason in [:agent_workspace, :invalid_arguments, :invalid_start_trigger], do: 64, else: 1
    end
  end

  @spec execute(keyword()) :: {:ok, [{String.t(), :ok | {:ok, [String.t()]} | {:error, term()}}]} | {:error, term()}
  def execute(opts) do
    with :ok <- guard_workspace(opts), :ok <- validate(opts), {:ok, opts} <- trigger(opts), :ok <- confirm(opts) do
      cond do
        opts[:build_order] -> adopt(opts)
        opts[:feature] -> adopt_feature(opts)
        true -> dispatch(Keyword.fetch!(opts, :verb), opts)
      end
    end
  end

  defp guard_workspace(opts) do
    if Keyword.get(opts, :caller_agent_workspace, "") == "", do: :ok, else: {:error, :agent_workspace}
  end

  defp validate(opts) do
    ids = Keyword.get(opts, :ids, [])
    queue = opts[:queue]
    valid = is_list(ids) and Enum.all?(ids, &id?/1) and Enum.uniq(ids) == ids and valid_queue?(queue)
    valid = valid and valid_rank?(opts)
    valid = valid and valid_options?(opts) and valid_command?(opts[:verb], ids, opts)
    if valid, do: :ok, else: {:error, :invalid_arguments}
  end

  defp valid_options?(opts) do
    Enum.all?(Keyword.keys(opts), &(&1 in (allowed_options(opts[:verb]) ++ [:verb, :caller_agent_workspace, :server, :error_fun, :settings])))
  end

  defp valid_queue?(nil), do: true
  defp valid_queue?(queue), do: is_binary(queue) and String.trim(queue) != ""

  defp valid_rank?(opts) do
    not Keyword.has_key?(opts, :rank) or
      (position?(opts[:rank]) and
         (is_binary(opts[:queue]) or not is_nil(opts[:build_order]) or not is_nil(opts[:feature])))
  end

  defp allowed_options(:order), do: [:queue, :to]

  defp allowed_options(verb) do
    case verb do
      :add -> [:ids, :queue, :after, :at, :build_order, :feature, :start_on, :rank, :json]
      :set -> [:queue, :start_on]
      :recover -> [:force]
      :clear -> [:remove_markers, :yes]
      :remove -> [:ids]
      :reorder -> [:ids, :to]
      verb when verb in [:hold, :release] -> [:ids, :queue]
      _ -> []
    end
  end

  defp valid_command?(:add, ids, opts) do
    cond do
      opts[:build_order] -> valid_root_add?(ids, opts)
      opts[:feature] -> valid_feature_add?(ids, opts)
      true -> valid_id_add?(ids, opts)
    end
  end

  defp valid_command?(:order, [], opts), do: is_binary(opts[:queue]) and position?(opts[:to])
  defp valid_command?(:set, [], opts), do: is_binary(opts[:queue]) and Keyword.has_key?(opts, :start_on)
  defp valid_command?(:recover, [], opts), do: Keyword.get(opts, :force, false) in [true, false]
  defp valid_command?(:clear, [], opts), do: opts[:remove_markers] == true and Keyword.get(opts, :yes, false) in [true, false]
  defp valid_command?(:remove, ids, opts), do: ids != [] and is_nil(opts[:queue])
  defp valid_command?(:reorder, [_], opts), do: position?(opts[:to]) and is_nil(opts[:queue])
  defp valid_command?(verb, ids, opts) when verb in [:hold, :release], do: (length(ids) == 1 and is_nil(opts[:queue])) or (ids == [] and is_binary(opts[:queue]))
  defp valid_command?(_, _, _), do: false

  defp valid_root_add?(ids, opts) do
    ids == [] and positive?(opts[:build_order]) and is_nil(opts[:after]) and is_nil(opts[:at]) and is_nil(opts[:feature])
  end

  defp valid_feature_add?(ids, opts) do
    ids == [] and valid_slug?(opts[:feature]) and is_nil(opts[:after]) and is_nil(opts[:at]) and is_nil(opts[:build_order])
  end

  defp valid_id_add?(ids, opts) do
    ids != [] and valid_after?(opts[:after], ids) and (is_nil(opts[:at]) or position?(opts[:at])) and
      is_nil(opts[:feature]) and is_nil(opts[:build_order])
  end

  defp valid_after?(nil, _ids), do: true
  defp valid_after?(id, ids), do: id?(id) and (id not in ids or length(ids) > 1)

  defp id?(id), do: is_binary(id) and Regex.match?(~r/\A[1-9][0-9]*\z/, id)
  defp valid_slug?(slug), do: is_binary(slug) and String.trim(slug) != ""
  defp position?(n), do: is_integer(n) and n >= 0
  defp positive?(n), do: is_integer(n) and n > 0

  defp trigger(opts) do
    cond do
      not Keyword.has_key?(opts, :start_on) ->
        {:ok, opts}

      opts[:verb] == :set and opts[:start_on] == "default" ->
        {:ok, Keyword.put(opts, :start_on, nil)}

      true ->
        with {:ok, value} <- Aiur.StartTrigger.parse(opts[:start_on]), do: {:ok, Keyword.put(opts, :start_on, value)}
    end
  end

  defp adopt(opts) do
    root = opts[:build_order]
    command = if Keyword.has_key?(opts, :start_on), do: {:adopt, root, opts[:queue], opts[:start_on]}, else: {:adopt, root, opts[:queue]}
    command = if Keyword.has_key?(opts, :rank), do: {:adopt, root, opts[:queue], opts[:start_on], opts[:rank]}, else: command
    result = call({:mutate, command}, opts)

    results =
      case result do
        {:ok, refusals} ->
          accepted = accepted_member_rows(root, opts)
          refused = Enum.map(refusals, fn {id, reason} -> {"##{id}", {:error, owning_queue(reason, id, opts)}} end)
          [{"Build Order ##{root}", :ok} | accepted ++ refused]

        error ->
          [{"Build Order ##{root}", error}]
      end

    {:ok, results}
  end

  defp accepted_member_rows(root, opts) do
    if Keyword.get(opts, :json, false) do
      BuildQueue.show(server(opts)).queues
      |> Enum.find(&(&1.root == root))
      |> accepted_member_rows()
    else
      []
    end
  end

  defp accepted_member_rows(%{items: items}), do: Enum.map(items, &{"##{&1.number}", :ok})
  defp accepted_member_rows(_queue), do: []

  defp adopt_feature(opts) do
    slug = opts[:feature]
    command = if Keyword.has_key?(opts, :start_on), do: {:adopt_feature, slug, opts[:queue], opts[:start_on]}, else: {:adopt_feature, slug, opts[:queue]}
    command = if Keyword.has_key?(opts, :rank), do: {:adopt_feature, slug, opts[:queue], opts[:start_on], opts[:rank]}, else: command
    result = call({:mutate, command}, opts)
    if match?({:ok, _refusals}, result), do: warn_set_order(opts)

    results =
      case result do
        {:ok, refusals} ->
          accepted = accepted_feature_rows(slug, opts)
          refused = Enum.map(refusals, &{"##{elem(&1, 0)}", elsewhere_result(&1, opts)})
          [{"Feature #{slug}", :ok} | accepted ++ refused]

        error ->
          [{"Feature #{slug}", error}]
      end

    {:ok, results}
  end

  # A member another set already owns stays there; the feature set itself still succeeds (KTD9).
  defp elsewhere_result({id, :already_queued}, opts), do: {:ok, {:owned_elsewhere, owner_name(id, opts)}}
  defp elsewhere_result({_id, reason}, _opts), do: {:error, reason}

  defp owner_name(id, opts) do
    case owning_queue(:already_queued, id, opts) do
      {:already_queued, name} -> name
      _ -> nil
    end
  end

  defp accepted_feature_rows(slug, opts) do
    if Keyword.get(opts, :json, false) do
      BuildQueue.show(server(opts)).queues
      |> Enum.find(&(&1.feature == slug))
      |> accepted_member_rows()
    else
      []
    end
  end

  # A feature entry has no stored positions, so its order only exists when set order is ranked.
  defp warn_set_order(opts) do
    case settings(opts) do
      {:ok, %{build_queue: %{set_order: "none"}}} ->
        Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1)).(
          "aiur: build_queue.set_order is none, so feature entries have no declared order; set build_queue.set_order to ranked to order entries by rank"
        )

      _ ->
        :ok
    end
  end

  defp settings(opts) do
    case Keyword.get(opts, :settings) do
      nil -> Aiur.Config.settings()
      %{} = settings -> {:ok, settings}
      other -> other
    end
  end

  defp confirm(opts) do
    if opts[:verb] == :clear and opts[:yes] != true, do: {:error, :confirmation_required}, else: :ok
  end

  defp dispatch(:add, opts) do
    if(opts[:after] in opts[:ids], do: dispatch_add_batch(opts), else: dispatch_add_ids(opts))
  end

  defp dispatch(:order, opts), do: {:ok, [{opts[:queue], call({:mutate, {:order, opts[:queue], opts[:to]}}, opts)}]}
  defp dispatch(:set, opts), do: {:ok, [{opts[:queue], call({:mutate, {:set_trigger, opts[:queue], opts[:start_on]}}, opts)}]}
  defp dispatch(:recover, opts), do: {:ok, [{"recover", call({:recover, Keyword.get(opts, :force, false)}, opts)}]}
  defp dispatch(:clear, opts), do: {:ok, [{"clear", call({:mutate, {:clear, Keyword.take(opts, [:remove_markers, :yes])}}, opts)}]}
  defp dispatch(:remove, opts), do: {:ok, Enum.map(opts[:ids], &{"##{&1}", call({:mutate, {:remove, &1}}, opts)})}
  defp dispatch(:reorder, opts), do: {:ok, [{"##{hd(opts[:ids])}", call({:mutate, {:reorder, hd(opts[:ids]), opts[:to]}}, opts)}]}

  defp dispatch(verb, opts) do
    with {:ok, target} <- target(opts) do
      {:ok, [{opts[:queue] || "##{target}", call({verb, target}, opts)}]}
    end
  end

  defp dispatch_add_ids(opts) do
    {results, _} =
      Enum.map_reduce(opts[:ids], {opts[:at], Keyword.take(opts, [:rank])}, fn id, {at, rank} ->
        options = Keyword.take(opts, [:after]) |> Keyword.merge(rank) |> Keyword.put(:queue, opts[:queue] || "default")
        options = if Keyword.has_key?(opts, :start_on), do: Keyword.put(options, :start_trigger, opts[:start_on]), else: options
        options = if is_nil(at), do: options, else: Keyword.put(options, :at, at)
        result = call({:mutate, {:add, [id], options}}, opts)
        {{"##{id}", result}, {if(inserted?(result) and is_integer(at), do: at + 1, else: at), if(inserted?(result), do: [], else: rank)}}
      end)

    {:ok, results}
  end

  defp dispatch_add_batch(opts) do
    options = Keyword.take(opts, [:after, :at, :rank]) |> Keyword.put(:queue, opts[:queue] || "default")
    options = if Keyword.has_key?(opts, :start_on), do: Keyword.put(options, :start_trigger, opts[:start_on]), else: options

    case call({:mutate, {:add, opts[:ids], options}}, opts) do
      {:ok, {:not_observed, ids}} ->
        {:ok, Enum.map(opts[:ids], fn id -> {"##{id}", if(id in ids, do: {:ok, {:not_observed, [id]}}, else: :ok)} end)}

      {:error, {:already_queued, _queue}} = result ->
        queued_ids = queued_ids(server(opts), opts[:ids])
        {:ok, Enum.map(opts[:ids], fn candidate -> {"##{candidate}", if(candidate in queued_ids, do: result, else: {:error, :batch_aborted})} end)}

      result ->
        {:ok, Enum.map(opts[:ids], &{"##{&1}", result})}
    end
  end

  defp inserted?(:ok), do: true
  defp inserted?({:ok, {:not_observed, ids}}) when is_list(ids), do: true
  defp inserted?({:ok, {:marker_deferred, ids}}) when is_list(ids), do: true
  defp inserted?({:error, {:marker_write_failed, _}}), do: true
  defp inserted?(_), do: false

  defp queued_ids(server, ids) do
    case BuildQueue.show(server) do
      %{queues: queues} ->
        for queue <- queues, item <- queue.items, "#{item.number}" in ids, do: "#{item.number}"

      _ ->
        []
    end
  end

  defp successful?({_id, :ok}), do: true
  defp successful?({_id, {:ok, {:not_observed, ids}}}) when is_list(ids), do: true
  defp successful?({_id, {:ok, unobserved}}) when is_list(unobserved), do: true
  defp successful?({_id, {:ok, {:marker_deferred, ids}}}) when is_list(ids), do: true
  defp successful?({_id, {:ok, {:owned_elsewhere, _name}}}), do: true
  defp successful?(_), do: false

  defp target(opts) do
    if opts[:queue] do
      model = BuildQueue.show(server(opts))
      select_queue(model, opts[:queue])
    else
      {:ok, hd(opts[:ids])}
    end
  end

  defp select_queue(%{status: status}, _name) when status not in [:running, :writes_paused], do: {:error, status}

  defp select_queue(model, name) do
    case Enum.find(model.queues, &(&1.name == name)) do
      nil -> {:error, :not_found}
      queue -> {:ok, queue.queue_id}
    end
  end

  defp owning_queue(:already_queued, id, opts) do
    model = BuildQueue.show(server(opts))
    queue = Enum.find(model.queues, fn queue -> Enum.any?(queue.items, &(&1.number == String.to_integer(id))) end)
    if queue, do: {:already_queued, queue.name}, else: :already_queued
  end

  defp owning_queue(reason, _, _), do: reason
  defp server(opts), do: Keyword.get(opts, :server, Aiur.BuildQueue.Server)

  defp call(command, opts) do
    GenServer.call(server(opts), command, 30_000)
  catch
    :exit, {:noproc, _} -> {:error, BuildQueue.show(server(opts)).status}
    :exit, {:timeout, _} -> {:error, :outcome_unknown}
  end

  defp message({:error, :confirmation_required}), do: "clear requires --yes; removes all queue membership and markers, keeping todo"
  defp message({:error, :invalid_start_trigger}), do: "--start-on must be one of: #{Enum.join(Aiur.StartTrigger.triggers(), ", ")} (set also accepts default)"
  defp message({:error, :trigger_mismatch}), do: "queue has a different start trigger; use queue set NAME --start-on TRIGGER"
  defp message({:error, :anchor_not_in_queue}), do: "--after anchor is not in this queue (add it in the same command or choose a queue member)"
  defp message({:error, :batch_aborted}), do: "not applied because another ID in this all-or-nothing batch was refused"
  defp message(:ok), do: "ok"
  defp message({:error, {:already_queued, name}}), do: "already in queue #{name}"
  defp message({:error, :agent_workspace}), do: "blocked in agent workspace"
  defp message({:error, :outcome_unknown}), do: "outcome unknown; run aiur queue show before retrying"
  defp message({:ok, {:not_observed, ids}}), do: "not yet observed (retry after next poll) for ##{Enum.join(ids, ", #")}; queued pending"
  defp message({:ok, {:deferred, :paced}}), do: "queued; marker write deferred and will retry"
  defp message({:ok, {:marker_deferred, ids}}), do: "queued; marker write deferred and will retry for #{Enum.map_join(ids, ", ", &"##{&1}")}"
  defp message({:ok, unobserved}) when is_list(unobserved), do: "released; no observation for ##{Enum.join(unobserved, ", #")}"
  defp message({:error, {:marker_write_failed, failures}}), do: marker_failure_message(failures)
  defp message({:ok, {:owned_elsewhere, name}}) when is_binary(name), do: "owned by queue #{name}; stays there"
  defp message({:ok, {:owned_elsewhere, _name}}), do: "owned by another set; stays there"
  defp message({:error, :feature_not_found}), do: "feature not found in the feature registry"
  defp message({:error, :too_many_features}), do: "too many feature entries"
  defp message({:error, :already_adopted}), do: "already queued as a feature or Build Order entry"
  defp message({:error, :observation_unavailable}), do: "ticket observation unavailable; retry after the next poll"
  defp message({:error, :features_down}), do: "feature registry unavailable"
  defp message({:error, reason}) when is_atom(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")
  defp message({:error, _reason}), do: "failed; inspect queue status and retry if needed"

  defp marker_failure_message(failures) do
    if Enum.all?(failures, fn {_action, _id, result} -> result == {:error, :paced} end) do
      "queued; marker write deferred and will retry"
    else
      "queued, but marker write failed; retry is scheduled"
    end
  end

  defp print_results(results), do: Enum.each(results, fn {id, result} -> IO.puts("#{id}: #{message(result)}") end)

  defp print_json(results) do
    rows = Enum.map(results, fn {id, result} -> %{id: id, status: status(result), outcome: outcome(result), message: message(result)} end)
    IO.puts(Jason.encode!(Aiur.JSONSafe.normalize(%{schema_version: 1, command: "queue add", results: rows})))
  end

  defp status({:error, :outcome_unknown}), do: :unknown
  defp status(result), do: if(successful?({nil, result}), do: :ok, else: :error)

  defp outcome(:ok), do: :added
  defp outcome({:ok, {:not_observed, _ids}}), do: :queued_pending
  defp outcome({:ok, {:marker_deferred, _ids}}), do: :marker_deferred
  defp outcome({:ok, {:owned_elsewhere, _name}}), do: :owned_elsewhere
  defp outcome({:ok, {:deferred, :paced}}), do: :marker_deferred
  defp outcome({:error, {:already_queued, _queue}}), do: :already_queued
  defp outcome({:error, :batch_aborted}), do: :batch_aborted
  defp outcome({:error, :outcome_unknown}), do: :outcome_unknown
  defp outcome({:error, reason}) when is_atom(reason), do: reason
  defp outcome({:error, _reason}), do: :refused
  defp outcome({:ok, _}), do: :added
end
