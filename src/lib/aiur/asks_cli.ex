defmodule Aiur.AsksCLI do
  @moduledoc false

  alias Aiur.Asks
  alias Aiur.GitHub.Config, as: GitHubConfig

  @type command ::
          {:create, %{title: String.t(), body: String.t() | nil, urgency: String.t(), blocking: boolean()}}
          | {:done, %{id: String.t(), note: String.t() | nil}}
          | {:list, %{status: :open | :all, json: boolean()}}

  @spec run(command(), (iodata() -> :ok), (-> String.t() | nil)) :: non_neg_integer()
  def run(command, puts \\ &IO.puts/1, repo_fun \\ &GitHubConfig.repo/0) do
    case repo_fun.() do
      repo when is_binary(repo) and repo != "" -> run_for_repo(command, repo, puts)
      _ -> write_error(puts, "could not determine the current repository")
    end
  end

  defp run_for_repo({:create, attrs}, repo, puts) do
    case Asks.create(repo, attrs) do
      {:ok, ask} ->
        puts.(["Created ", ask["id"], if(ask["blocking"], do: " (BLOCKING)", else: ""), "."])
        0

      {:error, reason} ->
        write_error(puts, reason)
    end
  end

  defp run_for_repo({:done, %{id: id, note: note}}, repo, puts) do
    case Asks.resolve(repo, id, note) do
      {:ok, _ask} ->
        puts.(["Resolved ", id, "."])
        0

      {:error, reason} ->
        write_error(puts, reason)
    end
  end

  defp run_for_repo({:list, %{status: status, json: json}}, repo, puts) do
    reader = if status == :open, do: &Asks.open/1, else: &Asks.all/1

    case reader.(repo) do
      {:ok, asks} when json ->
        puts.(Jason.encode!(asks))
        0

      {:ok, asks} ->
        Enum.each(asks, &puts.(render(&1)))
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

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
