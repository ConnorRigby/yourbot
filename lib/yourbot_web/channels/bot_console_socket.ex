defmodule YourBotWeb.BotConsoleSocket do
  @moduledoc """
  ## Javascript example

      // Create WebSocket connection.
      const socket = new WebSocket('ws://localhost:4000/api/bots/console');

      // Connection opened
      socket.addEventListener('open', function (event) {
          socket.send('Hello Server!');
      });

      // Listen for messages
      socket.addEventListener('message', function (event) {
          console.log('Message from server ', event.data);
      });
  """

  import Phoenix.Socket
  alias YourBot.Bots.Bot
  alias YourBot.Bots
  alias YourBot.Accounts.APIToken

  @behaviour :cowboy_websocket

  # entry point of the websocket socket.
  # WARNING: this is where you would need to do any authentication
  #          and authorization. Since this handler is invoked BEFORE
  #          our Phoenix router, it will NOT follow your pipelines defined there.
  #
  # WARNING: this function is NOT called in the same process context as the rest of the functions
  #          defined in this module. This is notably dissimilar to other gen_* behaviours.
  @impl :cowboy_websocket
  def init(req, opts) do
    token = req.headers["authorization"]

    with {:ok, _user} <- APIToken.verify(token || ""),
         %{"device_id" => device_id} <- URI.decode_query(req.qs),
         %Bot{} = bot <- Bots.get_bot(device_id),
         socket <- into_socket(req, opts) do
      {:cowboy_websocket, req,
       socket
       |> assign(:bot, bot)}
    else
      _ ->
        {:reply, {:close, 1000, "reason"}, opts}
    end
  end

  # as long as `init/2` returned `{:cowboy_websocket, req, opts}`
  # this function will be called. You can begin sending packets at this point.
  # We'll look at how to do that in the `websocket_handle` function however.
  # This function is where you might want to  implement `Phoenix.Presence`, schedule an `after_join` message etc.
  @impl :cowboy_websocket
  def websocket_init(socket) do
    socket.endpoint.subscribe("sandbox")
    Process.send_after(self(), :send_ping, 5000)
    {[], socket}
  end

  @impl :cowboy_websocket
  def websocket_handle(frame, socket)

  # :ping is not handled for us like in Phoenix Channels.
  # We must explicitly send :pong messages back.
  def websocket_handle(:ping, socket), do: {[:pong], socket}

  def websocket_handle(:pong, socket) do
    Process.send_after(self(), :send_ping, 5000)
    {[], socket}
  end

  # a message was delivered from a client. Here we handle it by just echoing it back
  # to the client.
  def websocket_handle({:text, message}, socket) do
    case Jason.decode(message) do
      {:ok, command} ->
        handle_command(command, socket)

      {:error, _} ->
        {[{:text, Jason.encode!(%{errors: ["could not decode json"]})}], socket}
    end
  end

  def handle_command(%{"kind" => "stop_sandbox"}, socket) do
    bot = socket.assigns.bot

    if pid = GenServer.whereis(YourBot.BotNameProvider.via(bot, YourBot.BotSandbox)) do
      DynamicSupervisor.terminate_child(YourBot.BotSupervisor, pid)
    end

    case YourBot.BotSupervisor.start_child(bot) do
      {:ok, _pid} ->
        {[{:text, Jason.encode!(%{"status" => "ok"})}], socket}
    end
  end

  def handle_command(%{"kind" => "deploy_sandbox"}, socket) do
    bot = socket.assigns.bot

    if pid = GenServer.whereis(YourBot.BotNameProvider.via(bot, YourBot.BotSandbox)) do
      DynamicSupervisor.terminate_child(YourBot.BotSupervisor, pid)
    end

    case YourBot.BotSupervisor.start_child(bot) do
      {:ok, _pid} ->
        YourBot.BotSandbox.exec_code(bot)
        {[{:text, Jason.encode!(%{"status" => "ok"})}], socket}
    end
  end

  def handle_command(_command, socket) do
    {[{:text, Jason.encode!(%{errors: ["unknown command"]})}], socket}
  end

  # This function is where we will process all *other* messages that get delivered to the
  # process mailbox. This function isn't used in this handler.
  @impl :cowboy_websocket
  def websocket_info(info, socket)

  def websocket_info(:send_ping, socket) do
    {[:ping], socket}
  end

  def websocket_info(_info, socket), do: {[], socket}

  def into_socket(req, _opts) do
    %Phoenix.Socket{
      endpoint: YourBotWeb.Endpoint,
      private: %{req: req}
    }
  end
end
