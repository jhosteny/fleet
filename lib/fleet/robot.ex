defmodule Fleet.Robot do
  use DurableServer, vsn: 1

  @fields ~w(id x y battery order phase progress cargo completed ticks commands paused boots)a
  def initial(id) do
    %{
      id: id,
      x: 12.0,
      y: 8.0 + rem(id, 7) * 8,
      battery: 75.0 + rem(id, 25),
      order: 8420 + id,
      phase: 0,
      progress: 0,
      cargo: nil,
      completed: 0,
      ticks: 0,
      commands: 0,
      paused: false,
      boots: 0
    }
  end

  @impl true
  def dump_state(state), do: Map.take(state, @fields)
  @impl true
  def load_state(_vsn, state), do: state

  @impl true
  def init(state, info) do
    state = Map.merge(state, %{host: info.host, boots: state.boots + 1})
    Process.send_after(self(), :tick, 100 + rem(state.id * 37, 650))
    send(self(), :first_report)
    {:ok, state, permanent: true, meta: %{id: state.id}, auto_sync: false}
  end

  @impl true
  def handle_info(:first_report, state), do: {:noreply, state, {:continue, :report}, sync: true}

  def handle_info(:tick, state) do
    state = advance(state)
    {:noreply, state, {:continue, :tick_report}, sync: true}
  end

  @impl true
  def handle_continue(action, state) do
    # DurableServer executes this continuation only after the strict sync succeeds.
    GenServer.cast({Fleet.Telemetry, state.host}, {:robot, node(), self(), dump_state(state)})
    if action == :tick_report, do: Process.send_after(self(), :tick, 250)
    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, dump_state(state), state}

  def handle_call(command, _from, state) when command in [:pause, :resume, :charge] do
    state =
      case command do
        :pause -> %{state | paused: true}
        :resume -> %{state | paused: false}
        :charge -> %{state | battery: 100.0}
      end

    state = %{state | commands: state.commands + 1}
    {:reply, {:ok, dump_state(state)}, state, {:continue, :report}, sync: true}
  end

  def advance(%{paused: true} = state), do: state

  def advance(%{battery: battery} = state) when battery < 10 do
    %{state | battery: min(100.0, battery + 1.2), ticks: state.ticks + 1}
  end

  def advance(state) do
    next = %{state | ticks: state.ticks + 1, battery: max(0.0, state.battery - 0.012)}

    case state.phase do
      0 ->
        navigate(next, pickup(state), 1)

      1 ->
        dwell(next, 2, "PLT-#{state.order}")

      2 ->
        navigate(next, {88.0, 8.0 + rem(state.id, 7) * 8}, 3)

      3 ->
        next = dwell(next, 0, nil)

        if next.phase == 0,
          do: %{next | order: state.order + 5000, completed: state.completed + 1},
          else: next
    end
  end

  defp pickup(state), do: {24.0 + rem(state.order * 7, 6) * 9, 8.0 + rem(state.order, 7) * 8}

  defp navigate(state, {tx, ty}, next_phase) do
    # Vertical travel stays on the warehouse's two unobstructed arterial aisles.
    rail = if state.phase == 0, do: 12.0, else: 88.0

    {x, y} =
      cond do
        abs(state.y - ty) > 0.01 and abs(state.x - rail) > 0.01 ->
          {toward(state.x, rail), state.y}

        abs(state.y - ty) > 0.01 ->
          {state.x, toward(state.y, ty)}

        true ->
          {toward(state.x, tx), state.y}
      end

    reached = abs(x - tx) < 0.01 and abs(y - ty) < 0.01

    %{
      state
      | x: x,
        y: y,
        progress: if(reached, do: 0, else: min(99, state.progress + 1)),
        phase: if(reached, do: next_phase, else: state.phase)
    }
  end

  defp toward(value, target), do: value + max(-0.8, min(0.8, target - value))

  defp dwell(state, phase, cargo) do
    if state.progress >= 10,
      do: %{state | phase: phase, progress: 0, cargo: cargo},
      else: %{state | progress: state.progress + 1}
  end
end
