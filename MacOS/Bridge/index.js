const { PassThrough } = require("node:stream");
const {
  AudioPlayerStatus,
  NoSubscriberBehavior,
  StreamType,
  VoiceConnectionStatus,
  createAudioPlayer,
  createAudioResource,
  entersState,
  joinVoiceChannel,
} = require("@discordjs/voice");
const { Client, GatewayIntentBits } = require("discord.js");

const token = process.env.DISCORD_TOKEN;
if (!token) {
  console.error("DISCORD_TOKEN is not set.");
  process.exit(1);
}

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.GuildVoiceStates,
    GatewayIntentBits.MessageContent,
  ],
});

const player = createAudioPlayer({
  behaviors: { noSubscriber: NoSubscriberBehavior.Play },
});
let connection = null;
let pcmStream = null;

function control(action, application) {
  process.stdout.write(`${JSON.stringify({ action, application })}\n`);
}

process.stdin.on("data", (chunk) => {
  if (pcmStream) pcmStream.write(chunk);
});
process.stdin.resume();

client.once("ready", () => {
  console.error(`Discord voice bridge logged in as ${client.user.tag}.`);
});

client.on("messageCreate", async (message) => {
  if (message.author.bot || !message.guild || !message.content.startsWith("!")) return;

  const [command, ...arguments] = message.content.slice(1).trim().split(/\s+/);

  if (command === "stream") {
    const voiceChannel = message.member?.voice?.channel;
    if (!voiceChannel) {
      await message.reply("You need to be in a voice channel first.");
      return;
    }
    if (connection) {
      await message.reply("Already streaming. Use `!stopstream` first.");
      return;
    }

    const application = arguments.join(" ") || "DuckDuckGo";
    try {
      connection = joinVoiceChannel({
        channelId: voiceChannel.id,
        guildId: voiceChannel.guild.id,
        adapterCreator: voiceChannel.guild.voiceAdapterCreator,
        selfDeaf: true,
        selfMute: false,
      });
      await entersState(connection, VoiceConnectionStatus.Ready, 30_000);

      pcmStream = new PassThrough({ highWaterMark: 3840 * 10 });
      const resource = createAudioResource(pcmStream, { inputType: StreamType.Raw });
      connection.subscribe(player);
      player.play(resource);

      // Tell Swift to begin producing PCM before waiting for the player. A raw
      // resource cannot enter Playing until its first audio bytes arrive.
      control("start", application);
      await entersState(player, AudioPlayerStatus.Playing, 10_000);

      await message.reply(`Streaming **${application}** into **${voiceChannel.name}**.`);
    } catch (error) {
      console.error(error);
      control("stop");
      pcmStream?.destroy();
      pcmStream = null;
      connection?.destroy();
      connection = null;
      await message.reply(`Failed to start streaming: ${error.message}`);
    }
  }

  if (command === "stopstream") {
    if (!connection) {
      await message.reply("Not currently streaming.");
      return;
    }

    control("stop");
    player.stop(true);
    pcmStream?.destroy();
    pcmStream = null;
    connection.destroy();
    connection = null;
    await message.reply("Stopped streaming.");
  }
});

async function shutdown() {
  control("stop");
  player.stop(true);
  pcmStream?.destroy();
  connection?.destroy();
  client.destroy();
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

client.login(token).catch((error) => {
  console.error(error);
  process.exit(1);
});
