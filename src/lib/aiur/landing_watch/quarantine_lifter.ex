defmodule Aiur.LandingWatch.QuarantineLifter do
  @moduledoc "Removes a test from quarantine after its tracking fix PR merges or its tracking ticket closes."
  use GenServer
  require Logger

  alias Aiur.Config.TrackerSettings
  alias Aiur.Events
  alias Aiur.GitHub.{Errors, Transport}
  alias Aiur.LandingWatch.Journal
  alias Aiur.LandingWatch.QuarantineNightlyResults
  alias Aiur.TestQuarantine

  @list_paths ["src/test/quarantine.txt", "src/browser/quarantine.txt"]
  # A ticket closed without a merged fix PR never sees `pr.merged`, so its entries are swept.
  @sweep_interval_ms :timer.hours(1)

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

  @doc "Lifts every quarantine entry whose tracking ticket is closed."
  @spec lift_closed(keyword()) :: :ok | {:error, term()}
  def lift_closed(opts \\ []) do
    with {:ok, tickets} <- quarantined_tickets(opts) do
      case lift_expired(opts) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("expired quarantine sweep failed reason=#{inspect(reason)}")
      end

      Enum.each(tickets, &lift_if_closed(&1, opts))
      :ok
    end
  end

  @doc "Applies the nightly quarantine result to entries past their expiry date."
  @spec lift_expired(keyword()) :: :ok | {:error, term()}
  def lift_expired(opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())

    with {:ok, contents} <- test_quarantine_contents(opts),
         {:ok, entries} <- TestQuarantine.parse(contents) do
      expired = Enum.filter(entries, &(Date.compare(&1.expires, today) != :gt))

      if expired == [] do
        :ok
      else
        process_expired_entries(expired, opts)
      end
    end
  end

  defp process_expired_entries(entries, opts) do
    with {:ok, runs} <- QuarantineNightlyResults.fetch(opts) do
      Enum.reduce_while(entries, :ok, &expire_entry_result(&1, &2, runs, opts))
    end
  end

  defp expire_entry_result(entry, :ok, runs, opts) do
    case expire_entry(entry, runs, opts) do
      :ok -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp test_quarantine_contents(opts) do
    case Keyword.get(opts, :test_quarantine_contents_fun) do
      fun when is_function(fun, 1) ->
        fun.(opts)

      _ ->
        with {:ok, context} <- context(hd(@list_paths), opts),
             {:ok, contents, _sha} <- get_contents(context, opts) do
          {:ok, contents}
        end
    end
  end

  defp expire_entry(entry, runs, opts) do
    required = Keyword.get(opts, :green_runs_required, 3)
    identity = entry.module <> " :: " <> entry.name
    recent = Enum.take(runs, required) |> Enum.map(&nightly_status(&1, identity, entry))

    cond do
      length(recent) >= required and Enum.all?(recent, &(&1 == :success)) ->
        ticket = String.to_integer(String.trim_leading(entry.ticket, "#"))
        Keyword.get(opts, :quarantine_lift_fun, &lift/2).(ticket, Keyword.put(opts, :lift_reason, "after #{length(recent)} green nightly quarantine runs")) |> normalize_lift_result()

      Enum.any?(recent, &(&1 == :failure)) ->
        escalate_once(entry, opts)

      true ->
        :ok
    end
  end

  defp nightly_status(%{fallback: fallback, failures: failures}, identity, %{name: "*", module: module}) do
    if Map.has_key?(failures, identity) or module_failure?(failures, module), do: :failure, else: fallback
  end

  defp nightly_status(%{fallback: fallback, failures: failures}, identity, _entry), do: if(Map.has_key?(failures, identity), do: :failure, else: fallback)

  defp nightly_status(_run, _identity, _entry), do: :unknown

  defp module_failure?(failures, module) do
    Enum.any?(failures, fn {identity, result} -> result == :failure and String.starts_with?(identity, module <> " :: ") end)
  end

  defp normalize_lift_result(:ok), do: :ok
  defp normalize_lift_result({:ok, :already_claimed}), do: :ok
  defp normalize_lift_result({:error, _} = error), do: error

  defp escalate_once(entry, opts) do
    claim = "quarantine-expiry-escalation :: #{entry.ticket}"

    case Journal.claim_flake(claim, opts) do
      {:ok, :already_claimed} -> :ok
      {:ok, :new} -> release_failed_escalation(claim, escalate(entry, opts), opts)
      {:error, _} = error -> error
    end
  end

  defp release_failed_escalation(_claim, :ok, _opts), do: :ok

  defp release_failed_escalation(claim, {:error, _} = error, opts) do
    case Journal.release_flake(claim, opts) do
      :ok -> error
      {:error, reason} -> {:error, {:quarantine_escalation_claim_release_failed, reason, error}}
    end
  end

  defp escalate(entry, opts) do
    with {:ok, context} <- context(hd(@list_paths), opts) do
      escalate_ticket(context, String.trim_leading(entry.ticket, "#"), opts)
    end
  end

  defp escalate_ticket(context, number, opts) do
    with :ok <- add_priority_label(context, number, opts) do
      change_label(context, number, :delete, "priority:2", opts)
    end
  end

  defp add_priority_label(context, number, opts) do
    url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/issues/#{number}/labels"

    case request(opts).(%{method: :post, url: url, token: context.token, caller: "quarantine_expiry_priority", body: %{"labels" => ["priority:1"]}}) do
      {:ok, %{status: status}} when status in [200, 201] -> :ok
      {:ok, response} -> {:error, Errors.github_status_error(response)}
      {:error, _} = error -> error
    end
  end

  defp change_label(context, number, method, label, opts) do
    url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/issues/#{number}/labels/#{URI.encode(label)}"

    case request(opts).(%{method: method, url: url, token: context.token, caller: "quarantine_expiry_priority"}) do
      {:ok, %{status: status}} when status in [200, 201, 204] -> :ok
      {:ok, %{status: 404}} when method == :delete -> :ok
      {:ok, response} -> {:error, Errors.github_status_error(response)}
      {:error, _} = error -> error
    end
  end

  defp lift_if_closed(ticket, opts) do
    case issue_state(ticket, opts) do
      {:ok, "closed"} -> log_result(ticket, lift(ticket, Keyword.put(opts, :lift_reason, "now that the ticket is closed")))
      {:ok, _open} -> :ok
      {:error, reason} -> Logger.warning("quarantine ticket state failed ticket=#{ticket} reason=#{inspect(reason)}")
    end
  end

  defp quarantined_tickets(opts) do
    Enum.reduce_while(@list_paths, {:ok, []}, fn path, {:ok, acc} ->
      with {:ok, context} <- context(path, opts),
           {:ok, contents, _sha} <- get_contents(context, opts) do
        {:cont, {:ok, Enum.uniq(acc ++ list_tickets(contents))}}
      else
        {:error, {:github, _, %{status: 404}}} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp list_tickets(contents) do
    for line <- String.split(contents, "\n"),
        fields when length(fields) in [3, 4] <- [String.split(line, "\t")],
        "#" <> number <- [Enum.at(fields, 2)],
        {ticket, ""} <- [Integer.parse(number)],
        do: ticket
  end

  defp issue_state(ticket, opts) do
    with {:ok, context} <- context(hd(@list_paths), opts) do
      url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/issues/#{ticket}"

      case request(opts).(%{method: :get, url: url, token: context.token, caller: "quarantine_lift_ticket_state"}) do
        {:ok, %{status: 200, body: %{"state" => state}}} when is_binary(state) -> {:ok, state}
        {:ok, response} -> {:error, Errors.github_status_error(response)}
        {:error, _} = error -> error
      end
    end
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe?, true), do: :ok = Events.subscribe("ticket.*.pr.merged")
    schedule_sweep(opts)
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

  def handle_info(:sweep_closed, opts) do
    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> lift_closed(opts) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.warning("quarantine closed-ticket sweep failed to start reason=#{inspect(reason)}")
    end

    schedule_sweep(opts)
    {:noreply, opts}
  end

  def handle_info(_event, opts), do: {:noreply, opts}

  defp schedule_sweep(opts) do
    case Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms) do
      interval when is_integer(interval) and interval > 0 -> Process.send_after(self(), :sweep_closed, interval)
      _disabled -> :ok
    end
  end

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
    result = Enum.reduce(@list_paths, :ok, fn path, acc -> if acc == :ok, do: fetch_list(ticket, path, opts), else: acc end)
    if result == :ok, do: :ok, else: release_claim(claim, opts, result)
  end

  defp release_claim(claim, opts, result) do
    case Journal.release_flake(claim, opts) do
      :ok -> result
      {:error, reason} -> {:error, {:quarantine_lift_claim_release_failed, reason}}
    end
  end

  defp fetch_list(ticket, path, opts) do
    with {:ok, context} <- context(path, opts),
         {:ok, contents, file_sha} <- get_contents(context, opts),
         {:ok, updated} <- remove_ticket(contents, ticket),
         :ok <- open_removal_pr(context, file_sha, updated, ticket, opts) do
      :ok
    else
      {:error, :ticket_not_quarantined} -> :ok
      # The browser list exists only once a spec has been quarantined.
      {:error, {:github, _, %{status: 404}}} -> :ok
      {:error, _} = error -> error
    end
  end

  defp context(path, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      {:ok, %{path: path, owner: owner, repo: repo, token: token, base: Keyword.get_lazy(opts, :base_branch, &TrackerSettings.base_branch/0)}}
    end
  end

  defp get_contents(context, opts) do
    url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/contents/#{context.path}?ref=#{context.base}"

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
      [_module, _name, ^target, _expires] -> true
      _ -> false
    end
  end

  defp open_removal_pr(context, file_sha, contents, ticket, opts) do
    suffix = if context.path == hd(@list_paths), do: "", else: "-browser"
    branch = "aiur/quarantine-lift-#{ticket}-#{context.base}#{suffix}"

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
    url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/contents/#{context.path}"
    body = %{"message" => "Lift fixed test quarantine", "content" => Base.encode64(contents), "branch" => branch, "sha" => sha}
    expect_write(request(opts).(%{method: :put, url: url, token: context.token, caller: "quarantine_lift_file", body: body}), [200])
  end

  defp create_pr(context, branch, ticket, opts) do
    url = "#{Transport.base_url()}/repos/#{context.owner}/#{context.repo}/pulls"

    body = %{
      "title" => "Lift fixed test quarantine",
      "body" => "Removes quarantine entries tracked by ##{ticket} #{Keyword.get(opts, :lift_reason, "after the fix merged")}.",
      "head" => branch,
      "base" => context.base
    }

    expect_write(request(opts).(%{method: :post, url: url, token: context.token, caller: "quarantine_lift_pr", body: body}), [200, 201])
  end

  defp expect_write({:ok, %{status: status} = response}, accepted) do
    if status in accepted, do: :ok, else: {:error, Errors.github_status_error(response)}
  end

  defp expect_write({:error, _} = error, _accepted), do: error
  defp request(opts), do: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
end
