defmodule Cortex.Gossip.Entry do
  @moduledoc """
  A knowledge entry in the gossip-based coordination system.

  Each entry represents a discrete piece of knowledge that agents share via
  gossip protocol. Entries are identified by a unique `id` and tracked with
  vector clocks for causal ordering and conflict resolution.

  ## Fields

    - `id` — unique identifier (UUID string)
    - `topic` — the knowledge topic/category (e.g., "market_research")
    - `content` — the actual knowledge content (free-form string)
    - `source` — the agent ID that created or last updated this entry
    - `confidence` — confidence score from 0.0 to 1.0 (default 0.5)
    - `timestamp` — UTC datetime of creation/last update
    - `vector_clock` — vector clock for causal ordering (default empty map)
    - `metadata` — arbitrary metadata map (default empty map)

  """

  alias Cortex.Gossip.VectorClock

  @enforce_keys [:id, :topic, :content, :source]
  defstruct [
    :id,
    :topic,
    :content,
    :source,
    confidence: 0.5,
    timestamp: nil,
    vector_clock: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          topic: String.t(),
          content: String.t(),
          source: String.t(),
          confidence: float(),
          timestamp: DateTime.t() | nil,
          vector_clock: VectorClock.t(),
          metadata: map()
        }

  @doc """
  Creates a new knowledge entry with defaults filled in.

  Generates a UUID for the `id`, sets `timestamp` to now, and initializes
  the `vector_clock` with a single increment for the `source` agent.

  ## Parameters

    - `attrs` — a map or keyword list with at least `:topic`, `:content`, and `:source`

  ## Examples

      iex> entry = Cortex.Gossip.Entry.new(topic: "research", content: "finding", source: "agent_a")
      iex> entry.confidence
      0.5

  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs) do
    new(Map.new(attrs))
  end

  def new(attrs) when is_map(attrs) do
    id = Map.get(attrs, :id, Uniq.UUID.uuid4())
    source = Map.fetch!(attrs, :source)
    timestamp = Map.get(attrs, :timestamp, DateTime.utc_now())
    vc = Map.get(attrs, :vector_clock, VectorClock.new() |> VectorClock.increment(source))

    struct!(
      __MODULE__,
      attrs
      |> Map.put(:id, id)
      |> Map.put(:timestamp, timestamp)
      |> Map.put(:vector_clock, vc)
    )
  end
end
