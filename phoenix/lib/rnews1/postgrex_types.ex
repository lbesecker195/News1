defmodule Rnews1.Postgrex.UUID do
  @moduledoc """
  UUIDs as strings on the wire.

  Postgrex hands a `uuid` column back as sixteen raw bytes, which is right for
  Ecto schemas and wrong for everything here: the queries are written by hand,
  their rows are maps, and an id is a thing that goes into URLs, JSON and log
  lines as text. Decoding to the canonical string once, at the driver, is
  cheaper than remembering to convert at every use — and encoding accepts
  both forms so a raw binary still round-trips.
  """
  import Postgrex.BinaryUtils, warn: false

  @behaviour Postgrex.Extension

  def init(_opts), do: nil
  def matching(_state), do: [type: "uuid"]
  def format(_state), do: :binary

  def encode(_state) do
    quote location: :keep do
      <<_::128>> = raw ->
        [<<16::int32()>> | raw]

      string when is_binary(string) and byte_size(string) == 36 ->
        [<<16::int32()>> | Rnews1.Postgrex.UUID.to_binary!(string)]
    end
  end

  def decode(_state) do
    quote location: :keep do
      <<16::int32(), raw::binary-16>> -> Rnews1.Postgrex.UUID.to_string(raw)
    end
  end

  def to_string(<<a::32, b::16, c::16, d::16, e::48>>) do
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  def to_binary!(string) do
    case Ecto.UUID.dump(string) do
      {:ok, raw} -> raw
      :error -> raise ArgumentError, "not a UUID: #{inspect(string)}"
    end
  end
end

Postgrex.Types.define(
  Rnews1.PostgrexTypes,
  [Rnews1.Postgrex.UUID] ++ Ecto.Adapters.Postgres.extensions(),
  json: Jason
)
