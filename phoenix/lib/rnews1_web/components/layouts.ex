defmodule Rnews1Web.Layouts do
  @moduledoc """
  The one document layout, in three moods: the app; a customer's host (their
  name in the masthead, no platform navigation, app links spelled out in
  full); and the archive (brand link to its own root).
  """
  use Rnews1Web, :html

  embed_templates "layouts/*"
end
