defmodule Aiur.AsksCLI do
  @moduledoc false

  alias Aiur.{Commands, ExecutorCommandCLI}
  alias Aiur.ControlCLI.ExecutorRequest
  alias Aiur.GitHub.Config, as: GitHubConfig

  @type command ::
          {:create, %{title: String.t(), body: String.t() | nil, urgency: String.t(), blocking: boolean()}}
          | {:done, %{id: String.t(), note: String.t() | nil}}
          | {:list, %{status: :open | :all, json: boolean()}}

  @spec rpc([String.t()], String.t(), keyword()) :: :ok
  def rpc(argv, executor_id, deps \\ []) do
    code =
      case Aiur.CLI.evaluate(argv) do
        {:asks, command} -> run(command, &IO.puts/1, &GitHubConfig.repo/0, &execute(&1, &2, executor_id, deps))
        _ -> write_error(&IO.puts/1, "invalid ask arguments")
      end

    IO.puts("__AIUR_CONTROL_EXIT__:#{code}")
  end

  @spec run(command(), (iodata() -> :ok), (-> String.t() | nil), (atom(), keyword() -> non_neg_integer())) :: non_neg_integer()
  def run(command, puts \\ &IO.puts/1, repo_fun \\ &GitHubConfig.repo/0, rpc_fun \\ &execute(&1, &2, "aiur-cli", []))

  def run({:create, attrs}, puts, _repo_fun, rpc_fun) do
    params = [question: attrs.title, long_context_markdown: attrs.body, urgency: attrs.urgency, blocking: attrs.blocking, options: []]

    rpc_fun.(
      :request,
      Keyword.put(params, :result_fun, fn decision, _status, _source_id, _json ->
        puts.(["Created ", decision.decision_id, if(attrs.blocking, do: " (BLOCKING)", else: ""), "."])
        puts.("Deprecated: use aiur command request; Command IDs now use the dec_ prefix.")
      end)
    )
  end

  def run({:done, %{id: "ask_" <> _}} = command, puts, repo_fun, _rpc_fun), do: run_legacy(command, puts, repo_fun)

  def run({:done, %{id: id, note: note}}, puts, _repo_fun, rpc_fun) do
    params = [decision_id: id, reason_class: "executor_withdrew", error_fun: puts]
    params = if is_nil(note), do: params, else: Keyword.put(params, :reason, note)
    rpc_fun.(:moot, params)
  end

  def run({:list, _} = command, puts, repo_fun, _rpc_fun), do: run_legacy(command, puts, repo_fun)

  defp run_legacy(command, puts, repo_fun) do
    case repo_fun.() do
      repo when is_binary(repo) and repo != "" -> run_for_repo(command, repo, puts)
      _ -> write_error(puts, "could not determine the current repository")
    end
  end

  defp execute(:request, params, executor_id, deps) do
    {result_fun, params} = Keyword.pop!(params, :result_fun)
    ExecutorRequest.request(Keyword.put(params, :executor_id, executor_id), Keyword.put(deps, :result_fun, result_fun))
  end

  defp execute(:moot, params, executor_id, deps) do
    case Commands.get(params[:decision_id], store: Keyword.get(deps, :decision_store, Commands.default_store())) do
      {:ok, %{decision: decision}} ->
        params |> Keyword.merge(expected_version: decision.version, executor_id: executor_id) |> ExecutorCommandCLI.moot(Keyword.put(deps, :error_fun, params[:error_fun]))

      {:error, reason} ->
        write_error(params[:error_fun], reason)
    end
  end

  defp run_for_repo({:done, %{id: id, note: note}}, repo, puts) do
    case Commands.resolve_ask(repo, id, note) do
      {:ok, _ask} ->
        puts.(["Resolved ", id, "."])
        0

      {:error, reason} ->
        write_error(puts, reason)
    end
  end

  defp run_for_repo({:list, %{status: status, json: json}}, repo, puts) do
    reader = if status == :open, do: &Commands.open_asks/1, else: &Commands.all_asks/1

    case reader.(repo) do
      {:ok, asks} when json ->
        puts.(Jason.encode!(asks))
        0

      {:ok, asks} ->
        Enum.each(asks, &puts.(render(&1)))
        puts.("Legacy asks only. View Executor Commands with aiur commands.")
        0

      {:error, reason} ->
        write_error(puts, reason)
    end
  end

  defp render(ask) do
    state = if ask["status"] == "done", do: "DONE", else: "OPEN"
    blocking = if ask["blocking"], do: " BLOCKING", else: ""

    [
      "[#{state}#{blocking}] #{ask["id"]} (#{ask["urgency"]}, by #{ask["created_by"]}, #{ask["created_at"]})\n",
      ask["title"],
      render_body(ask["body"]),
      render_resolution(ask)
    ]
  end

  defp render_body(nil), do: ""
  defp render_body(""), do: ""
  defp render_body(body), do: "\n" <> body

  defp render_resolution(%{"status" => "done"} = ask) do
    note = if ask["note"] in [nil, ""], do: "", else: "\nNote: " <> ask["note"]
    "\nResolved by #{ask["resolved_by"]} at #{ask["resolved_at"]}." <> note
  end

  defp render_resolution(_ask), do: ""

  defp write_error(puts, reason) do
    puts.(["aiur ask: ", format_error(reason)])
    2
  end

  defp format_error({:ask_not_found, id}), do: "ask #{id} was not found"
  defp format_error({:ask_already_done, id}), do: "ask #{id} is already done"
  defp format_error({:invalid_ask_transition, :duplicate_open}), do: "open ask must create a new id"
  defp format_error({:invalid_ask_transition, :orphan_done}), do: "done ask must reference an open id"
  defp format_error({:invalid_ask_transition, :duplicate_done}), do: "ask is already done"
  defp format_error({:invalid_ask, :id}), do: "ask id is invalid"
  defp format_error({:invalid_ask, :status}), do: "ask status must be open or done"
  defp format_error({:invalid_ask, :urgency}), do: "ask urgency must be one of: low, normal, high"
  defp format_error({:invalid_ask, :body_or_note}), do: "ask body and note must be text"
  defp format_error({:invalid_ask, key}), do: "ask requires valid #{key}"
  defp format_error({:ask_record_too_large, size, limit}), do: "ask exceeds the #{limit}-byte atomic append limit (got #{size} bytes)"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
