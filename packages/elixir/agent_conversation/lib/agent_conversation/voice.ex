defmodule AgentConversation.Voice do
  @moduledoc """
  Dictation and two-way voice as the component sees them.

  The component does not own a voice protocol. A host reports which modes its own
  voice client offers through `voice_capabilities/2`; this module turns that
  report into the four states a reader needs to see: ready, unavailable,
  permission denied and reconnecting.

  `:dictation` is one-way speech into the composer. `:two_way` is a spoken
  conversation with the agent, which a host only offers when its client already
  supports it.
  """

  alias AgentConversation.{Host, Scope}

  defstruct mode: :text_only,
            connection: :idle,
            capabilities: %{dictation: false, two_way: false},
            reset_at: nil,
            reason: nil

  @modes [:dictation, :two_way]

  @type mode :: :text_only | :dictation | :two_way
  @type status :: :available | :active | :unavailable | :permission_denied | :reconnecting
  @type t :: %__MODULE__{
          mode: mode(),
          connection: :idle | :connected | :reconnecting,
          capabilities: %{dictation: boolean(), two_way: boolean()},
          reset_at: non_neg_integer() | nil,
          reason: atom() | nil
        }

  @doc """
  Reports which voice modes this host may actually offer.

  The host mount decides first: an embed that did not mount voice is
  `:unavailable` no matter what the transport says, and a host that mounted
  dictation only never offers two-way voice. A transport report that refuses for
  permissions stays `:permission_denied` so the composer can say which it is.

  Pass `nil` as the report to read it from the host's transport, or the result of
  a previous `voice_capabilities/2` call to avoid asking twice.
  """
  @spec capabilities(Host.t(), String.t(), term()) :: {:ok, map()} | {:error, atom()}
  def capabilities(%Host{} = host, conversation_id, report \\ nil) do
    report = if is_nil(report), do: read_report(host, conversation_id), else: report

    with :ok <- mounted(host),
         :ok <- in_scope(host, conversation_id),
         {:ok, capabilities} <- normalize(report),
         {:ok, offered} <- narrow(host, capabilities) do
      {:ok, Map.new(offered, &{&1, true})}
    end
  end

  @doc """
  Opens a voice session for one mode, or returns why it cannot.

  This is the single entry point a host calls: mount, scope, capability report and
  mode are all checked here, so no caller can bypass one of them.
  """
  @spec open(Host.t(), String.t(), mode(), term()) :: {:ok, t()} | {:error, atom()}
  def open(%Host{} = host, conversation_id, mode, report \\ nil) do
    with {:ok, capabilities} <- capabilities(host, conversation_id, report) do
      start(from_report({:ok, capabilities}), mode)
    end
  end

  defp read_report(%Host{transport: transport} = host, conversation_id) do
    if Code.ensure_loaded?(transport) and function_exported?(transport, :voice_capabilities, 2) do
      transport.voice_capabilities(host, conversation_id)
    else
      {:error, :not_implemented}
    end
  end

  defp mounted(host), do: if(Host.enabled?(host, :voice), do: :ok, else: {:error, :unavailable})

  defp in_scope(host, conversation_id) do
    case Scope.check(host.scope, conversation_id, :voice) do
      :ok -> :ok
      {:error, :out_of_scope} -> {:error, :out_of_scope}
      {:error, _reason} -> {:error, :permission_denied}
    end
  end

  defp normalize({:ok, %{} = capabilities}), do: {:ok, capabilities}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(_report), do: {:error, :not_implemented}

  defp narrow(host, capabilities) do
    offered =
      Enum.filter(@modes, fn mode ->
        truthy(Map.get(capabilities, mode) || Map.get(capabilities, Atom.to_string(mode))) and
          (mode != :two_way or Host.feature(host, :voice) in [true, :two_way])
      end)

    if offered == [], do: {:error, :unavailable}, else: {:ok, offered}
  end

  @doc "Every voice mode a host can report."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc """
  Builds voice state from a transport report.

  `{:ok, %{dictation: true, two_way: false}}` offers dictation only; a transport
  that does not implement the optional `voice_capabilities/2` callback reports
  `{:error, :not_implemented}` and the component stays text-only.
  """
  @spec from_report(term()) :: t()
  def from_report({:ok, %{} = capabilities}) do
    %__MODULE__{
      capabilities: %{
        dictation: truthy(Map.get(capabilities, :dictation) || Map.get(capabilities, "dictation")),
        two_way: truthy(Map.get(capabilities, :two_way) || Map.get(capabilities, "two_way"))
      },
      reason: Map.get(capabilities, :reason) || Map.get(capabilities, "reason")
    }
  end

  def from_report({:error, reason}), do: %__MODULE__{reason: reason}
  def from_report(_report), do: %__MODULE__{reason: :not_implemented}

  @doc "The modes this host may use, in the order the composer offers them."
  @spec offered(t()) :: [mode()]
  def offered(%__MODULE__{reason: :permission_denied}), do: []
  def offered(%__MODULE__{capabilities: capabilities}), do: Enum.filter(@modes, &Map.get(capabilities, &1, false))

  @doc """
  Starts a voice mode.

  A mode the host does not offer reports `:unavailable`, and one refused for
  permissions reports `:permission_denied`, so the composer can say which.
  """
  @spec start(t(), mode()) :: {:ok, t()} | {:error, atom()}
  def start(%__MODULE__{} = voice, :text_only), do: {:ok, %{voice | mode: :text_only, connection: :idle}}

  def start(%__MODULE__{reason: :permission_denied}, _mode), do: {:error, :permission_denied}

  def start(%__MODULE__{} = voice, mode) when mode in @modes do
    if mode in offered(voice) do
      {:ok, %{voice | mode: mode, connection: :connected}}
    else
      {:error, :unavailable}
    end
  end

  def start(%__MODULE__{}, _mode), do: {:error, :invalid_mode}

  @doc "Stops voice and returns to text only, keeping the host's capabilities."
  @spec stop(t()) :: t()
  def stop(%__MODULE__{} = voice), do: %{voice | mode: :text_only, connection: :idle}

  @doc "Records a dropped connection without losing the selected mode."
  @spec disconnect(t()) :: t()
  def disconnect(%__MODULE__{mode: :text_only} = voice), do: voice
  def disconnect(%__MODULE__{} = voice), do: %{voice | connection: :reconnecting}

  @doc "Records that the host re-established the voice connection."
  @spec reconnect(t()) :: t()
  def reconnect(%__MODULE__{mode: :text_only} = voice), do: voice
  def reconnect(%__MODULE__{} = voice), do: %{voice | connection: :connected}

  @doc """
  The state the composer renders.

  Permission denial outranks a dropped connection: there is nothing to reconnect
  to. A reconnect in progress outranks availability.
  """
  @spec status(t()) :: status()
  def status(%__MODULE__{reason: :permission_denied}), do: :permission_denied
  def status(%__MODULE__{connection: :reconnecting}), do: :reconnecting
  def status(%__MODULE__{mode: mode}) when mode in [:dictation, :two_way], do: :active
  def status(%__MODULE__{} = voice), do: if(offered(voice) == [], do: :unavailable, else: :available)

  @doc "Short reader-facing text for each state."
  @spec label(status() | t()) :: String.t()
  def label(%__MODULE__{} = voice), do: label(status(voice))
  def label(:available), do: "Voice ready"
  def label(:active), do: "Voice listening"
  def label(:unavailable), do: "Voice is not available in this embed"
  def label(:permission_denied), do: "Voice is not permitted for this account"
  def label(:reconnecting), do: "Voice reconnecting…"

  defp truthy(value), do: value == true
end
