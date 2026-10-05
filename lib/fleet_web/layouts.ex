defmodule FleetWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>BEAM // Fleet Continuum</title>
        <link rel="icon" href="/favicon.svg" type="image/svg+xml" />
        <link rel="stylesheet" href="/assets/app.css" />
        <script type="module" src="/assets/app.js">
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
