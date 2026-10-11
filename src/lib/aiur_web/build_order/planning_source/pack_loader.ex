defmodule AiurWeb.BuildOrder.PlanningSource.PackLoader do
  @moduledoc "Pack discovery, loading, duplicate reconciliation and pack-derived identities for the planning source."

  require Logger

  alias Aiur.BuildOrder.PackPaths
  alias Aiur.GitHub.Config
  alias Aiur.TrackerIdentity

  @default_root_number_base 100_000
  @default_root_number_range 800_000_000
  @pack_source_precedence %{workspace: 0, state: 1, override: 2, configured: 3, explicit: 4}
  @pack_source_precedence_description "workspace > state > environment > configured > explicit"

  @doc false
  @spec load_packs(keyword()) :: [map()]
  def load_packs(options \\ []) do
    include_drafts? = Keyword.get(options, :include_drafts?, false)

    pack_paths()
    |> Enum.map(&load_pack(&1, include_drafts?))
    |> Enum.flat_map(fn
      {:ok, pack} -> [pack]
      {:error, _reason} -> []
    end)
    |> filter_for_tracked_repository()
    |> reconcile_duplicate_packs()
    |> Enum.sort(&pack_before?/2)
    |> assign_default_root_numbers()
    |> assign_default_icons()
  end

  # A single explicit pack is a test/demo override. Every normal catalog source,
  # including the environment directory override, remains scoped to the repo this
  # daemon is tracking.
  defp filter_for_tracked_repository(packs) do
    if Application.get_env(:aiur, :build_order_planning_pack) do
      packs
    else
      Enum.filter(packs, &tracked_repository?/1)
    end
  end

  defp tracked_repository?(%{repository: repository}), do: same_repository?(repository, configured_repository_tuple())
  defp tracked_repository?(_pack), do: false

  defp pack_paths do
    case Application.get_env(:aiur, :build_order_planning_pack) do
      nil ->
        case Application.get_env(:aiur, :build_order_planning_packs) do
          paths when is_list(paths) -> Enum.map(paths, &{:configured, &1})
          _missing -> discovered_packs()
        end

      path ->
        [{:explicit, path}]
    end
  end

  # Runtime packs are re-discovered through the same canonical source list the
  # status poller uses, including publisher-created workspace mirrors.
  defp discovered_packs do
    PackPaths.discovered_sources()
  end

  @doc false
  @spec catalog_repository([map()]) :: {String.t(), String.t()}
  def catalog_repository([pack | _packs]), do: pack.repository
  def catalog_repository([]), do: configured_repository_tuple()

  defp configured_repository_tuple do
    case String.split(to_string(configured_repository() || ""), "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {owner, repo}
      _other -> {"unknown", "unknown"}
    end
  end

  @doc false
  @spec catalog_search_paths() :: [Path.t()]
  def catalog_search_paths do
    case Application.get_env(:aiur, :build_order_planning_pack) do
      nil ->
        case Application.get_env(:aiur, :build_order_planning_packs) do
          paths when is_list(paths) -> Enum.map(paths, &Path.dirname(absolute_path(&1)))
          _missing -> PackPaths.discovery_directories()
        end

      path ->
        [Path.dirname(absolute_path(path))]
    end
  end

  defp load_pack({source, path}, include_drafts?) do
    absolute = absolute_path(path)

    with {:ok, body} <- File.read(absolute),
         {:ok, json} <- Jason.decode(body),
         :ok <- pack_object(json),
         {:repository, {:ok, repository}} <- {:repository, repository(json)},
         {:tickets, {:ok, tickets}} <- {:tickets, tickets(Map.get(json, "tickets", []), Path.dirname(absolute), include_drafts?)} do
      raw_build_order_id = Map.get(json, "build_order_id")
      build_order_id = normalized_build_order_id(raw_build_order_id)
      root_number = Map.get(json, "root_number") || get_in(json, ["github_root", "number"])
      status = status(absolute)
      declared_completed? = Map.get(json, "completed", false) == true

      pack =
        %{
          source: source,
          path: absolute,
          content_hash: :crypto.hash(:sha256, body),
          repository: repository,
          build_order_id: build_order_id,
          build_order_id_explicit?: is_binary(raw_build_order_id) and raw_build_order_id != "",
          title: Map.get(json, "title", "Planning build order"),
          icon: pack_icon(json),
          icon_explicit?: is_binary(Map.get(json, "icon")) and Map.get(json, "icon") != "",
          root_number: root_number || default_root_number(build_order_id),
          root_number_explicit?: is_integer(root_number),
          root_node_id: root_node_id(json, build_order_id),
          declared_completed?: declared_completed?,
          completed: declared_completed? or status_completed?(status),
          completed_at: status_completed_at(status),
          status: status,
          metadata: Map.take(json, ["workstreams", "phases", "external_gates"]),
          materialized?: Enum.any?(tickets, &is_integer(&1.number)),
          tickets: tickets
        }

      root_identity(pack)
      identifiers = Enum.map(tickets, &ticket_identity(pack, &1).identifier)

      if length(Enum.uniq(identifiers)) == length(identifiers),
        do: {:ok, pack},
        else: pack_error(absolute, :duplicate_member_identifier)
    else
      error -> pack_error(absolute, error)
    end
  rescue
    error -> pack_error(absolute_path(path), {:exception, error.__struct__, Exception.message(error)})
  end

  defp pack_object(json) when is_map(json), do: :ok
  defp pack_object(_json), do: {:error, :invalid_pack_object}

  defp pack_error(path, reason) do
    Logger.warning("build order catalog skipped pack #{path}: #{inspect(reason)}")
    {:error, reason}
  end

  # The publisher writes a workspace mirror while the repository state node
  # retains its canonical copy. Reconcile only mirrors of the same logical
  # build order before sorting so the URL router receives one root identity.
  # Source precedence is intentional and auditable in the warning: workspace,
  # state, environment, configured list, then the singular explicit test/demo
  # pack. Distinct build orders retain their entries even when root locators
  # collide, allowing RouteState to fail closed rather than hiding a pack.
  defp reconcile_duplicate_packs(packs) do
    packs
    |> Enum.sort_by(&pack_precedence/1)
    |> Enum.reduce([], fn pack, selected ->
      case Enum.find_index(selected, &same_catalog_pack?(&1, pack)) do
        nil ->
          [pack | selected]

        index ->
          chosen = Enum.at(selected, index)

          Logger.warning(
            "build order catalog discarded #{duplicate_kind(chosen, pack)} #{inspect(pack.build_order_id)} from #{pack.source} (#{pack.path}); " <>
              "source precedence #{@pack_source_precedence_description} selected #{chosen.source} (#{chosen.path})"
          )

          List.replace_at(selected, index, retain_state_projection(chosen, pack))
      end
    end)
    |> Enum.reverse()
  end

  defp pack_precedence(pack), do: {Map.get(@pack_source_precedence, pack.source, 99), pack.path}

  defp same_catalog_pack?(left, right) do
    same_repository?(left.repository, right.repository) and
      left.build_order_id_explicit? and right.build_order_id_explicit? and
      left.build_order_id == right.build_order_id
  end

  defp duplicate_kind(%{content_hash: hash}, %{content_hash: hash}), do: "identical mirror"
  defp duplicate_kind(_chosen, _pack), do: "divergent duplicate"

  # A workspace mirror determines the catalog definition, but the daemon writes
  # status.json only beside the repository-state manifest. Keep that projection
  # when the matching state pack loses definition precedence.
  defp retain_state_projection(chosen, %{source: :state, status: status}) do
    %{chosen | status: status, completed: chosen.declared_completed? or status_completed?(status), completed_at: status_completed_at(status)}
  end

  defp retain_state_projection(chosen, _discarded), do: chosen

  defp same_repository?({left_owner, left_repo}, {right_owner, right_repo}) do
    String.downcase(left_owner) == String.downcase(right_owner) and String.downcase(left_repo) == String.downcase(right_repo)
  end

  defp same_repository?(_left, _right), do: false

  defp normalized_build_order_id(build_order_id) when is_binary(build_order_id) and build_order_id != "", do: build_order_id
  defp normalized_build_order_id(_build_order_id), do: "planning"

  defp root_node_id(json, build_order_id), do: Map.get(json, "root_node_id") || get_in(json, ["github_root", "node_id"]) || "BO_#{build_order_id}"

  defp assign_default_root_numbers(packs) do
    {packs, _used_numbers} =
      Enum.map_reduce(packs, MapSet.new(), fn pack, used_numbers ->
        root_number =
          if pack.root_number_explicit? do
            pack.root_number
          else
            unique_default_root_number(pack.build_order_id, used_numbers)
          end

        {%{pack | root_number: root_number}, MapSet.put(used_numbers, root_number)}
      end)

    packs
  end

  defp default_root_number(build_order_id), do: @default_root_number_base + :erlang.phash2(build_order_id, @default_root_number_range)

  defp unique_default_root_number(build_order_id, used_numbers, probe \\ 0) do
    root_number = default_root_number({build_order_id, probe})

    if MapSet.member?(used_numbers, root_number) do
      unique_default_root_number(build_order_id, used_numbers, probe + 1)
    else
      root_number
    end
  end

  defp repository(json) do
    case String.split(to_string(Map.get(json, "repository", "")), "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, {owner, repo}}
      _other -> :error
    end
  end

  defp tickets(list, pack_dir, include_drafts?) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn attributes, {:ok, tickets} ->
      case ticket(attributes, pack_dir, include_drafts?) do
        {:ok, ticket} -> {:cont, {:ok, [ticket | tickets]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, tickets} -> {:ok, Enum.reverse(tickets)}
      :error -> :error
    end
  end

  defp tickets(_list, _pack_dir, _include_drafts?), do: :error

  defp ticket(%{"id" => id} = attributes, pack_dir, include_drafts?) when is_binary(id) and id != "" do
    with {:ok, number} <- ticket_number(attributes),
         document_path <- ticket_document_path(attributes),
         true <- safe_document_path?(document_path) do
      {:ok,
       %{
         id: id,
         title: Map.get(attributes, "title", id),
         lane: ticket_lane(attributes),
         phase: ticket_phase(attributes),
         complexity: ticket_complexity(attributes),
         number: number,
         node_id: ticket_node_id(attributes),
         depends_on: List.wrap(Map.get(attributes, "depends_on", [])),
         document_url: nil,
         document_path: document_path,
         draft_body: if(include_drafts? and is_nil(number), do: draft_body(document_path, pack_dir)),
         icon: Map.get(attributes, "icon")
       }}
    else
      _invalid -> :error
    end
  end

  defp ticket(_attributes, _pack_dir, _include_drafts?), do: :error

  defp ticket_document_path(attributes), do: Map.get(attributes, "doc") || Map.get(attributes, "document")

  defp ticket_lane(attributes), do: to_string(Map.get(attributes, "lane") || Map.get(attributes, "workstream") || "unassigned")

  defp ticket_phase(attributes), do: Map.get(attributes, "phase") || Map.get(attributes, "phase_hint") || 0

  defp ticket_complexity(attributes), do: Map.get(attributes, "complexity") || Map.get(attributes, "complexity_points")

  defp ticket_node_id(attributes), do: get_in(attributes, ["github", "node_id"])

  defp safe_document_path?(path) when is_binary(path) and byte_size(path) in 1..512 do
    Path.type(path) == :relative and
      String.starts_with?(path, "tickets/") and
      not Enum.member?(Path.split(path), "..")
  end

  defp safe_document_path?(_path), do: false

  @doc false
  @spec draft_body(term(), Path.t()) :: String.t() | nil
  def draft_body(path, pack_dir) when is_binary(path) do
    pack_dir = Path.expand(pack_dir)
    document = Path.expand(path, pack_dir)

    with {:ok, %{candidate: canonical}} <- Aiur.PathSafety.contained?(pack_dir, document),
         {:ok, body} when byte_size(body) in 1..64_000 <- File.read(canonical) do
      body
    else
      _missing_or_invalid -> nil
    end
  end

  def draft_body(_path, _pack_dir), do: nil

  defp status(path) do
    path
    |> PackPaths.status_path()
    |> File.read()
    |> case do
      {:ok, body} -> Jason.decode(body)
      _missing -> {:error, :missing}
    end
    |> case do
      {:ok, map} when is_map(map) -> map
      _invalid -> %{}
    end
  end

  defp status_completed?(%{"state" => state}) when state in ["completed", "COMPLETE", "complete"], do: true
  defp status_completed?(%{"completed" => true}), do: true
  defp status_completed?(_status), do: false

  defp status_completed_at(%{"completed_at" => value}) when is_binary(value), do: value
  defp status_completed_at(_status), do: nil

  @doc false
  @spec status_lifecycle(term(), term()) :: atom() | nil
  def status_lifecycle(%TrackerIdentity{identifier: identifier}, %{status: status}) do
    state =
      status
      |> status_members()
      |> Map.get(identifier)
      |> case do
        %{"lifecycle" => lifecycle} -> lifecycle
        %{"state" => value} -> value
        value when is_binary(value) -> value
        _missing -> nil
      end

    case state do
      value when value in ["completed", "COMPLETE", "complete"] -> :completed
      value when value in ["cancelled", "canceled", "CANCELLED", "CANCELED"] -> :cancelled
      value when value in ["open", "OPEN"] -> :open
      _unknown -> nil
    end
  end

  def status_lifecycle(_identity, _pack), do: nil

  defp status_members(%{"members" => members}) when is_map(members), do: members
  defp status_members(_status), do: %{}

  defp ticket_number(%{"ticket" => ticket}) when is_integer(ticket) and ticket > 0, do: {:ok, ticket}
  defp ticket_number(%{"ticket" => nil}), do: {:ok, nil}
  defp ticket_number(%{"github" => %{"number" => ticket}}) when is_integer(ticket) and ticket > 0, do: {:ok, ticket}
  defp ticket_number(_attributes), do: :error

  @default_icons ["bolt", "cube", "sparkles", "server-stack", "rectangle-group"]

  defp assign_default_icons(packs) do
    {packs, _used_icons} =
      Enum.map_reduce(packs, MapSet.new(), fn pack, used_icons ->
        if pack.icon_explicit? do
          {pack, MapSet.put(used_icons, pack.icon)}
        else
          icon = unique_default_icon(pack.build_order_id, used_icons)
          {%{pack | icon: icon}, MapSet.put(used_icons, icon)}
        end
      end)

    packs
  end

  defp pack_icon(%{"icon" => icon}) when is_binary(icon) and icon != "", do: icon

  defp pack_icon(json) do
    unique_default_icon(Map.get(json, "build_order_id", "planning"), MapSet.new())
  end

  defp unique_default_icon(build_order_id, used_icons) do
    offset = :erlang.phash2(build_order_id, length(@default_icons))

    candidates =
      @default_icons
      |> Stream.cycle()
      |> Stream.drop(offset)
      |> Enum.take(length(@default_icons))

    Enum.find(candidates, &(not MapSet.member?(used_icons, &1))) || hd(candidates)
  end

  defp pack_before?(left, right) do
    cond do
      left.completed != right.completed -> not left.completed
      left.completed and left.completed_at != right.completed_at -> (left.completed_at || "") > (right.completed_at || "")
      true -> left.title < right.title
    end
  end

  defp configured_repository do
    Config.repo()
  rescue
    _error -> nil
  end

  defp absolute_path(path), do: if(Path.type(path) == :absolute, do: path, else: Application.app_dir(:aiur, path))

  @doc false
  @spec root_identity(map()) :: TrackerIdentity.t()
  def root_identity(pack), do: identity!(pack.repository, pack.root_number, pack.root_node_id || "BO_ROOT")

  @doc false
  @spec ticket_identity(map(), map()) :: TrackerIdentity.t()
  def ticket_identity(pack, %{number: nil, id: id}) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({pack.build_order_id, id}))
    # Reserve bounded 19-digit locators so drafts can open the ticket context.
    number = 1_000_000_000_000_000_000 + rem(:binary.decode_unsigned(digest), 8_223_372_036_854_775_807)
    identity!(pack.repository, number, "PLAN_" <> Base.encode16(digest, case: :lower))
  end

  def ticket_identity(pack, ticket), do: identity!(pack.repository, ticket.number, ticket.node_id || "PLAN_#{ticket.id}")

  defp identity!({owner, repo}, number, node_id) do
    {:ok, identity} =
      TrackerIdentity.from_github(%{"node_id" => node_id, "number" => number}, {owner, repo}, {owner, repo})

    identity
  end
end
