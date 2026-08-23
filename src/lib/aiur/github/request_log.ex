defmodule Aiur.GitHub.RequestLog do
  @moduledoc """
  Durable per-request TSV record of every GitHub request routed through the
  `Aiur.GitHub.Quota` chokepoint.

  `Quota` keeps a rolling-hour, in-memory attribution that answers *how much*
  each caller spent; nothing on disk answered *which* requests were made in a
  closed window. This module appends one TSV row per observed request at the
  `Quota` chokepoint — the single place every `Transport` response flows
  through — so "what spent the most this hour" is one `awk` over a file, with
  no paired-sample reconciliation and no subagent.

  ## What is recorded, and what is not

  A row is written for every request that reaches `Quota.observe/3` — i.e.
  every request that actually went to the network. A shared-state `ReadCache`
  hit is served without a network request and never reaches `Quota`, so it
  leaves no row; its cost is zero, so its absence cannot skew a spend query.
  The `/rate_limit` probe is exempt (`Quota.attribute_request/4` skips it too),
  so the file is spend-bearing traffic only.

  The columns are, in order:

  `timestamp, identity, pool, route shape, caller, cache disposition, status
  code, billable, points`

  * `timestamp` — unix seconds (UTC) of the observation.
  * `identity` — the request's stable one-way credential fingerprint
    (`request[:credential_key]`, set by `CredentialSelector`), never the token;
    `anonymous` for a tokenless read.
  * `pool` — `core`, `graphql`, or `core:anonymous`, derived exactly as `Quota`
    does.
  * `route shape` — `RouteShape.log_shape/1`: a **closed-vocabulary constant**,
    never a URL byte. This is the column that makes the log safe to contain
    URLs from a credentialed client: a query string can carry a token, and a
    constant cannot carry it onward. See `Aiur.GitHub.RouteShape`.
  * `caller` — `GraphQLCost.derive/1`, the call site, matching the in-memory
    ranking.
  * `cache disposition` — `miss` when the read cache classified the request as
    cacheable but did not hold it; `refused:<reason>` when the policy declined
    it (`refused:write`, `refused:unsafe_kind`, `refused:unclassified`, ...). A
    hit is never recorded because a hit never reaches `Quota`.
  * `status code` — the HTTP status, or empty when no response arrived.
  * `billable` — `1` iff GitHub billed the request (a real non-`304` status);
    `0` for `304` and for requests that never got a response. This is the
    `billable = 1` filter the reconciliation criterion sums over (#2357).
  * `points` — what the call cost its pool: reported GraphQL points from
    `rateLimit { cost }`, `1` (assumed) when the query did not ask, `1` per
    core request, `0` for a `304`. Mirrors `Quota.request_cost/3` so the log
    and the in-memory ranking cannot disagree.

  The cost/pool/billable derivations below deliberately mirror `Aiur.GitHub.Quota`
  (which remains the canonical source of attribution semantics); the two must
  agree or the durable log and the live ranking would tell different stories.

  ## Where it is written

  Into the boot's session directory — `Aiur.Config.Paths.log_root_dir()`,
  i.e. `~/.aiur/logs/<session-id>/log/github-requests.tsv` (or the configured
  `--logs-root`/`AIUR_LOGS_ROOT`) — which the session lifecycle already
  governs. It is deliberately **not** `~/.aiur/repo/<slug>/github-quota/`,
  which no retention policy covers and which would grow without bound. Measured
  volume is ~6,500 rows/hr ≈ 1 MB/hr, so session retention bounds the file.

  ## Writing

  The `Quota` GenServer holds the log's io_device, opened once at boot in
  `:delayed_write` and written through `append_io/3`, so an observe never pays
  an open/close/stat on the message loop that gates the fleet's GitHub access.
  `append/4` (path-based) is kept for direct callers and tests. All writes are
  best-effort and fail open: a logging failure never refuses or distorts a
  GitHub request, and `Quota` disables the log rather than retrying a broken
  io_device on every request.
  """

  alias Aiur.GitHub.{GraphQLCost, RouteShape}
  alias Aiur.GitHub.ReadCache.Policy

  @file_name "github-requests.tsv"
  @delayed_write_bytes 65_536
  @delayed_write_ms 1_000

  @doc "The name of the request-log file under the session log directory."
  @spec file_name() :: String.t()
  def file_name, do: @file_name

  @doc """
  The log path explicitly configured for this call, or `nil` when the caller
  did not set one (which includes an explicit `path: nil`, meaning the log is
  disabled for this caller).

  This never resolves the run's default — that happens once at boot in
  `Quota.init`, which keeps the hot path free of a per-request config read.
  """
  @spec log_path(keyword()) :: String.t() | nil
  def log_path(opts \\ []) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) and path != "" -> path
      _explicitly_disabled -> nil
    end
  end

  @doc false
  # The run's default path: the boot's session log directory, resolved once at
  # `Quota.init`. The test env never writes into the session log root — tests
  # that want a request log pass `path:` explicitly.
  @spec default_path() :: String.t() | nil
  def default_path do
    if Application.get_env(:aiur, :env) == :test do
      nil
    else
      Path.join(Aiur.Config.Paths.log_root_dir(), @file_name)
    end
  end

  @doc false
  # Opens the run's io_device in `:delayed_write`, so `Quota` can append without
  # an open/close/stat per request. `nil` disables the log.
  @spec open_writer(String.t() | nil) :: :file.io_device() | nil
  def open_writer(path) when is_binary(path) and path != "" do
    _ = File.mkdir_p(Path.dirname(path))

    case :file.open(path, [:append, :binary, {:delayed_write, @delayed_write_bytes, @delayed_write_ms}]) do
      {:ok, io} -> io
      {:error, _reason} -> nil
    end
  rescue
    _unavailable -> nil
  end

  def open_writer(_path), do: nil

  @doc false
  # Appends one row through an io_device opened by `open_writer/1`.
  @spec append_io(:file.io_device(), map(), {:ok, map()} | {:error, term()}, DateTime.t()) ::
          :ok | {:error, term()}
  def append_io(io, request, result, now), do: :file.write(io, [row(request, result, now), "\n"])

  @doc false
  # Forces the `:delayed_write` buffer out so a caller can read its own write
  # deterministically (the request-log mutation test does exactly this).
  @spec sync(:file.io_device() | nil) :: :ok | {:error, term()}
  def sync(nil), do: :ok
  def sync(io), do: :file.sync(io)

  @doc false
  @spec close(:file.io_device() | nil) :: :ok
  def close(nil), do: :ok
  def close(io), do: :file.close(io)

  @doc """
  Appends one row to `path`, creating the directory as needed.

  Path-based, for direct callers and tests; the daemon path is the held
  io_device (`append_io/4`) so it never opens the file per request.
  """
  @spec append(map(), {:ok, map()} | {:error, term()}, DateTime.t(), keyword()) :: :ok
  def append(request, result, now, opts \\ []) do
    case log_path(opts) do
      path when is_binary(path) and path != "" ->
        :ok = File.mkdir_p(Path.dirname(path))
        File.write(path, [row(request, result, now), "\n"], [:append])
        :ok

      _unconfigured ->
        :ok
    end
  rescue
    _unavailable -> :ok
  end

  # -- row derivation ---------------------------------------------------------

  defp row(request, result, now) do
    {status, response} = attribution_response(result)
    resource = request_resource(request)

    [
      Integer.to_string(DateTime.to_unix(now)),
      identity(request),
      resource,
      RouteShape.log_shape(request),
      GraphQLCost.derive(request),
      cache_disposition(request),
      status_cell(status),
      Integer.to_string(billable(status)),
      Integer.to_string(request_cost(resource, status, response))
    ]
    |> Enum.join("\t")
  end

  defp attribution_response({:ok, response}) when is_map(response), do: {Map.get(response, :status), response}
  defp attribution_response(_result), do: {nil, %{}}

  # Every derivation below mirrors `Aiur.GitHub.Quota`, which remains the
  # canonical source of attribution semantics; the two must agree or the
  # durable log and the in-memory ranking would tell different stories.

  defp request_resource(%{anonymous: true}), do: "core:anonymous"

  defp request_resource(%{url: url}) when is_binary(url) do
    if URI.parse(url).path == "/graphql", do: "graphql", else: "core"
  end

  defp request_resource(_request), do: "core"

  defp request_cost(_resource, 304, _response), do: 0

  defp request_cost("graphql", _status, response) do
    case GraphQLCost.reported(response) do
      %{cost: cost} when is_integer(cost) and cost >= 0 -> cost
      _unreported -> 1
    end
  end

  defp request_cost(_resource, _status, _response), do: 1

  # `billable` is the reconciliation filter: GitHub billed a real non-`304`
  # status. A `304` is served from GitHub's cache and costs nothing, and a
  # request that never got a response billed nothing either (#2353).
  defp billable(status), do: if(is_integer(status) and status != 304, do: 1, else: 0)

  defp status_cell(status) when is_integer(status), do: Integer.to_string(status)
  defp status_cell(_no_status), do: ""

  # The stable one-way credential fingerprint the selector stamped on the
  # request — never the token, and never a credential-controlled byte: the
  # value is a sha256-derived key or one of two known constants.
  defp identity(request) do
    cond do
      Map.get(request, :anonymous) == true -> "anonymous"
      true -> Map.get(request, :credential_key, "")
    end
  end

  # The disposition names why the request reached the network: `miss` when the
  # policy would have served it from cache but held nothing, otherwise the
  # refusal reason. `Policy.classify`'s `{:no_cache, reason}` reason is always
  # an atom today; if a future shape-classifying policy (#2352) widens the
  # reason to a `{:unclassified, shape}` tuple, the compiler's type checking
  # flags `Atom.to_string/1` here and the disposition must be widened with it.
  defp cache_disposition(request) do
    case Policy.classify(request) do
      {:cache, _class, _ttl} -> "miss"
      {:no_cache, reason} -> "refused:" <> Atom.to_string(reason)
      _other -> "unknown"
    end
  end
end
