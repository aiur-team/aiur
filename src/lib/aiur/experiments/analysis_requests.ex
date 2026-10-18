defmodule Aiur.Experiments.AnalysisRequests do
  @moduledoc false

  alias Aiur.Experiments.{Journal, Paths, Persistence, Reader, ReportRecords, Schema}

  @spec submitted(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def submitted(id, mode, record) do
    with {:ok, rows} <- history(id) do
      request = Enum.find(latest(rows), &(&1["state"] == "open" and &1["mode"] == mode))
      fulfill_submitted(id, request, mode, record)
    end
  end

  defp fulfill_submitted(_id, nil, _mode, _record), do: :ok

  defp fulfill_submitted(id, request, "spec", record) do
    submission = %{"mode" => "spec", "version" => length(record["amendments"] || []) + 1}
    with {:ok, _request} <- fulfill(id, request["request_id"], submission), do: :ok
  end

  defp fulfill_submitted(id, request, "report", record) do
    submission = %{"mode" => "report", "version" => record["header"]["report_version"], "analysis_type" => record["header"]["analysis_type"]}

    case fulfill(id, request["request_id"], submission) do
      {:ok, _request} -> :ok
      {:error, :submission_mismatch} -> :ok
      error -> error
    end
  end

  @spec default_mode(String.t()) :: {:ok, String.t()} | {:error, term()}
  def default_mode(id) do
    with {:ok, _spec, _read_only?} <- Reader.spec(id), {:ok, records} <- ReportRecords.read(id) do
      {:ok, if(records["preregistration"], do: "report", else: "spec")}
    end
  end

  @spec dispatch(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch(id, request_id, fields) do
    allowed = ~w(first_creating_ms dispatch_requested ticket_status dispatch_attempts next_attempt_ms routing_promoted dispatched_analysis_type promotion_attempts promotion_next_attempt_ms)

    if Enum.all?(Map.keys(fields), &(&1 in allowed)) do
      update(id, request_id, &dispatch_fields(&1, fields))
    else
      {:error, :invalid_dispatch_update}
    end
  end

  defp dispatch_fields(%{"state" => "open"} = request, fields) do
    fields = Map.merge(fields, Map.take(request, ["first_creating_ms"]))
    {:ok, Map.merge(request, fields)}
  end

  defp dispatch_fields(_request, _fields), do: {:error, :request_closed}

  # Mutations are called only by Store, keeping deduplication and appends serialized.
  @spec request(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(id, mode, opts) do
    with :ok <- writable(id),
         :ok <- validate(mode, opts),
         {:ok, rows} <- history(id) do
      requests = latest(rows)
      trigger = Keyword.get(opts, :trigger)
      previous = if trigger, do: Enum.find(requests, &(trigger in &1["triggers"]))
      open = Enum.find(requests, &(&1["state"] == "open"))

      cond do
        previous -> {:ok, previous}
        open -> supersede(id, open, mode, opts)
        true -> append(id, new(id, mode, opts))
      end
    end
  end

  @spec history(String.t()) :: {:ok, [map()]} | {:error, term()}
  def history(id) do
    if Paths.valid_id?(id) do
      with {:ok, rows} <- Journal.read(Paths.file(id, "requests.ndjson")), do: validate_history(rows)
    else
      {:error, :not_found}
    end
  end

  defp validate_history(rows), do: if(Enum.all?(rows, &valid_record?/1), do: {:ok, rows}, else: {:error, :invalid_analysis_journal})

  defp valid_record?(row) do
    Enum.all?(~w(request_id experiment_id nonce), &(is_binary(row[&1]) and row[&1] != "")) and
      row["mode"] in ~w(spec report) and row["state"] in ~w(open fulfilled cancelled failed) and
      valid_revision?(row) and valid_analysis_type?(row)
  end

  defp valid_revision?(row), do: is_integer(row["revision"]) and row["revision"] > 0 and is_list(row["triggers"]) and Enum.all?(row["triggers"], &is_binary/1)
  defp valid_analysis_type?(row), do: row["mode"] == "spec" or row["analysis_type"] in ~w(interim confirmatory)

  @spec latest([map()]) :: [map()]
  def latest(rows), do: rows |> Enum.reduce(%{}, &Map.put(&2, &1["request_id"], &1)) |> Map.values() |> Enum.sort_by(& &1["request_id"])

  @spec attach_ticket(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def attach_ticket(id, request_id, %{"number" => number, "url" => url} = ticket) when is_integer(number) and number > 0 and is_binary(url) do
    update(id, request_id, fn request ->
      cond do
        request["state"] != "open" -> {:error, :request_closed}
        request["ticket"] == ticket -> {:ok, request}
        request["ticket"] -> {:error, :ticket_exists}
        true -> {:ok, Map.put(request, "ticket", ticket)}
      end
    end)
  end

  def attach_ticket(_id, _request_id, _ticket), do: {:error, :invalid_ticket}

  @spec fulfill(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def fulfill(id, request_id, submission) do
    update(id, request_id, fn request ->
      cond do
        request["state"] == "fulfilled" and request["submission"] == submission -> {:ok, request}
        request["state"] != "open" -> {:error, :request_closed}
        not matching_submission?(request, submission) -> {:error, :submission_mismatch}
        true -> {:ok, Map.merge(request, %{"state" => "fulfilled", "submission" => submission})}
      end
    end)
  end

  @spec cancel(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(id, request_id, reason) when is_binary(reason) and reason != "" do
    update(id, request_id, fn request ->
      if request["state"] == "open", do: {:ok, Map.merge(request, %{"state" => "cancelled", "cancel_reason" => reason})}, else: {:error, :request_closed}
    end)
  end

  def cancel(_id, _request_id, _reason), do: {:error, :invalid_reason}

  @spec fail(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fail(id, request_id, reason) when is_binary(reason) and reason != "" do
    update(id, request_id, fn request ->
      if request["state"] == "open", do: {:ok, Map.merge(request, %{"state" => "failed", "failure_reason" => reason})}, else: {:error, :request_closed}
    end)
  end

  def fail(_id, _request_id, _reason), do: {:error, :invalid_reason}

  defp matching_submission?(request, %{"mode" => mode, "version" => version} = submission) when is_integer(version) and version > 0 do
    mode == request["mode"] and (mode == "spec" or submission["analysis_type"] == request["analysis_type"])
  end

  defp matching_submission?(_request, _submission), do: false

  defp update(id, request_id, change) do
    with :ok <- writable(id),
         {:ok, rows} <- history(id),
         request when is_map(request) <- Enum.find(latest(rows), &(&1["request_id"] == request_id)),
         {:ok, updated} <- change.(request) do
      if updated == request, do: {:ok, request}, else: append(id, revise(updated))
    else
      nil -> {:error, :request_not_found}
      error -> error
    end
  end

  defp supersede(id, request, mode, opts) do
    stronger? = rank(mode, opts[:analysis_type] || "interim") > rank(request["mode"], request["analysis_type"])
    trigger = opts[:trigger]
    triggers = if trigger, do: Enum.uniq(request["triggers"] ++ [trigger]), else: request["triggers"]
    updated = Map.put(request, "triggers", triggers)

    updated =
      if stronger? do
        Map.merge(updated, %{"mode" => mode, "analysis_type" => analysis_type(mode, opts), "superseded_reason" => opts[:reason] || "manual"})
      else
        updated
      end

    if updated == request, do: {:ok, request}, else: append(id, revise(updated))
  end

  defp rank("spec", _type), do: 0
  defp rank("report", "interim"), do: 1
  defp rank("report", "confirmatory"), do: 2

  defp new(id, mode, opts) do
    at = now()

    %{
      "schema_version" => Schema.current(),
      "request_id" => "req-" <> random(),
      "experiment_id" => id,
      "nonce" => random(),
      "mode" => mode,
      "analysis_type" => analysis_type(mode, opts),
      "reason" => opts[:reason] || "manual",
      "requested_by" => opts[:requested_by] || "operator",
      "ticket" => nil,
      "state" => "open",
      "triggers" => List.wrap(opts[:trigger]),
      "revision" => 1,
      "at" => at,
      "requested_at" => at
    }
  end

  defp validate(mode, opts) do
    valid? =
      mode in ~w(spec report) and opts[:analysis_type] in [nil, "interim", "confirmatory"] and
        Enum.all?([:reason, :requested_by, :trigger], &(is_nil(opts[&1]) or (is_binary(opts[&1]) and opts[&1] != "")))

    if valid?, do: :ok, else: {:error, :invalid_analysis_request}
  end

  defp writable(id) do
    with {:ok, _spec, false} <- Reader.spec(id), :ok <- Persistence.writable(id) do
      Journal.writable(Paths.file(id, "requests.ndjson"))
    else
      {:ok, _spec, true} -> {:error, :store_read_only}
      error -> error
    end
  end

  defp append(id, request) do
    with :ok <- Aiur.Journal.prepare(Paths.experiment(id), Paths.file(id, "requests.ndjson")), :ok <- Journal.append(Paths.file(id, "requests.ndjson"), request), do: {:ok, request}
  end

  defp analysis_type("spec", _opts), do: nil
  defp analysis_type("report", opts), do: opts[:analysis_type] || "interim"
  defp revise(request), do: request |> Map.update!("revision", &(&1 + 1)) |> Map.put("at", now())
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp random, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
