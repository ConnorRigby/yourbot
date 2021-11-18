defmodule YourBot.BotSandbox do
  use GenServer
  import YourBot.BotNameProvider, only: [via: 2]
  alias YourBot.Bots.Bot
  alias YourBot.Bots.Presence
  require Logger

  @endpoint YourBotWeb.Endpoint

  def start_link(%Bot{} = bot) do
    GenServer.start_link(__MODULE__, bot, name: via(bot, __MODULE__))
  end

  def exec_code(bot, pid \\ nil) do
    pid = pid || GenServer.whereis(via(bot, __MODULE__))
    GenServer.cast({__MODULE__, :"#{bot.id}@#{node_name()}"}, {:code, bot.code, pid})
  end

  def get_stdout(bot) do
    GenServer.call(via(bot, __MODULE__), :get_stdout)
  end

  @impl GenServer
  def init(bot) do
    # @endpoint.subscribe("crud:bots")
    python = System.find_executable("python3")
    sandbox_py = Application.app_dir(:yourbot, ["priv", "sandbox", "sandbox.py"])
    {:ok, _presence} = Presence.track(self(), "bots", "#{bot.id}", default_presence())

    args = [
      sandbox_py,
      "--name",
      "#{bot.id}@#{node_name()}",
      "--cookie",
      to_string(Node.get_cookie())
    ]

    {:ok, tty} =
      ExTTY.start_link(
        handler: self(),
        type: :muontrap,
        shell_opts: [
          [
            exec: python,
            args: args
          ]
        ]
      )

    {:ok, %{bot: bot, tty: tty, stdout: []}, {:continue, :connect}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    {:ok, _} =
      Presence.update(self(), "bots", "#{state.bot.id}", fn meta ->
        %{meta | uptime_status: "down"}
      end)
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    case Node.connect(:"#{state.bot.id}@#{node_name()}") do
      true ->
        Logger.info("Connected to #{state.bot.id}@#{node_name()}")
        Node.monitor(:"#{state.bot.id}@#{node_name()}", true)
        # bot = YourBot.Bots.update_bot_deploy_status(state.bot, "live")
        {:ok, _} =
          Presence.update(self(), "bots", "#{state.bot.id}", fn meta ->
            %{meta | uptime_status: "up"}
          end)

        {:noreply, state, {:continue, :exec_code}}

      false ->
        Logger.warn("Failed to connect to #{state.bot.id}@#{node_name()}")

        {:ok, _} =
          Presence.update(self(), "bots", "#{state.bot.id}", fn meta ->
            %{meta | uptime_status: "boot"}
          end)

        Process.sleep(1000)
        {:noreply, state, {:continue, :connect}}
    end
  end

  def handle_continue(:exec_code, state) do
    # internal continue method to start the discord client after the node is up
    :ok = exec_code(state.bot, self())
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:get_stdout, _from, state) do
    {:reply, state.stdout, state}
  end

  @impl GenServer
  def handle_info({:tty_data, data}, state) do
    Logger.debug(%{tty_data: data, bot: state.bot.id})
    @endpoint.broadcast!("bots", "tty_data", %{bot: state.bot, data: data})
    {:noreply, %{state | stdout: state.stdout ++ [data]}}
  end

  def handle_info({:nodedown, _node}, state) do
    {:ok, _} =
      Presence.update(self(), "bots", "#{state.bot.id}", fn meta ->
        %{meta | uptime_status: "down"}
      end)

    # bot = YourBot.Bots.update_bot_deploy_status(state.bot, "error")
    # {:stop, :nodedown, %{state | bot: bot}}
    {:stop, :nodedown, state}
  end

  def node_name, do: Application.get_env(:yourbot, __MODULE__)[:node_name]

  def default_presence do
    %{
      uptime_status: "boot"
    }
  end
end
