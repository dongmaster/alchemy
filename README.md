# Alchemy

This fork was made to add bot-specific features that I personally wanted.
Here's a list of the new features:
1. Made a distinction between audio being stopped automatically after playing audio (end of audio file or YouTube video), and audio being manually stopped (such as a !stop command).
   * This was added because otherwise it would be impossible to add a queue system for playing audio files.
2. Added several audio effects/filters.
   * Phaser
   * Flanger
   * Speed (speed of audio, slower or faster. This effect uses SoX)
   * Bass (higher or lower bass. This effect uses SoX)
   * Overdrive (Distorts audio, much like setting a very high volume when encoding with ffmpeg. This effect uses SoX)
   * Stretch (Stretches audio, like speed, but it doesn't change the pitch. This effect uses SoX)
   * Reverse (Reverses audio. This effect uses SoX)
   * Pitch (Randomly changes the pitch of audio. This effect uses SoX)

For some reason, if the bot stays connected to a voice channel for a long time without activity, it "disconnects" from the voice channel (specifically the gateway or whatever), or it just times out.
This has not been fixed yet, but it will be fixed.

## Important note before using this fork of Alchemy

Basically none of the changes I've made have been documented in terms of developer documentation, so good luck using it :^)

The releases available on github are not guaranteed to be stable, or even working whatsoever, so use them and this fork at your own risk. Saying that though, if I've made a release that doesn't work, a release should come up shortly after that does actually work. The master branch should also not be considered stable.

This fork is made solely for me, with no regard for anyone else using it, therefore, if you'd like to know what changes were made in detail, go through all of the commits I've done.

## Original Description

A discord library / framework for elixir.

This library aims to provide a solid foundation, upon which to build
a simple, yet powerful interface. Unlike other libraries, this one comes
along with a framework for defining commands, and event hooks. No need
to mess around with consumers, or handlers, defining a command is as simple
as defining a function!


### Installation
Simply add *Alchemy* to your dependencies in your `mix.exs` file:
```elixir
def deps do
  [{:alchemy, "~> 0.6.4", hex: :discord_alchemy}]
end
```

### [Docs](https://hexdocs.pm/discord_alchemy/0.6.0)

This is the stable documentation for the library, I highly recommend going
through it, as most of the relevant information resides there.

### QuickStart
Run `mix alchemy.init` to generate a template bot file for your project.

### Getting Started
The first thing we need to do is define some kind of application for our bot.
Thankfully, the `Application` module encapsulates this need.
```elixir
defmodule MyBot do
  use Application
  alias Alchemy.Client


  defmodule Commands do
    use Alchemy.Cogs

    Cogs.def ping do
      Cogs.say "pong!"
    end
  end


  def start(_type, _args) do
    run = Client.start("your token here")
    use Commands
    run
  end
end
```
So we defined what we call a `Cog` in the `Commands` module, a cog
is simply a module that contains commands. To wire up this command into the bot,
we need to `use` the module, which we do after starting the client. We need
to provide a valid return type in `start/2`, which is why we capture the result
of `Client.start` in a variable.

Now all we need to do to wire up this application, is to add it to our `mix.exs`:
```elixir
def application do
  [mod: {MyBot, []}]
end
```
This makes our bot automatically start when we run our project.
Now, to run this project, we have 2 options:
 - use `mix run --no-halt` (the flags being necessary to
   prevent the app from ending once our `start/2` function finishes)
 - or use `iex -S mix` to start our application in the repl.

Starting the application in the repl is very advantageous, as it allows
 you to interact with the bot live.

### Using Voice
Alchemy also supports using Discord's Voice API to play audio.
We rely on [ffmpeg](https://ffmpeg.org/) for audio encoding,
as well as [youtube-dl](https://rg3.github.io/youtube-dl/) for streaming
audio from sites. Before the Voice API can be used, you'll need to acquire
the latest versions of those from their sites (make sure you get ffmpeg
with opus support), and then configure the path to those executables in
alchemy like so:
```
# in config.exs
config :alchemy,
  ffmpeg_path: "path/to/ffmpeg",
  youtube_dl_path: "path/to/youtube_dl"
```

Now you're all set to start playing some audio!

The first step is to connect to a voice channel with `Alchemy.Voice.join/2`,
then, you can start playing audio with `Alchemy.Voice.play_file/2`,
or `Alchemy.Voice.play_url/2`. Here's an example command to show off these
features:
```elixir
Cogs.def play(url) do
  {:ok, guild} = Cogs.guild()
  default_voice_channel = Enum.find(guild.channels, &match?(%{type: 2}, &1))
  # joins the default channel for this guild
  # this will check if a connection already exists for you
  Alchemy.Voice.join(guild.id, default_voice_channel.id)
  Alchemy.Voice.play_url(guild.id, url)
  Cogs.say "Now playing #{url}"
end
```

### Porcelain
Alchemy uses [`Porcelain`](https://github.com/alco/porcelain), to
help with managing external processes, to help save on memory usage,
you may want to use the `goon` driver, as suggested by `Porcelain`.
For more information, check out their GitHub.

# Other Examples
If you'd like to see a larger example of a bot using `Alchemy`,
checkout out [Viviani](https://github.com/cronokirby/viviani).
