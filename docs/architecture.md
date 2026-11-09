# Architecture — jido_chat_mattermost

This document describes how the Mattermost adapter is structured and how data flows
through it at runtime.

---

## Package role

`jido_chat_mattermost` is a platform adapter. It bridges Mattermost (a self-hosted
chat server) to the `jido_chat` SDK. It owns:

- **Ingress** — receiving messages from Mattermost via WebSocket
- **Egress** — sending messages and performing actions via Mattermost REST API v4
- **Normalization** — translating between Mattermost-native payloads and `jido_chat`
  typed structs (`%Incoming{}`, `%Response{}`, `%ChannelInfo{}`, etc.)

It does **not** own:
- Runtime supervision trees (that is the caller's responsibility)
- Message routing or handler dispatch (owned by `jido_chat` / `Jido.Chat`)
- Persistence or queueing (e.g. Oban — accepted as an opaque opt)

---

## Module map

```
Jido.Chat.Mattermost
│
├── Adapter               ← use Jido.Chat.Adapter
│                           Normalization + all egress callbacks
│
├── Channel               ← Compatibility shim (delegates to Adapter)
│
├── Listener              ← WebSocket supervisor entry point
│                           child_spec/1, start_link/1
│
├── WebSocket/
│   └── Client            ← Fresh-based WS frame handler
│                           handle_connect/3, handle_in/2
│
├── Transport             ← @behaviour (HTTP contract)
│   └── ReqClient         ← Production Req-based implementation
│
├── SendOptions           ← Unused (dead code — see adapter_violations.md #8)
├── MetadataOptions       ← Unused (dead code — see adapter_violations.md #8)
└── FetchOptions          ← Unused (dead code — see adapter_violations.md #8)
```

---

## Ingress flow (WebSocket)

```
Mattermost server
  │  (WebSocket frame, JSON)
  ▼
Jido.Chat.Mattermost.WebSocket.Client
  │  handle_connect/3 → sends authentication_challenge
  │  handle_in/2      → decodes frame, filters non-"posted" events
  │
  ├─ filter: bot self-message?      → drop
  ├─ filter: channel not in allowlist? → drop
  │
  ▼  raw payload map
  invoke_sink/3
  │  apply(module, function, extra_args ++ [raw_payload, sink_opts])
  │
  ▼  (caller's responsibility)
  Adapter.transform_incoming/1
  │  → %Jido.Chat.Incoming{}
  ▼
  Jido.Chat.process_message/5  (or equivalent in caller)
```

**Key invariant:** `WebSocket.Client` never transforms payloads. It is a raw
dispatcher. All normalization happens in the sink or adapter layer above it.

### Sink MFA

```elixir
sink_mfa = {MyModule, :handle_incoming, [extra_arg]}
sink_opts = [transport: "websocket", bridge_id: "mattermost_1", ...]

# Client calls:
apply(MyModule, :handle_incoming, [extra_arg, raw_payload, sink_opts])
```

The sink receives the raw Mattermost `%{"post" => ..., "channel_type" => ...}` map.

---

## Egress flow (REST API)

```
Caller
  │  Jido.Chat.Adapter.send_message(Adapter, room_id, text, opts)
  ▼
Jido.Chat.Mattermost.Adapter.send_message/3
  │  transport(opts).send_message(channel_id, text, transport_opts(opts))
  ▼
Jido.Chat.Mattermost.Transport.ReqClient   (or test double)
  │  POST /api/v4/posts
  ▼
Mattermost REST API v4
```

All egress callbacks follow the same pattern:
1. Resolve transport module from opts (default: `ReqClient`)
2. Delegate to `transport(opts).callback(...)`
3. Return `{:ok, response_map}` or `{:error, term()}`

The `Jido.Chat.Adapter` module-level functions normalize the returned map into
typed structs (`%Response{}`, `%ChannelInfo{}`, etc.) before returning to the caller.

---

## Transport swapping (test double)

```elixir
# In tests:
defmodule FakeTransport do
  @behaviour Jido.Chat.Mattermost.Transport

  @impl true
  def send_message(_channel_id, _text, _opts), do: {:ok, %{"id" => "fake-post-id"}}
  # ... implement all callbacks
end

Adapter.send_message(channel_id, "hello", transport: FakeTransport, ...)
```

Never mock at the HTTP layer. Always swap the transport module.

The `transport` option also accepts the full module name produced by JSON
serialization, such as `"Elixir.MyTransport"`. The adapter resolves it to an
existing atom immediately before transport dispatch. Unknown names raise
`ArgumentError`; they do not create atoms or fall back to the production
transport. The SDK leaves this adapter-specific option value unchanged.

Transports supporting uploads must implement `upload_files/3`, accepting a list
even for a single file. The former `upload_file/3` callback is no longer called.
The adapter owns individual file-size validation, the ten-attachment post limit,
and delivery reporting. The transport owns encoded-body sizing and HTTP batching;
one upload callback can make several requests, returning ordered file results
only after all succeed. `ReqClient` keeps its multipart sizing private.
See the [file-upload migration guide](../README.md#file-upload-migration-breaking-changes)
for the request and response contract.

---

## Multiple instances

Each `Listener` is identified by `bridge_id`. The child spec `id` is
`{Jido.Chat.Mattermost.Listener, bridge_id}`, allowing multiple Mattermost servers
(or bot accounts) to run concurrently on the same node:

```elixir
children = [
  Listener.child_spec(bridge_id: "mm_prod", url: ..., token: ..., sink_mfa: ...),
  Listener.child_spec(bridge_id: "mm_staging", url: ..., token: ..., sink_mfa: ...)
]
```

---

## Configuration

Global defaults (lowest priority):

```elixir
config :jido_chat_mattermost,
  url: "https://mattermost.example.com",
  token: "your-bot-token"
```

Per-call opts override globals:

```elixir
Adapter.send_message(channel_id, text, url: "...", token: "...", transport: MyTransport)
```

File uploads additionally require a positive integer `max_file_size` in bytes,
advertised by `configurable_max_file_size: :native` in the adapter capability matrix,
resolved from per-call options before application configuration. Set it to the
server's `FileSettings.MaxFileSize`; it is not discovered automatically. This is
required for single-file sends, multiple-file posts, and attachment edits.
Text-only operations do not require it. See the
[README configuration example](../README.md#configuration).

Call `Adapter.validate_files/2` before materialization to check declared sizes.
It accepts lazy file maps/structs with `name` or `filename` and `size` (also accepted
inside `metadata`), using atom or string keys. It returns `:ok` or the first
validation error, including filename, size and limit for an oversized file.
Unknown sizes are rejected. This adapter extension does no file or network I/O;
delivery still validates actual bytes.
