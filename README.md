# Jido Chat Mattermost

`jido_chat_mattermost` is the Mattermost adapter package for `jido_chat`.

## Release Status

This package is being prepared for the Jido 1.x chat package release line. It is part of the Elixir implementation aligned to the Vercel Chat SDK ([chat-sdk.dev/docs](https://www.chat-sdk.dev/docs)).

`Jido.Chat.Mattermost.Adapter` is the canonical adapter module and uses `Req` as the HTTP transport against the Mattermost REST API v4.

`Jido.Chat.Mattermost.Channel` is kept as a compatibility wrapper for legacy `Jido.Chat.Channel` integrations.

## Installation

```elixir
def deps do
  [
    {:jido_chat, github: "agentjido/jido_chat", branch: "main"},
    {:jido_chat_mattermost, github: "agentjido/jido_chat_mattermost", branch: "main"}
  ]
end
```

## Configuration

Token and base URL can be provided per-call via opts or set globally.
File uploads also require `max_file_size`, a positive integer in bytes matching
your Mattermost server's `FileSettings.MaxFileSize`. This applies to single-file
sends, multiple-file posts, and attachment edits. Text-only sends and edits do
not require it.

For an application that uploads files, configure:

```elixir
# config/runtime.exs
config :jido_chat_mattermost,
  url: "https://mattermost.yourcompany.com",
  token: System.get_env("MATTERMOST_BOT_TOKEN"),
  max_file_size: System.fetch_env!("MATTERMOST_MAX_FILE_SIZE") |> String.to_integer()
```

Set `MATTERMOST_MAX_FILE_SIZE` in your application's environment to the server's
limit in bytes. This example explicitly reads that environment variable; the
adapter itself reads per-call options first, then application configuration.
It does not discover the server limit automatically. Local size validation
rejects oversized files before upload; server-side errors still propagate if
the server configuration changes.

## Usage

```elixir
alias Jido.Chat.Mattermost.Adapter

# Normalize an inbound Mattermost event payload
{:ok, incoming} =
  Adapter.transform_incoming(%{
    "post" => %{
      "id" => "abc123",
      "channel_id" => "ch001",
      "user_id" => "usr001",
      "message" => "@zaq what is the leave policy?",
      "root_id" => ""
    },
    "channel_display_name" => "general",
    "channel_type" => "O"
  })

# Send a reply
{:ok, sent} = Adapter.send_message("ch001", "Here is the leave policy...", token: "my-token")

# Reply in a thread
{:ok, sent} = Adapter.send_message("ch001", "reply text", token: "my-token", thread_id: "root-post-id")

# Upload and send a file (the limit can also come from global configuration)
{:ok, sent} =
  Adapter.send_file("ch001",
    %{path: "/tmp/report.pdf", filename: "report.pdf", media_type: "application/pdf"},
    token: "my-token",
    max_file_size: System.fetch_env!("MATTERMOST_MAX_FILE_SIZE") |> String.to_integer(),
    caption: "Latest report"
  )

# Download an inbound attachment
[media | _] = incoming.media
{:ok, bytes} = Adapter.fetch_media(media, token: "my-token")

# Edit a message
{:ok, updated} = Adapter.edit_message("ch001", "post-id", "updated text", token: "my-token")

# Delete a message
{:ok, _} = Adapter.delete_message("ch001", "post-id", token: "my-token")

# Add a reaction
:ok = Adapter.add_reaction("ch001", "post-id", "white_check_mark", token: "my-token")

# Remove a reaction
:ok = Adapter.remove_reaction("ch001", "post-id", "white_check_mark", token: "my-token", user_id: "usr001")

# Fetch last 10 messages
{:ok, page} = Adapter.fetch_messages("ch001", limit: 10, token: "my-token")

# Fetch a specific post
{:ok, message} = Adapter.fetch_message("ch001", "post-id", token: "my-token")

# Fetch a thread by root post ID
{:ok, thread} = Adapter.fetch_thread("root-post-id", token: "my-token")

# Look up a user (returns the Mattermost user map with a synthesized "display_name" key)
{:ok, user} = Adapter.get_user("usr001", token: "my-token")

# Open (or retrieve) a DM channel between the bot and a user
{:ok, channel} = Adapter.open_dm_channel("bot-user-id", "target-user-id", token: "my-token")
```

## Ingress (WebSocket Listener)

Mattermost ingress uses a **persistent WebSocket connection** (`/api/v4/websocket`).
`listener_child_specs/2` returns a child spec for `Jido.Chat.Mattermost.Listener`, which
wraps a Fresh-based WebSocket client. Add it to your supervision tree:

```elixir
children = [
  Jido.Chat.Mattermost.Listener.child_spec(
    bridge_id: :my_bot,
    url: "https://mattermost.yourcompany.com",
    token: System.get_env("MATTERMOST_BOT_TOKEN"),
    bot_user_id: "bot-user-id",
    bot_name: "zaq",
    channel_ids: :all,                            # or a list of channel ID strings
    sink_mfa: {MyApp.Handler, :handle_incoming, []}
  )
]
```

Each incoming WebSocket event is normalized to a `%Jido.Chat.Incoming{}` struct and
delivered via `sink_mfa`. Multiple Mattermost instances can coexist on the same node
by using distinct `bridge_id` values.

## Transport

The default HTTP transport is `Jido.Chat.Mattermost.Transport.ReqClient`. Swap it out
for tests by injecting a module that implements the `Jido.Chat.Mattermost.Transport`
behaviour:

```elixir
Adapter.send_message("ch001", "hello", transport: MyFakeTransport, token: "x")
```

### File-upload migration (breaking changes)

Existing integrations must make two changes when adopting multiple-file delivery:

1. **Configure `max_file_size` for every upload path.** Calls to `send_file/3`
   that previously needed only authentication now also need this setting, either
   in per-call options or application configuration as shown above. The same
   requirement applies when posting or editing attachments through the SDK.
   Missing configuration returns `{:error, {:missing_configuration, :max_file_size}}`;
   values other than positive integers return
   `{:error, {:invalid_configuration, :max_file_size}}`. Both fail before upload.
2. **Update custom transports from `upload_file/3` to `upload_files/3`.** The
   adapter's public `send_file/3` API remains available, but it now calls the
   plural transport callback with a one-element list. There is no fallback to
   the old singular callback. The bundled `Transport.ReqClient` already implements
   the new contract.

For a custom transport, replace `upload_file(channel_id, file, opts)` with
`upload_files(channel_id, files, opts)`. Each call supplies the files for one post;
the transport owns request encoding, sizing, and splitting them into HTTP requests
using `opts[:max_file_size]`. Each input map contains `:body` or `:path`, plus
`:filename` and `:content_type`. Return `{:ok, %{"file_infos" => infos}}` with one entry per
input, in request order, each containing a unique server `"id"`. Preserve this
order even when filenames are duplicated; the adapter uses it to associate
missing server details with the corresponding upload. Return `{:error, reason}`
on failure, stopping further requests and returning no partial success. Previously
uploaded files can remain stored after a later request fails. The post response must confirm a nonempty message ID and all uploaded
file IDs before the adapter reports successful delivery.

See [the adapter reference](docs/jido_chat_adapter.md#multiple-file-posts-and-edits)
for batching and delivery-report behavior.

## Capability Matrix

| Capability | Status |
|---|---|
| send message | native |
| edit message | native |
| delete message | native |
| start typing | native |
| fetch channel metadata | native |
| fetch thread | native |
| fetch message by ID | native |
| fetch media | native |
| add reaction | native |
| remove reaction | native |
| fetch messages (history) | native |
| fetch channel messages | native |
| open DM channel | native |
| post ephemeral message | unsupported |
| list threads | unsupported |
| modal | unsupported |
| webhook ingress | unsupported |
| send file | native |

Downloading private attachments requires the bot to have permission to read the
channel containing the file.

### Attachment MIME policy

Requires `jido_chat` 1.2.1 or newer. Incoming file metadata uses the shared
`Jido.Chat.MediaType` resolver: valid provider MIME takes precedence, followed by
best-effort hints from the filename, Mattermost file-info extension, then URL path
(ignoring query parameters). Provider MIME is canonicalized to lowercase without
parameters; blank and invalid values are treated as absent. Explicit document or
`application/octet-stream` MIME is not overridden by an image-like filename.

Unknown formats keep `media_type: nil` and `kind: :file`. There is no Mattermost-wide
image default, no normalization-time download, and no transcoding. The original
event remains in `Incoming.raw`; file IDs and provider extension remain in media
metadata. `fetch_media/2` returns the original downloaded bytes without decoding
the response body.

## Testing and coverage

`mix test` runs unit tests without a Mattermost server. Tests tagged `:integration`
are excluded by default.

The CI coverage job starts disposable PostgreSQL and Mattermost service containers,
waits for Mattermost readiness, and runs `.github/scripts/bootstrap_mattermost.py`
to create an account, team, channel, and attached file. Credentials are generated
per run, the session token is masked in Actions logs, and no stored Mattermost
secrets are required. The bootstrap script is intended only for a fresh, isolated
test server, not an existing deployment. Service containers are removed after the job.

To include integration tests against your own test instance, set `MATTERMOST_URL`,
`MATTERMOST_TOKEN`, `MATTERMOST_CHANNEL_ID`, and `MATTERMOST_FILE_ID` (an existing
attachment readable by that user), then run:

```sh
MIX_ENV=test mix coveralls.cobertura --include integration
```

The MIME integration audit uploads JPEG, PNG, GIF, WebP, and text-document fixtures
through both path-backed and byte-backed uploads. It checks the upload and fetched
post file-info MIME, incoming normalization, and byte-for-byte download equality.
The fixture sources are documented in `test/fixtures/README.md`.

CI uploads the combined `cover/cobertura.xml` report to Codecov and as an Actions
artifact, even if the 95% coverage gate fails. CI runs the full test suite once,
in the coverage job; the separate quality job does not start service containers.

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
