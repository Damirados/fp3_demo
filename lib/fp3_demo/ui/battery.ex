defmodule Fp3Demo.UI.Battery do
  use Solve.Controller

  @path "/sys/class/power_supply/qg-battery"

  @impl Solve.Controller
  def init(_params, _dependencies) do
    :timer.send_interval(500, :refresh)
    read_status()
  end

  def handle_info(:refresh, _state), do: read_status()

  def read_status do
     @path
     |> File.ls!()
     |> Enum.reject(&(&1 == "uevent"))
     |> Enum.reduce(%{}, fn name, acc ->
       case File.read(Path.join(@path, name)) do
         {:ok, value} ->
           Map.put(acc, String.to_atom(name), String.trim(value))

         {:error, _reason} ->
           acc
       end
     end)
  end
end
