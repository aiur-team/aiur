defmodule Aiur.Experiments.ReportRecords do
  @moduledoc false
  alias Aiur.Experiments.{Paths, Persistence, Preregistration, Reader}

  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(id) do
    case Reader.json(Paths.file(id, "report/contract.json")) do
      {:error, :not_found} -> {:ok, %{"first_results_read_at" => nil, "preregistration" => nil, "reports" => []}}
      result -> result
    end
  end

  @spec preregister(String.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def preregister(id, attrs, now) do
    with :ok <- writable(id),
         {:ok, records} <- read(id),
         {:ok, registration} <- Preregistration.prepare(attrs, records["preregistration"], records["first_results_read_at"], now),
         true <- registration["experiment_id"] == id and attrs["experiment_id"] == id,
         :ok <- write(id, Map.put(records, "preregistration", registration)) do
      :ok = Persistence.broadcast(id)
      {:ok, registration}
    else
      false -> {:error, [%{path: "experiment_id", message: "does not match experiment"}]}
      error -> error
    end
  end

  @spec record_results_read(String.t(), DateTime.t()) :: :ok | {:error, term()}
  def record_results_read(id, now) do
    with :ok <- writable(id), {:ok, records} <- read(id) do
      if records["first_results_read_at"], do: :ok, else: write(id, Map.put(records, "first_results_read_at", DateTime.to_iso8601(now)))
    end
  end

  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(id, records), do: Persistence.write_json(Paths.file(id, "report/contract.json"), records)

  @spec writable(String.t()) :: :ok | {:error, term()}
  def writable(id) do
    case Reader.spec(id) do
      {:ok, _spec, false} -> Persistence.writable(id)
      {:ok, _spec, true} -> {:error, :store_read_only}
      error -> error
    end
  end
end
