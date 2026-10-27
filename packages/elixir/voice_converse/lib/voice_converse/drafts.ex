defmodule VoiceConverse.Drafts do
  @moduledoc """
  The durable projection for instruction drafts.

  A draft changes only through the transitions in `transition/4`. Callers append
  `record/1` to the transcript before notifying subscribers, then retain the
  returned projection for the next operation.
  """

  @max_open_drafts 5
  @max_text_chars 4_000
  @id_regex ~r/\Avd_[A-Za-z0-9_-]{22}\z/
  @statuses [:proposed, :confirmed, :sent, :delivered, :failed, :discarded, :stale]
  @transitions MapSet.new([
                 {:proposed, :confirmed},
                 {:proposed, :discarded},
                 {:proposed, :stale},
                 {:confirmed, :sent},
                 {:confirmed, :failed},
                 {:sent, :delivered},
                 {:sent, :failed},
                 {:failed, :confirmed}
               ])

  defmodule Draft do
    @enforce_keys [:draft_id, :kind, :status, :text, :target, :at]
    defstruct [:draft_id, :kind, :status, :text, :target, :base_version, :at, edited?: false]

    @type t :: %__MODULE__{
            draft_id: String.t(),
            kind: :instruction,
            status: VoiceConverse.Drafts.status(),
            text: String.t(),
            target: map(),
            base_version: term() | nil,
            edited?: boolean(),
            at: String.t()
          }
  end

  @enforce_keys [:drafts]
  defstruct drafts: %{}

  @type status :: unquote(Enum.reduce(@statuses, &{:|, [], [&1, &2]}))
  @type t :: %__MODULE__{drafts: %{optional(String.t()) => Draft.t()}}

  @spec new() :: t()
  def new, do: %__MODULE__{drafts: %{}}

  @spec propose_instruction(t(), term(), keyword()) :: {:ok, Draft.t(), t()} | {:error, term()}
  def propose_instruction(%__MODULE__{} = projection, text, opts \\ []) do
    with :ok <- validate_text(text),
         :ok <- check_open_draft_limit(projection),
         {:ok, draft_id} <- draft_id(Keyword.get(opts, :id_generator, &new_id/0)),
         text <- redact(text, Keyword.get(opts, :redactor, & &1)),
         :ok <- validate_text(text) do
      draft = %Draft{
        draft_id: draft_id,
        kind: :instruction,
        status: :proposed,
        text: text,
        target: Keyword.get(opts, :target, %{}),
        base_version: Keyword.get(opts, :base_version),
        at: Keyword.get(opts, :at, now())
      }

      {:ok, draft, put(projection, draft)}
    end
  end

  @spec confirm(t(), String.t(), map(), keyword()) :: {:ok, Draft.t(), t()} | {:error, term()}
  def confirm(_projection, _draft_id, %{source: source}, _opts) when source != :client_socket, do: {:error, :not_client}

  def confirm(%__MODULE__{} = projection, draft_id, %{source: :client_socket, principal: _principal}, opts),
    do: do_transition(projection, draft_id, :confirmed, opts)

  def confirm(_projection, _draft_id, _principal, _opts), do: {:error, :not_client}

  @spec edit(t(), String.t(), term(), keyword()) :: {:ok, Draft.t(), t()} | {:error, term()}
  def edit(%__MODULE__{} = projection, draft_id, text, opts \\ []) do
    with {:ok, draft} <- fetch(projection, draft_id),
         :proposed <- draft.status || {:error, :invalid_transition},
         :ok <- validate_text(text),
         text <- redact(text, Keyword.get(opts, :redactor, & &1)),
         :ok <- validate_text(text) do
      draft = %{draft | text: text, edited?: true, at: Keyword.get(opts, :at, now())}
      {:ok, draft, put(projection, draft)}
    else
      status when is_atom(status) -> {:error, :invalid_transition}
      {:error, _reason} = error -> error
    end
  end

  @spec transition(t(), String.t(), status(), keyword()) ::
          {:ok, Draft.t(), t()} | {:error, :invalid_transition | :not_client | :not_found}
  def transition(projection, draft_id, next_status, opts \\ [])

  def transition(%__MODULE__{}, _draft_id, :confirmed, _opts), do: {:error, :not_client}

  def transition(%__MODULE__{} = projection, draft_id, next_status, opts) do
    do_transition(projection, draft_id, next_status, opts)
  end

  defp do_transition(%__MODULE__{} = projection, draft_id, next_status, opts) do
    with {:ok, draft} <- fetch(projection, draft_id),
         true <- MapSet.member?(@transitions, {draft.status, next_status}) || {:error, :invalid_transition} do
      draft = %{draft | status: next_status, at: Keyword.get(opts, :at, now())}
      {:ok, draft, put(projection, draft)}
    else
      false -> {:error, :invalid_transition}
      {:error, _reason} = error -> error
    end
  end

  @spec fetch(t(), String.t()) :: {:ok, Draft.t()} | {:error, :not_found}
  def fetch(%__MODULE__{drafts: drafts}, draft_id) when is_binary(draft_id) do
    case Map.fetch(drafts, draft_id) do
      {:ok, draft} -> {:ok, draft}
      :error -> {:error, :not_found}
    end
  end

  def fetch(%__MODULE__{}, _draft_id), do: {:error, :not_found}

  @spec open(t()) :: [Draft.t()]
  def open(%__MODULE__{drafts: drafts}), do: drafts |> Map.values() |> Enum.filter(&(&1.status == :proposed))

  @spec record(Draft.t()) :: map()
  def record(%Draft{} = draft) do
    %{
      type: "draft",
      draft_id: draft.draft_id,
      kind: Atom.to_string(draft.kind),
      status: Atom.to_string(draft.status),
      text: draft.text,
      target: draft.target,
      at: draft.at
    }
    |> maybe_put(:base_version, draft.base_version)
    |> maybe_put(:edited, if(draft.edited?, do: true))
  end

  @spec replay([map()]) :: {:ok, t()} | {:error, :invalid_record}
  def replay(records) when is_list(records) do
    Enum.reduce_while(records, {:ok, new()}, fn record, {:ok, projection} ->
      case draft_from_record(record) do
        :ignore -> {:cont, {:ok, projection}}
        {:ok, draft} -> {:cont, {:ok, put(projection, draft)}}
        :error -> {:halt, {:error, :invalid_record}}
      end
    end)
  end

  def replay(_records), do: {:error, :invalid_record}

  defp put(%__MODULE__{drafts: drafts} = projection, %Draft{} = draft),
    do: %{projection | drafts: Map.put(drafts, draft.draft_id, draft)}

  defp check_open_draft_limit(projection) do
    if length(open(projection)) < @max_open_drafts, do: :ok, else: {:error, :too_many_open_drafts}
  end

  defp validate_text(text) when is_binary(text) and text != "" do
    if String.length(text) <= @max_text_chars, do: :ok, else: {:error, :text_too_long}
  end

  defp validate_text(text) when is_binary(text), do: {:error, :invalid_text}
  defp validate_text(_text), do: {:error, :invalid_text}

  defp draft_id(generator) when is_function(generator, 0) do
    case generator.() do
      draft_id when is_binary(draft_id) ->
        if(Regex.match?(@id_regex, draft_id), do: {:ok, draft_id}, else: {:error, :invalid_draft_id})

      _ ->
        {:error, :invalid_draft_id}
    end
  end

  defp draft_id(_generator), do: {:error, :invalid_draft_id}
  defp new_id, do: "vd_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  defp redact(text, redactor) when is_function(redactor, 1), do: redactor.(text)
  defp redact(_text, _redactor), do: ""
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp maybe_put(record, _key, nil), do: record
  defp maybe_put(record, key, value), do: Map.put(record, key, value)

  defp draft_from_record(record) do
    if value(record, :type) == "draft" do
      with draft_id when is_binary(draft_id) <- value(record, :draft_id),
           true <- Regex.match?(@id_regex, draft_id),
           {:ok, kind} <- kind(value(record, :kind)),
           {:ok, status} <- status(value(record, :status)),
           text when is_binary(text) <- value(record, :text),
           target when is_map(target) <- value(record, :target),
           at when is_binary(at) <- value(record, :at) do
        {:ok,
         %Draft{
           draft_id: draft_id,
           kind: kind,
           status: status,
           text: text,
           target: target,
           base_version: value(record, :base_version),
           edited?: value(record, :edited) == true,
           at: at
         }}
      else
        _ -> :error
      end
    else
      :ignore
    end
  end

  defp value(record, key) when is_map(record), do: Map.get(record, key, Map.get(record, Atom.to_string(key)))
  defp value(_record, _key), do: nil
  defp kind("instruction"), do: {:ok, :instruction}
  defp kind(:instruction), do: {:ok, :instruction}
  defp kind(_kind), do: :error
  defp status(status) when status in @statuses, do: {:ok, status}

  defp status(status) when is_binary(status) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == status)) do
      nil -> :error
      status -> {:ok, status}
    end
  end

  defp status(_status), do: :error
end
