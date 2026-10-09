defmodule Aiur.Events.BranchRewriteClassifier do
  @moduledoc "Subscription-gated asynchronous classification of ticket branch rewrites."

  require Logger

  alias Aiur.Events.{BranchRefStore, Exchange}
  alias Aiur.GitHub.Transport

  @spec maybe_publish(String.t(), map(), function(), keyword()) :: term()
  def maybe_publish(id, payload, publisher, opts) do
    topic = "ticket.#{id}.branch.force-push"

    if payload.previous_sha && subscribed?(topic) do
      start_compare(id, topic, payload, publisher, opts)
    end
  catch
    :exit, reason -> note_error(reason, payload)
  end

  defp start_compare(id, topic, payload, publisher, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor)

    case Task.Supervisor.start_child(supervisor, fn -> classify_and_publish(id, topic, payload, publisher, opts) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> note_error(reason, payload)
    end
  end

  # Fleet observers bind ticket.*.#; only dependent stores justify a compare.
  defp subscribed?(topic) do
    Aiur.Events.SubscriptionStoreRegistry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [:"$2"]}])
    |> Enum.any?(fn pid -> Enum.any?(Exchange.bindings_for(pid), &Exchange.matches?(&1, topic)) end)
  rescue
    ArgumentError -> false
  end

  defp classify_and_publish(id, topic, payload, publisher, opts) do
    case compare(payload, opts) do
      {:ok, %{"status" => status}} when status in ["ahead", "identical"] -> :ok
      {:ok, %{"status" => status}} when status in ["behind", "diverged"] -> publish(id, topic, payload, publisher, status, false)
      {:error, {:github, :http, %{status: 404}}} -> publish(id, topic, payload, publisher, "unknown", true)
      other -> note_error(other, payload)
    end
  rescue
    error -> note_error(error, payload)
  catch
    kind, reason -> note_error({kind, reason}, payload)
  end

  defp compare(payload, opts) do
    with {:ok, token} <- Transport.require_token(opts) do
      previous = URI.encode(payload.previous_sha, &URI.char_unreserved?/1)
      sha = URI.encode(payload.sha, &URI.char_unreserved?/1)
      url = "#{Transport.base_url()}/repos/#{payload.repo}/compare/#{previous}...#{sha}?per_page=1"
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      Transport.fetch_json_map(request_fun, token, url, caller: "ticket_branch_rewrite")
    end
  end

  defp publish(id, topic, payload, publisher, status, missing?) do
    latest = BranchRefStore.latest(id)
    superseded? = latest != nil and latest != %{ref: payload.ref, sha: payload.sha}
    event = Map.merge(payload, %{compare_status: status, previous_missing: missing?, superseded: superseded?})
    Logger.info("aiur_perf ls_remote_ticker phase=publish_force_push ref=#{payload.ref} sha=#{payload.sha} topic=#{topic}")
    publisher.(topic, event, issue_number: id, dedup_key: {:branch_force_push, payload.repo, payload.ref, payload.sha})
  end

  defp note_error(reason, payload) do
    Logger.debug("Ticket branch rewrite compare unavailable ref=#{payload.ref} previous_sha=#{payload.previous_sha} sha=#{payload.sha}: #{inspect(reason)}")
    :telemetry.execute([:aiur, :events, :branch_rewrite, :error], %{count: 1}, %{reason: reason, ref: payload.ref, sha: payload.sha, previous_sha: payload.previous_sha, repo: payload.repo})
  end
end
