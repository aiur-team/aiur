defmodule Aiur.ExecutorWakeInbox.StaleHumanReview do
  @moduledoc false

  require Logger

  alias Aiur.Config
  alias Aiur.GitHub.{Access, Labels}
  alias Aiur.GitHub.Config, as: GitHubConfig

  @spec filter([map()], (map() -> :current | {:stale, atom()} | :unknown)) :: {[map()], [map()]}
  def filter(records, reader) when is_list(records) and is_function(reader, 1) do
    {deliver, stale} = Enum.split_with(records, &(not stale?(safely_read_state(reader, &1))))
    Enum.each(stale, &log_stale/1)
    {deliver, stale}
  end

  @spec current_state(map()) :: :current | {:stale, atom()} | :unknown
  def current_state(%{"action" => "human_review"} = wake) do
    with {:ok, number} <- issue_number(wake["ticket"]),
         repo when is_binary(repo) <- GitHubConfig.repo(Config.settings!()) do
      read_state(repo, number)
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  def current_state(_wake), do: :current

  defp safely_read_state(reader, record) do
    reader.(record)
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  defp read_state(repo, number) do
    issue = Access.data(Access.key_for_repo(:issue, repo, number))

    case issue do
      %{"state" => state} when is_binary(state) ->
        case String.downcase(state) do
          "open" -> classify_labels(issue, repo, number)
          "closed" -> {:stale, :closed}
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  defp classify_labels(issue, repo, number) do
    labels =
      case Access.data(Access.key_for_repo(:issue_labels, repo, number)) do
        labels when is_list(labels) -> {:ok, label_names(labels)}
        _ -> labels_from_issue(issue)
      end

    case labels do
      {:ok, labels} ->
        prefix = Config.settings!().tracker.github.label_prefix
        states = Enum.filter(labels, &(&1 in Labels.state_labels(prefix)))
        human_review = "#{prefix}:human-review"

        case states do
          [^human_review] -> :current
          [] -> {:stale, :missing_agent_state}
          _ -> {:stale, :state_changed}
        end

      :unknown ->
        :unknown
    end
  end

  defp labels_from_issue(%{"labels" => labels}) when is_list(labels), do: {:ok, label_names(labels)}
  defp labels_from_issue(_issue), do: :unknown

  defp label_names(labels) when is_list(labels), do: Enum.map(labels, &String.downcase(Map.get(&1, "name") || ""))
  defp label_names(_labels), do: []

  defp issue_number(ticket) when is_binary(ticket) do
    case Regex.run(~r/(?:#|\A)(\d+)\z/, ticket) do
      [_, number] -> {:ok, String.to_integer(number)}
      _ -> :error
    end
  end

  defp issue_number(_ticket), do: :error

  defp stale?({:stale, _reason}), do: true
  defp stale?(_result), do: false

  defp log_stale(%{"wake_id" => id, "ticket" => ticket}) do
    Logger.info("aiur_executor_wake_inbox phase=stale_human_review_dropped wake_id=#{id} ticket=#{inspect(ticket)}")
  end

  defp log_stale(_record), do: :ok
end
