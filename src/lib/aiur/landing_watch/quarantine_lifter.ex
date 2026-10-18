defmodule Aiur.LandingWatch.QuarantineLifter do
  @moduledoc "Removes a test from quarantine after its tracking fix PR merges."
  use GenServer
  require Logger

  alias Aiur.Config.TrackerSettings
  alias Aiur.Events
  alias Aiur.GitHub.{Errors, Transport}
  alias Aiur.LandingWatch.Journal

  @list_path "src/test/quarantine.txt"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec lift(pos_integer(), keyword()) :: :ok | {:ok, :already_claimed} | {:error, term()}
  def lift(ticket, opts \\ [])

  def lift(ticket, opts) when is_integer(ticket) and ticket > 0 do
    claim = "quarantine-lift :: #{ticket}"

    case Journal.claim_flake(claim, opts) do
      {:ok, :already_claimed} -> {:ok, :already_claimed}
      {:ok, :new} -> lift_claimed(ticket, claim, opts)
      {:error, _} = error -> error
    end
  end

  def lift(_, _), do: {:error, :invalid_quarantine_ticket}

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe?, true), do: :ok = Events.subscribe("ticket.*.pr.merged")
    {:ok, opts}
  end

  @impl true
  def handle_info({:event, %{topic: topic}}, opts) do
    case Regex.run(~r/^ticket\.([1-9][0-9]*)\.pr\.merged$/, topic) do
      [_, ticket] -> start_lift(String.to_integer(ticket), opts)
      _ -> :ok
    end

    {:noreply, opts}
  end

  def handle_info(_event, opts), do: {:noreply, opts}

  defp start_lift(ticket, opts) do
    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> log_result(ticket, lift(ticket, opts)) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.warning("quarantine lift task failed to start ticket=#{ticket} reason=#{inspect(reason)}")
    end
  end

  defp log_result(ticket, result) do
    case result do
      :ok -> :ok
      {:ok, :already_claimed} -> :ok
      {:error, reason} -> Logger.warning("quarantine lift failed ticket=#{ticket} reason=#{inspect(reason)}")
    end
  end

  defp lift_claimed(ticket, claim, opts) do
    result = fetch_list(ticket, opts)
    if result == :ok, do: :ok, else: release_claim(claim, opts, result)
  end

  defp release_claim(claim, opts, result) do
    case Journal.release_flake(claim, opts) do
      :ok -> result
      {:error, reason} -> {:error, {:quarantine_lift_claim_release_failed, reason}}
    end
  end

  defp fetch_list(ticket, opts) do
    with {:ok, context} <- context(opts),
         {:ok, contents, file_sha} <- get_contents(context, opts),
         {:ok, updated} <- remove_ticket(contents, ticket),
         :ok <- open_removal_pr(context, file_sha, updated, ticket, opts) do
      :ok
    else
      {:error, :ticket_not_quarantined} -> :ok
      {:error, _} = error -> error
    end
  end

  defp context(opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      {:ok, %{owner: owner, repo: repo, token: token, base: Keyword.get_lazy(opts, :base_branch, &TrackerSettings.base_branch/0)}}
    end
  end

  defp get_contents(context, opts) do
    url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/contents/#{@list_path}?ref=#{context.base}"

    case request(opts).(%{method: :get, url: url, token: context.token, caller: "quarantine_lift_contents"}) do
      {:ok, %{status: 200, body: %{"content" => encoded, "sha" => sha, "encoding" => "base64"}}} ->
        case Base.decode64(String.replace(encoded, ~r/\s/, "")) do
          {:ok, contents} -> {:ok, contents, sha}
          :error -> {:error, :invalid_quarantine_list_encoding}
        end

      {:ok, response} ->
        {:error, Errors.github_status_error(response)}

      {:error, _} = error ->
        error
    end
  end

  defp remove_ticket(contents, ticket) do
    target = "##{ticket}"
    lines = String.split(contents, "\n")
    retained = Enum.reject(lines, &ticket_entry?(&1, target))

    if retained == lines, do: {:error, :ticket_not_quarantined}, else: {:ok, Enum.join(retained, "\n")}
  end

  defp ticket_entry?(line, target) do
    case String.split(line, "\t") do
      [_module, _name, ^target] -> true
      _ -> false
    end
  end

  defp open_removal_pr(context, file_sha, contents, ticket, opts) do
    branch = "aiur/quarantine-lift-#{ticket}-#{context.base}"

    with {:ok, base_sha} <- base_sha(context, opts),
         :ok <- create_branch(context, branch, base_sha, opts),
         :ok <- update_file(context, branch, file_sha, contents, opts) do
      create_pr(context, branch, ticket, opts)
    end
  end

  defp base_sha(context, opts) do
    url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/git/ref/heads/#{context.base}"

    case request(opts).(%{method: :get, url: url, token: context.token, caller: "quarantine_lift_base"}) do
      {:ok, %{status: 200, body: %{"object" => %{"sha" => sha}}}} -> {:ok, sha}
      {:ok, response} -> {:error, Errors.github_status_error(response)}
      {:error, _} = error -> error
    end
  end

  defp create_branch(context, branch, sha, opts) do
    url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/git/refs"
    body = %{"ref" => "refs/heads/#{branch}", "sha" => sha}
    expect_write(request(opts).(%{method: :post, url: url, token: context.token, caller: "quarantine_lift_branch", body: body}), [201])
  end

  defp update_file(context, branch, sha, contents, opts) do
    url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/contents/#{@list_path}"
    body = %{"message" => "Lift fixed test quarantine", "content" => Base.encode64(contents), "branch" => branch, "sha" => sha}
    expect_write(request(opts).(%{method: :put, url: url, token: context.token, caller: "quarantine_lift_file", body: body}), [200])
  end

  defp create_pr(context, branch, ticket, opts) do
    url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/pulls"
    body = %{"title" => "Lift fixed test quarantine", "body" => "Removes quarantine entries tracked by ##{ticket} after the fix merged.", "head" => branch, "base" => context.base}
    expect_write(request(opts).(%{method: :post, url: url, token: context.token, caller: "quarantine_lift_pr", body: body}), [200, 201])
  end

  defp expect_write({:ok, %{status: status} = response}, accepted) do
    if status in accepted, do: :ok, else: {:error, Errors.github_status_error(response)}
  end

  defp expect_write({:error, _} = error, _accepted), do: error
  defp request(opts), do: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
end
