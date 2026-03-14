defmodule Cortex.Store.Schemas.EventLog do
  @moduledoc """
  Ecto schema for persisted PubSub events.

  Captures a log of all events that flow through the Cortex.Events
  PubSub system for replay, debugging, and analytics.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "event_logs" do
    field(:run_id, :string)
    field(:event_type, :string)
    field(:payload, :map, default: %{})
    field(:source, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(event_type)a
  @optional_fields ~w(run_id payload source)a

  def changeset(event_log, attrs) do
    event_log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
