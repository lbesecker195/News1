defmodule Rnews1.HttpError do
  @moduledoc "An error with an HTTP status: rendered as the message page or as JSON."
  defexception [:status, :message]

  @impl true
  def exception(opts) when is_list(opts) do
    %__MODULE__{status: Keyword.fetch!(opts, :status), message: Keyword.fetch!(opts, :message)}
  end

  def exception({status, message}), do: %__MODULE__{status: status, message: message}

  def new(status, message), do: %__MODULE__{status: status, message: message}
end

defimpl Plug.Exception, for: Rnews1.HttpError do
  def status(%{status: status}), do: status
  def actions(_), do: []
end
