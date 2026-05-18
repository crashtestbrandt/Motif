defmodule MotifWeb.Layouts do
  use MotifWeb, :component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  embed_templates "layouts/*"
end
