defmodule Fp3Demo.UI.App do
  use Solve

  alias Fp3Demo.UI.Battery

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name, __MODULE__)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @impl Solve
  def controllers do
    [controller!(name: :battery, module: Battery)]
  end
end
