defmodule AiurWeb.OperatorControlCenter.Analytics.RuntimeCaps do
  @moduledoc false

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.CapacityBinding
  alias AiurWeb.OperatorControlCenter.Analytics.LiveConcurrency

  @default_buckets 180
  @default_host_mem_bytes 32 * 1024 * 1024 * 1024

  @spec cap_label(map()) :: String.t()
  def cap_label(%{} = model) do
    head =
      case model do
        %{cap_available?: false} -> "unknown cap"
        %{cap: cap} -> "#{cap} cap"
      end

    head <> annotations(model)
  end

  defp annotations(model) do
    case Enum.reject([binding_note(model), ceiling_note(model), age_note(model)], &is_nil/1) do
      [] -> ""
      notes -> " (" <> Enum.join(notes, ", ") <> ")"
    end
  end

  defp binding_note(model) do
    case Map.get(model, :cap_binding) do
      binding when is_binary(binding) -> "binding: #{binding}"
      _absent -> nil
    end
  end

  # The configured value is always shown when the effective cap is unknown: it
  # is the only ceiling left to report, and its absence is what would make the
  # "unknown" unactionable.
  defp ceiling_note(%{cap_available?: false, configured_cap: configured}) when is_integer(configured),
    do: "configured #{configured}"

  defp ceiling_note(%{cap_available?: false}), do: nil

  defp ceiling_note(%{cap: cap} = model) do
    session = Map.get(model, :session_cap, cap)
    configured = Map.get(model, :configured_cap, cap)

    [{"session", session}, {"configured", configured}]
    |> Enum.filter(fn {_name, value} -> is_integer(value) and value != cap end)
    # One number, one name. When the session ceiling and the configured value
    # coincide, "configured" is the one an operator can go and change.
    |> Enum.reverse()
    |> Enum.uniq_by(fn {_name, value} -> value end)
    |> Enum.reverse()
    |> case do
      [] -> nil
      pairs -> Enum.map_join(pairs, ", ", fn {name, value} -> "#{name} #{value}" end)
    end
  end

  # `cap_staleness` is populated only for a degraded read, so its mere presence
  # is the signal. A current reading carries no note at all.
  defp age_note(model) do
    case Map.get(model, :cap_staleness) do
      {:retained, age_ms} -> "retained, daemon unreachable#{age_suffix(age_ms)}"
      {:stale, age_ms} -> "stale#{age_suffix(age_ms)}"
      _absent -> nil
    end
  end

  # Under a second the age says nothing an operator can act on, and printing
  # "0s old" beside "stale" reads as a contradiction rather than a warning.
  defp age_suffix(age_ms) when is_integer(age_ms) and age_ms >= 1_000, do: ", #{humanize_age(age_ms)} old"
  defp age_suffix(_age_ms), do: ""

  defp humanize_age(age_ms) do
    seconds = div(age_ms, 1_000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      true -> "#{Float.round(seconds / 3_600, 1)}h"
    end
  end

  @spec runtime_opts(keyword()) :: keyword()
  def runtime_opts(opts) do
    opts
    |> Keyword.merge(runtime_facts(opts), fn _key, given, _derived -> given end)
    |> Keyword.put_new(:cores, System.schedulers_online())
    |> Keyword.put_new(:host_mem_bytes, host_mem_bytes())
    |> Keyword.put_new(:buckets, @default_buckets)
  end

  defp runtime_facts(opts) do
    if Keyword.has_key?(opts, :cap) do
      []
    else
      reading = capacity_reading(opts)
      caps = cap_facts(reading)

      if Keyword.get(opts, :session, :all) == :current and not Keyword.has_key?(opts, :tickets) do
        caps ++ LiveConcurrency.snapshot_opts(reading)
      else
        caps
      end
    end
  end

  # Every ceiling the daemon reports travels together. Reading only `effective`
  # is what let the page and `aiur status` disagree: the CLI prints the session
  # ceiling, so a page that never mentions it cannot be reconciled with the CLI.
  defp cap_facts({kind, %{capacity: %{effective: effective} = capacity} = snapshot, freshness})
       when kind in [:current, :stale] and is_integer(effective) and effective > 0 do
    staleness = if kind == :stale, do: staleness(freshness), else: nil
    polling = snapshot_polling(snapshot)

    [
      cap: effective,
      cap_available?: true,
      session_cap: positive_or(Map.get(capacity, :max), effective),
      configured_cap: positive_or(Map.get(capacity, :configured), effective),
      # The polling report travels from the same snapshot as the capacity, so
      # the page cannot blame "ticket supply" in a state where `aiur status`
      # says "idle backoff" or "has not polled yet" (#2138, #2640). Two
      # surfaces, one classifier, one answer.
      cap_binding: CapacityBinding.short_label(CapacityBinding.binding(capacity, polling)),
      cap_staleness: staleness
    ]
  end

  # No effective fact means no ceiling is known. The local config file is NOT
  # substituted here: this process may not run on the daemon's host, so its
  # `.aiur/config` is a different fact wearing the same name, and reporting it
  # as "configured" would put a confident number under an admitted unknown.
  defp cap_facts(_reading) do
    [cap: nil, cap_available?: false, configured_cap: nil, session_cap: nil, cap_binding: nil, cap_staleness: nil]
  end

  defp positive_or(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_or(_value, fallback), do: fallback

  # A retained-but-aged snapshot is still rendered — `SnapshotStore` returns it
  # precisely so callers can show last-known-good data — but its age comes back
  # with it and is never discarded. Dropping `freshness` here is what turned an
  # hours-old cap into an unmarked current one.
  defp capacity_reading(opts) do
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
    timeout = Keyword.get(opts, :snapshot_timeout_ms, 15_000)
    snapshot_fun = Keyword.get(opts, :dashboard_snapshot_fun, &Orchestrator.dashboard_snapshot/2)
    snapshot_fun.(orchestrator, timeout)
  end

  defp snapshot_polling(%{polling: %{} = polling}), do: polling
  defp snapshot_polling(_snapshot), do: %{}

  # The two degraded states must not collapse into one message. An aged reading
  # from a live daemon is a cap that may have moved since; a retained reading
  # from a daemon that is no longer there is a cap nobody is enforcing.
  defp staleness(%{reason: :orchestrator_unavailable} = freshness),
    do: {:retained, freshness_age_ms(freshness)}

  defp staleness(freshness), do: {:stale, freshness_age_ms(freshness)}

  defp freshness_age_ms(%{age_ms: age_ms}) when is_integer(age_ms) and age_ms >= 0, do: age_ms
  defp freshness_age_ms(_freshness), do: 0

  defp host_mem_bytes do
    case File.read("/proc/meminfo") do
      {:ok, content} -> meminfo_total(content)
      _ -> @default_host_mem_bytes
    end
  rescue
    _ -> @default_host_mem_bytes
  end

  defp meminfo_total(content) do
    case Regex.run(~r/MemTotal:\s+(\d+)\s*kB/, content) do
      [_, kb] -> String.to_integer(kb) * 1024
      _ -> @default_host_mem_bytes
    end
  end
end
