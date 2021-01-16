defmodule Alchemy.Voice.Controller do
  @moduledoc false
  use GenServer
  require Logger
  alias Alchemy.Voice.Supervisor.VoiceRegistry
  alias Porcelain.Process, as: Proc

  defmodule State do
    @moduledoc false
    defstruct [
      :udp, 
      :key, 
      :ssrc, 
      :ip, 
      :port, 
      :guild_id, 
      :player, 
      :ws,      
      :kill_timer, 
      :time, 
      listeners: MapSet.new()]
  end

  def start_link(udp, key, ssrc, ip, port, guild_id, me) do
    state = %State{udp: udp, key: key, ssrc: ssrc,
                   ip: ip, port: port, guild_id: guild_id, ws: me, time: 0}
    GenServer.start_link(__MODULE__, state,
                         name: VoiceRegistry.via({guild_id, :controller}))
  end

  def init(state) do
    Logger.debug "Voice Controller for #{state.guild_id} started"
    {:ok, state}
  end

  def handle_cast({:send_audio, data}, state) do
    # We need to do this because youtube streams don't cut off when they finish
    # playing audio, so we need to manually check and kill.
    unless state.kill_timer == nil do
      Process.cancel_timer(state.kill_timer)
    end
    timer = Process.send_after(self(), {:stop_playing, :automatic}, 120)
    :gen_udp.send(state.udp, state.ip, state.port, data)
    {:noreply, %{state | kill_timer: timer}}
  end
  
  def handle_cast({:update_time, new_time}, state) do
    {:noreply, %{state | time: new_time}}
  end

  def handle_call({:play, path, type, options}, _, state) do
    self = self()
    if state.player != nil && Process.alive?(state.player.pid) do
      {:reply, {:error, "Already playing audio"}, state}
    else
      player = Task.async(fn ->
        new_time = run_player(path, type, options, self,
          %{ssrc: state.ssrc, key: state.key, ws: state.ws, time: state.time})
        
        GenServer.cast(self, {:update_time, new_time})
      end)
      {:reply, :ok, %{state | player: player}}
    end
  end

  def handle_call(:stop_playing, _, state) do
    new = case state.player do
      nil -> state
      _ -> stop_playing(state, :unknown)
    end
    {:reply, :ok, new}
  end

  def handle_call({:stop_playing, source}, _, state) do
    new = case state.player do
            nil -> state
            _ -> stop_playing(state, source)
          end
    {:reply, :ok, new}
  end

  def handle_call(:add_listener, {pid, _}, state) do
    {:reply, :ok, Map.update!(state, :listeners,&MapSet.put(&1, pid))}
  end

  def handle_call({:add_listener, genserver_pid}, {pid, _}, state) do
    {:reply, :ok, Map.update!(state, :listeners,&MapSet.put(&1, genserver_pid))}
  end

  def handle_info(:stop_playing, state) do
    {:noreply, stop_playing(state, :unknown)}
  end

  def handle_info({:stop_playing, source}, state) do
    {:noreply, stop_playing(state, source)}
  end

  # ignore down messages from the task
  def handle_info(_, state) do
    {:noreply, state}
  end

  defp stop_playing(state, source) do
    Task.shutdown(state.player)
    MapSet.to_list(state.listeners)
    |> Enum.each(&send(&1, {:audio_stopped, state.guild_id, source}))
    %{state | listeners: MapSet.new()}
  end

  ## Audio stuff ##

  defp header(sequence, time, ssrc) do
    <<0x80, 0x78, sequence::size(16), time::size(32), ssrc::size(32)>>
  end

  defp mk_stream(file_path, options) do
    volume = (options[:vol] || 100) / 100
    filter_complex = "volume=#{volume}"

    filter_complex =
      if options[:phaser] != nil do
        speed = normalize_value(:speed, options[:phaser][:speed])
        decay = normalize_value(:decay, options[:phaser][:decay])
        delay = normalize_value(:delay, options[:phaser][:delay])

        filter_complex <> ",aphaser=in_gain=1:out_gain=1:speed=#{speed}:decay=#{decay}:delay=#{delay}"
      else
        filter_complex
      end

    filter_complex =
      if options[:flanger] != nil do
        filter_complex <> ",flanger=speed=10:delay=30:depth=10:width=80:phase=10"
      else
        filter_complex
      end

    if options[:pitch] != nil or options[:speed] != nil or options[:reverse] != nil or options[:bass] != nil or options[:overdrive] != nil or options[:stretch] != nil do
      # sox path
      IO.puts("sox path mk_stream")
      ffmpeg_command = ["-hide_banner", "-loglevel", "quiet", "-i", "#{file_path}", "-filter_complex", filter_complex, "-f", "ogg", "-map", "0:a", "-ar", "48k", "-ac", "2", "-acodec", "libvorbis", "-b:a", "128k", "pipe:1"]

      %Proc{out: audio_stream} =
        Porcelain.spawn(Application.fetch_env!(:alchemy, :ffmpeg_path), ffmpeg_command, [out: :stream])
      sox(audio_stream, options)
    else
      ffmpeg_command = ["-hide_banner", "-loglevel", "quiet", "-i", "#{file_path}", "-filter_complex", filter_complex, "-f", "data", "-map", "0:a", "-ar", "48k", "-ac", "2", "-acodec", "libopus", "-b:a", "128k", "pipe:1"]

      %Proc{out: audio_stream} =
        Porcelain.spawn(Application.fetch_env!(:alchemy, :ffmpeg_path), ffmpeg_command, [out: :stream])
      audio_stream
    end
  end

  defp normalize_value(:speed, value) do
    cond do
      value < 0.1 == true -> 0.1
      value > 2.0 == true -> 2.0
      value == nil -> 0.5
      true -> value
    end
  end

  defp normalize_value(:decay, value) do
    cond do
      value < 0.1 == true -> 0.1
      value > 0.9 == true -> 0.9
      value == nil -> 0.4
      true -> value
    end
  end

  defp normalize_value(:delay, value) do
    cond do
      value < 0.1 == true -> 0.1
      value > 5.0 == true -> 5.0
      value == nil -> 3.0
      true -> value
    end
  end

  defp url_stream(url, options) do
    %Proc{out: youtube} =
      Porcelain.spawn(Application.fetch_env!(:alchemy, :youtube_dl_path),
        ["-q", "-f", "bestaudio/webm/mp4", "-o", "-", url], [out: :stream])
    io_data_stream(youtube, options)
  end

  defp io_data_stream(data, options) do
    volume = (options[:vol] || 100) / 100
    opts = [in: data, out: :stream]

    filter_complex = "volume=#{volume}"

    filter_complex =
    if options[:phaser] != nil do
      speed = normalize_value(:speed, options[:phaser][:speed])
      decay = normalize_value(:decay, options[:phaser][:decay])
      delay = normalize_value(:delay, options[:phaser][:delay])

      filter_complex <> ",aphaser=in_gain=1:out_gain=1:speed=#{speed}:decay=#{decay}:delay=#{delay}"
    else
      filter_complex
    end

    filter_complex =
    if options[:flanger] != nil do
      filter_complex <> ",flanger=speed=10:delay=30:depth=10:width=80:phase=10"
    else
      filter_complex
    end


    if options[:pitch] != nil or options[:speed] != nil or options[:reverse] != nil or options[:bass] != nil or options[:overdrive] != nil or options[:stretch] != nil do
      # sox path
      IO.puts("sox path")
      ffmpeg_command = ["-hide_banner", "-loglevel", "quiet", "-i","pipe:0", "-filter_complex", filter_complex,
                        "-f", "ogg", "-map", "0:a", "-ar", "48k", "-ac", "2", "-acodec", "libvorbis", "-b:a", "128k", "pipe:1"]

      %Proc{out: audio_stream} =
        Porcelain.spawn(Application.fetch_env!(:alchemy, :ffmpeg_path), ffmpeg_command, opts)
      sox(audio_stream, options)
    else
      ffmpeg_command = ["-hide_banner", "-loglevel", "quiet", "-i","pipe:0", "-filter_complex", filter_complex,
                        "-f", "data", "-map", "0:a", "-ar", "48k", "-ac", "2", "-acodec", "libopus", "-b:a", "128k", "pipe:1"]

      %Proc{out: audio_stream} =
        Porcelain.spawn(Application.fetch_env!(:alchemy, :ffmpeg_path), ffmpeg_command, opts)
      audio_stream
    end
  end

  defp sox(data, options) do
    opts = [in: data, out: :stream]

    bend_values = Times.main()

    extra = []

    extra =
    if options[:speed] != nil do
      extra ++ ["speed", Float.to_string(options[:speed])]
    else
      extra
    end

    extra =
    if options[:reverse] != nil do
      extra ++ ["reverse"]
    else
      extra
    end

    extra =
    if options[:bass] != nil do
      extra ++ ["bass", Float.to_string(options[:bass])]
    else
      extra
    end

    extra =
    if options[:overdrive] != nil do
      extra ++ ["overdrive", Float.to_string(options[:overdrive])]
    else
      extra
    end

    extra =
    if options[:stretch] != nil do
      extra ++ ["stretch", Float.to_string(options[:stretch])]
    else
      extra
    end

    extra =
    if options[:pitch] != nil do
      extra ++ ["bend"] ++ bend_values
    else
      extra
    end

    sox_command = ["-V0", "-q", "-t", "vorbis", "-", "-q", "-t", "wav", "-", "gain", "2"] ++ extra

    IO.inspect(sox_command)
    %Proc{out: sox_out} = Porcelain.spawn("/usr/bin/sox", sox_command, opts)
    Process.sleep(100)

    IO.inspect("fug")
    opusenc(sox_out, options)
  end

  defp opusenc(data, options) do
    opts = [in: data, out: :stream]

    ffmpeg_command = ["-hide_banner", "-loglevel", "quiet", "-i", "pipe:0", "-f", "data", "-map", "0:a", "-ar", "48k", "-ac", "2", "-acodec", "libopus", "-b:a", "128k", "pipe:1"]

    IO.puts("lol xd")

    %Proc{out: opusenc_out} = Porcelain.spawn(Application.fetch_env!(:alchemy, :ffmpeg_path), ffmpeg_command, opts)
    IO.inspect(opusenc_out)
    Process.sleep(100)
    IO.puts("kumm")
    opusenc_out
  end

  defp run_player(path, type, options, parent, state) do
    send(state.ws, {:speaking, true})
    stream = case type do
      :file -> mk_stream(path, options)
      :url -> url_stream(path, options)
      :iodata -> io_data_stream(path, options)
    end
    {seq, time, _} =
      stream
      |> Enum.reduce({0, state.time, nil}, fn packet, {seq, time, elapsed} ->
        packet = mk_audio(packet, seq, time, state)
        GenServer.cast(parent, {:send_audio, packet})
        # putting the elapsed time directly in the accumulator makes it incorrect
        elapsed = elapsed || :os.system_time(:milli_seconds)
        Process.sleep(do_sleep(elapsed))
        {seq + 1, time + 960, elapsed + 20}
      end)
    # We must send 5 frames of silence to end opus interpolation
    {_seq, new_time} = Enum.reduce(1..5, {seq, time}, fn _, {seq, time} ->
      GenServer.cast(parent, {:send_audio, <<0xF8, 0xFF, 0xFE>>})
      Process.sleep(20)
      {seq + 1, time + 960}
    end)
    
    send(state.ws, {:speaking, false})
    new_time
  end

  defp mk_audio(packet, seq, time, state) do
    header = header(seq, time, state.ssrc)
    nonce = (header <> <<0::size(96)>>)
    header <> Kcl.secretbox(packet, nonce, state.key)
  end

  # this also takes care of adjusting for sleeps taking too long
  defp do_sleep(elapsed, delay \\ 20) do
    max(0, elapsed - :os.system_time(:milli_seconds) + delay)
  end
end


defmodule Times do
  def main do
    result = generate_timestamps(0.1, 750.0, 0.1, [], 1)
    # result2 = Enum.map_join(result, " ", fn(x) -> x end)

    result
  end

  def generate_timestamps(start, finish, current, acc, pitch) when start >= finish do
    Enum.reverse(acc)
  end

  def generate_timestamps(start, finish, current, acc, pitch) do
    new_pitch = Enum.random([Enum.random(-1460..-1), Enum.random(1..1460)])

    diff = new_pitch - pitch

    #new_pitch = Enum.random([-1500, -700, -400, -100, 1, 100, 400, 700, 1500])

    rand_pos = Enum.random([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9])
    res = "#{Float.ceil(rand_pos, 1)},#{diff},#{Float.ceil(rand_pos + 1.4, 1)}"

    generate_timestamps(Float.ceil(current + 0.7, 1), finish, Float.ceil(current + 0.7, 1), [res | acc], new_pitch)
  end

  def default_low() do
    -1400
  end

  def default_high() do
    1400
  end
end
