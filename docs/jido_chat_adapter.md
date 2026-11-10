# Jido.Chat Adapter — Callback Reference

This document is the authoritative reference for implementing `Jido.Chat.Adapter`
callbacks in `jido_chat_mattermost`. Read this before adding or changing any adapter
callbacks.

Source of truth: `deps/jido_chat/lib/jido/chat/adapter.ex`

---

## What is `Jido.Chat.Adapter`?

`Jido.Chat.Adapter` is a behaviour (interface contract) defined by the `jido_chat`
SDK. Any platform adapter (Mattermost, Slack, Telegram, …) implements this behaviour
to plug into the `jido_chat` runtime.

The SDK exposes **module-level wrapper functions** (e.g. `Jido.Chat.Adapter.send_message/4`)
that:
1. Delegate to the adapter callback
2. Normalize the returned value into a typed struct
3. Apply fallbacks when a callback is absent

Adapter callbacks only need to return the raw platform response — normalization is
handled upstream.

---

## Declaring the behaviour

```elixir
defmodule Jido.Chat.Mattermost.Adapter do
  use Jido.Chat.Adapter
  # ↑ adds @behaviour Jido.Chat.Adapter
  # ↑ provides default channel_type/0 (last module segment, underscored)

  @impl true
  def channel_type, do: :mattermost  # override the default
end
```

---

## Required callbacks

These must always be implemented. There are no fallbacks.

### `channel_type/0`

```elixir
@impl true
def channel_type, do: :mattermost
```

Returns the atom identifier for this platform. Used as the `adapter_name` key
throughout `jido_chat` (e.g. in `Thread.id`, `Incoming.adapter_name`).

---

### `transform_incoming/1`

```elixir
@callback transform_incoming(raw_payload :: map()) ::
  {:ok, Incoming.t() | map()} | {:error, term()}
```

Normalizes a raw Mattermost payload into a `%Jido.Chat.Incoming{}` struct.

**Arity is 1.** The SDK calls `adapter_module.transform_incoming(payload)`.
An `opts \\ []` default is permitted for local use but the contract is arity-1.

Incoming payload shape from WebSocket:
```elixir
%{
  "post" => %{
    "id" => "post-id",
    "user_id" => "user-id",
    "channel_id" => "channel-id",
    "message" => "Hello",
    "root_id" => ""        # non-empty means thread reply
  },
  "channel_type" => "O",   # "O"=public, "P"=private, "D"=DM
  "channel_display_name" => "town-square"
}
```

Must return a map with at minimum:
- `external_room_id` — Mattermost channel ID
- `external_message_id` — Mattermost post ID
- `text` — message text
- `author` — `%Author{user_id: user_id, ...}`

---

### `send_message/3`

```elixir
@callback send_message(external_room_id(), text :: String.t(), opts :: keyword()) ::
  {:ok, Response.t() | map()} | {:error, term()}
```

Posts a message to a channel. Return `{:ok, map}` — the SDK normalizes it into
`%Response{}`. The map should include `"id"` (Mattermost post ID) so the SDK
can set `external_message_id`.

---

## Optional callbacks

Implement only what `capabilities/0` declares as `:native`.

### `capabilities/0`

```elixir
@callback capabilities() :: %{optional(atom()) => :native | :fallback | :unsupported}
```

Declares what this adapter supports. If absent, the SDK auto-detects via
`function_exported?`. When present, your declaration wins — but it must be
coherent (see Validation below).

Capability key → callback mapping:

| Key | Callback | Arity |
|---|---|---|
| `:initialize` | `initialize` | 1 |
| `:shutdown` | `shutdown` | 1 |
| `:send_message` | `send_message` | 3 |
| `:edit_message` | `edit_message` | 4 |
| `:edit_attachments` | `edit_message` (accepts `files: [FileUpload.t()]`) | 4 |
| `:delete_message` | `delete_message` | 3 |
| `:start_typing` | `start_typing` | 2 |
| `:fetch_metadata` | `fetch_metadata` | 2 |
| `:fetch_thread` | `fetch_thread` | 2 |
| `:fetch_message` | `fetch_message` | 3 |
| `:fetch_media` | `fetch_media` | 2 |
| `:add_reaction` | `add_reaction` | 4 |
| `:remove_reaction` | `remove_reaction` | 4 |
| `:post_ephemeral` | `post_ephemeral` | 4 |
| `:open_dm` | `open_dm` | 2 |
| `:fetch_messages` | `fetch_messages` | 2 |
| `:fetch_channel_messages` | `fetch_channel_messages` | 2 |
| `:list_threads` | `list_threads` | 2 |
| `:post_channel_message` | `post_channel_message` | 3 |
| `:stream` | `stream` | 3 |
| `:open_modal` | `open_modal` | 3 |
| `:webhook` | `handle_webhook` | 3 |
| `:verify_webhook` | `verify_webhook` | 2 |
| `:parse_event` | `parse_event` | 2 |
| `:format_webhook_response` | `format_webhook_response` | 2 |

> **Note:** The key for `handle_webhook/3` is `:webhook`, not `:handle_webhook`.

---

### `initialize/1` and `shutdown/1`

```elixir
@callback initialize(opts :: keyword()) :: :ok | {:ok, term()} | {:error, term()}
@callback shutdown(opts :: keyword())   :: :ok | {:ok, term()} | {:error, term()}
```

Lifecycle hooks. Called by `Jido.Chat.initialize/1` and `Jido.Chat.shutdown/1`.
Both return `:ok` by default when absent.

---

### `edit_message/4`

```elixir
@callback edit_message(room_id, msg_id, text :: String.t(), opts) ::
  {:ok, Response.t() | map()} | {:error, term()}
```

Fallback: `{:error, :unsupported}`

---

### `delete_message/3`

```elixir
@callback delete_message(room_id, msg_id, opts) ::
  :ok | {:ok, term()} | {:error, term()}
```

The SDK normalizes `:ok` and `{:ok, _}` both to `:ok`.
Fallback: `{:error, :unsupported}`

---

### `start_typing/2`

```elixir
@callback start_typing(room_id, opts) :: :ok | {:ok, term()} | {:error, term()}
```

Fallback: `{:error, :unsupported}`

---

### `fetch_metadata/2`

```elixir
@callback fetch_metadata(room_id, opts) ::
  {:ok, ChannelInfo.t() | map()} | {:error, term()}
```

Fallback: returns a minimal `%ChannelInfo{id: room_id}`.

---

### `fetch_thread/2`

```elixir
@callback fetch_thread(room_id, opts) ::
  {:ok, Thread.t() | map()} | {:error, term()}
```

Fallback: returns a minimal `%Thread{id: "mattermost:#{room_id}"}`.

---

### `fetch_message/3`

```elixir
@callback fetch_message(room_id, msg_id, opts) ::
  {:ok, Message.t() | Incoming.t() | map()} | {:error, term()}
```

Fallback: `{:error, :unsupported}`

---

### `fetch_media/2`

```elixir
@callback fetch_media(reference :: String.t() | Media.t() | map(), opts) ::
  {:ok, binary()} | {:error, term()}
```

Fetches the raw bytes behind an inbound media reference minted by the adapter.
Mattermost accepts a raw file ID, a `mattermost://file/<file_id>` reference, a
normalized media value carrying `metadata.file_id`, or a Mattermost
`/api/v4/files/<file_id>` URL. Fallback: `{:error, :unsupported}`.

---

### `add_reaction/4` and `remove_reaction/4`

```elixir
@callback add_reaction(room_id, msg_id, emoji :: String.t(), opts) ::
  :ok | {:ok, term()} | {:error, term()}

@callback remove_reaction(room_id, msg_id, emoji :: String.t(), opts) ::
  :ok | {:ok, term()} | {:error, term()}
```

Fallback: `{:error, :unsupported}`

---

### `post_ephemeral/4`

```elixir
@callback post_ephemeral(room_id, user_id, text :: String.t(), opts) ::
  {:ok, EphemeralMessage.t() | map()} | {:error, term()}
```

Fallback: if `open_dm/2` is implemented and `opts[:fallback_to_dm]` is `true`,
the SDK opens a DM and sends the message there. Otherwise `{:error, :unsupported}`.

---

### `open_dm/2`

```elixir
@callback open_dm(user_id, opts) :: {:ok, external_room_id()} | {:error, term()}
```

Returns the DM channel ID. Fallback: `{:error, :unsupported}`

---

### `post_channel_message/3`

```elixir
@callback post_channel_message(room_id, text :: String.t(), opts) ::
  {:ok, Response.t() | map()} | {:error, term()}
```

Fallback: delegates to `send_message/3`.

---

### `stream/3`

```elixir
@callback stream(room_id, chunks :: Enumerable.t(), opts) ::
  {:ok, Response.t() | map()} | {:error, term()}
```

Fallback: `Enum.join(chunks, "")` then `send_message/3`.

---

### `open_modal/3`

```elixir
@callback open_modal(room_id, payload :: map(), opts) ::
  {:ok, ModalResult.t() | map()} | {:error, term()}
```

Fallback: `{:error, :unsupported}`

---

### `fetch_messages/2` and `fetch_channel_messages/2`

```elixir
@callback fetch_messages(room_id, opts) ::
  {:ok, MessagePage.t() | map()} | {:error, term()}

@callback fetch_channel_messages(room_id, opts) ::
  {:ok, MessagePage.t() | map()} | {:error, term()}
```

`opts` is pre-normalized to `FetchOptions` keyword list by the SDK before being
passed to the callback. Fallback: `{:error, :unsupported}`

---

### `list_threads/2`

```elixir
@callback list_threads(room_id, opts) ::
  {:ok, ThreadPage.t() | map()} | {:error, term()}
```

Fallback: `{:error, :unsupported}`

---

### `handle_webhook/3`

```elixir
@callback handle_webhook(chat :: Jido.Chat.t(), raw_payload :: map(), opts) ::
  {:ok, Jido.Chat.t(), Incoming.t()} | {:error, term()}
```

Capability key: `:webhook` (not `:handle_webhook`).

Fallback: calls `transform_incoming/1` then `Jido.Chat.process_message/5`.

---

### `verify_webhook/2`

```elixir
@callback verify_webhook(WebhookRequest.t() | map(), opts) ::
  :ok | {:error, term()}
```

Fallback: `:ok` (permissive — no verification).

---

### `parse_event/2`

```elixir
@callback parse_event(WebhookRequest.t() | map(), opts) ::
  {:ok, EventEnvelope.t() | map() | :noop | nil} | {:error, term()}
```

Return `:noop` or `nil` for events that should be silently ignored.

Fallback: calls `transform_incoming/1` and wraps the result in an `%EventEnvelope{}`.

---

### `format_webhook_response/2`

```elixir
@callback format_webhook_response(result, opts) ::
  WebhookResponse.t() | map() | {:ok, WebhookResponse.t() | map()} | {:error, term()}
```

Fallback: `WebhookResponse.accepted(%{ok: true})` on success,
`WebhookResponse.error(400, ...)` on error, `WebhookResponse.error(401, ...)` on
`:invalid_webhook_secret`.

---

### `listener_child_specs/2`

```elixir
@callback listener_child_specs(bridge_id :: String.t(), opts :: keyword()) ::
  {:ok, [Supervisor.child_spec()]} | {:error, term()}
```

Expected opts keys (provided by the runtime, opaque to the adapter):
- `:sink_mfa` — `{module, function, extra_args}`
- `:bridge_id` — same as the first argument
- `:bridge_config` — resolved config struct/map
- `:instance_module` — runtime instance module
- `:settings` — adapter-specific ingress settings
- `:ingress` — normalized ingress mode/settings

Return `{:ok, []}` for webhook-only mode (no persistent listener needed).
Return `{:error, {:unsupported_ingress_mode, mode}}` for unknown modes.

---

## Validation

```elixir
# In your adapter test:
test "capability matrix is coherent" do
  assert :ok = Jido.Chat.Adapter.validate_capabilities(Jido.Chat.Mattermost.Adapter)
end
```

`validate_capabilities/1` iterates all declared capabilities and verifies that every
`:native` entry has an exported callback of the correct arity. It returns
`{:error, {:invalid_capability_matrix, [...missing...]}}` on failure.

---

## Normalization done by the SDK (not the adapter)

The module-level functions in `Jido.Chat.Adapter` normalize adapter responses so
adapter callbacks can return plain maps:

| Adapter returns | SDK normalizes to |
|---|---|
| `map` from `transform_incoming/1` | `%Incoming{}` via `Incoming.new/1` |
| `map` from `send_message/3` | `%Response{}` via `Response.new/1` |
| `map` from `fetch_metadata/2` | `%ChannelInfo{}` via `ChannelInfo.new/1` |
| `map` from `fetch_thread/2` | `%Thread{}` via `Thread.new/1` |
| `map` from `fetch_message/3` | `%Message{}` via `Message.new/1` or `Message.from_incoming/2` |
| `map` from `post_ephemeral/4` | `%EphemeralMessage{}` |
| `map` from `open_modal/3` | `%ModalResult{}` |
| `map` from `fetch_messages/2` | `%MessagePage{}` |
| `map` from `parse_event/2` | `%EventEnvelope{}` |

Adapters should NOT construct these structs manually — just return the platform's
raw map and let the SDK normalize it.

### Attachment state after edits

`SentMessage.edit/3` supplies the handle's metadata merged with its latest delivery
response in `:previous_metadata`; response values take precedence.
Mattermost uses it only to fill missing file details for matching file IDs;
the returned file IDs still determine attachment membership and order.
Text-only edit responses publish an explicit `metadata.attachments` list so the
SDK refreshes its attachment list, including clearing it after external removal.
An absent attachment snapshot leaves the SDK's existing fallback behavior intact.

### Multiple-file posts and edits

The adapter declares `post_message: :native` and `multi_file: :native`.
It also declares `attachment_failure_policy: :native`, independently of message
and attachment editing. Existing send, post and attachment-edit callbacks accept
`attachment_failure_policy: :continue | :abort`. Omitting it retains the legacy
delivery behavior described below.

With `:abort`, every planned file upload completes before the first post or update;
any preflight/upload failure returns an error without final publication. With
`:continue`, usable uploads are published and failures are reported; an entirely
failed file selection publishes text once. Successful uploads are reused within
the invocation. No public upload/publish handoff or retry is involved.

Policy-mode delivery reports additionally retain `uploaded_files`, separate from
confirmed `messages`. Failures before publication return
`{:error, {:attachment_delivery_failed, report}}` with `delivery: :not_sent`;
uncertain publication uses `delivery: :unconfirmed`. Later publication failure can
leave earlier confirmed posts, reported as a partial success. Strict mode does not
make multiple post publication atomic, and orphaned uploads may remain.
Use `Postable.text("Caption", files: uploads)` with `Thread.post/3` or
`ChannelRef.post/3` to attach multiple files to one post, or with
`SentMessage.edit/3` to replace the attachments on the existing post.
An empty upload list performs a text-only edit; it does not remove attachments.

**Breaking migration:** existing single-file callers must now configure
`max_file_size`, and custom transports must replace `upload_file/3` with
`upload_files/3`. There is no fallback to the old callback. See the
[README migration guide](../README.md#file-upload-migration-breaking-changes)
for configuration examples and the transport migration contract.

File delivery requires a positive integer `max_file_size` in bytes, supplied in per-call options or
`config :jido_chat_mattermost, max_file_size: ...`. Set it to the server's
`FileSettings.MaxFileSize`. Missing or invalid configuration returns
`{:error, {:missing_configuration | :invalid_configuration, :max_file_size}}`
before uploading; text-only sends and edits do not require this option.

The adapter checks actual byte/file sizes before uploading and partitions valid
files into posts of at most ten attachments. Oversized files are omitted and
reported individually; an entirely rejected selection returns an error. Other
invalid file sources fail preflight before any upload.

The adapter calls `Transport.upload_files/3` once per post's attachment group.
Each transport owns its request encoding, sizing, and HTTP batching. `ReqClient`
measures its encoded multipart bodies, including headers, and plans all requests
before uploading, fitting the configured limit plus Mattermost v10's 512-byte
multipart allowance. Large valid files can upload separately while their IDs
are attached to the same post. Custom transports must implement this callback
using their own encoding rules; the adapter does not call Req's sizing helper.
The callback returns success only after every batch is confirmed and stops on
the first HTTP failure or incomplete upload response. Its combined `file_infos`
response must contain one unique server file ID per input, in request order,
so per-upload fallback metadata remains associated with the correct file.
For a supplied failure policy, a later failed HTTP batch returns the confirmed
input prefix as `{:error, {:partial_upload, %{reason: reason, uploaded: result}}}`.
Only earlier fully confirmed batches appear in `result.file_infos`, in input
order. The adapter can publish that prefix in continue mode without reuploading;
strict mode reports it without publication. No failed HTTP batch is retried.

The first post contains the supplied text. Continuations contain
`Additional files (2/2).` (with the actual indices) and reply under the first
post, or under the existing thread root. For an attachment edit, the first part
updates the existing message and subsequent parts become thread replies.

The SDK still returns one `SentMessage`, bound to the first confirmed post. When
multiple posts or rejected/pending files are involved, its response metadata has
`delivery_report: %{confirmation: :confirmed | :partial, messages: [...],
failed_files: [...]}`. Each confirmed message includes its `message_id`, `body`,
`thread_id`, `action`, `confirmation`, `delivery_part_index`, and attachment
`metadata`. Consumers must record these as separate messages. Ordinary successful
single-post sends retain their existing response shape.

A later upload/post failure stops delivery. The report preserves confirmed posts
and marks files in the failed part as unconfirmed and later files as not attempted.
A first-part failure returns an error. No automatic retries occur; orphaned uploads
can remain stored after failures. Per-file rejections include filename, actual
size, configured limit, and reason.

Structured `failed_files` entries use neutral atom reasons or `{:http_error, status}`,
including upload failures and failed or pending publication parts. They retain
per-file stage and delivery certainty without raw response bodies or transport
exception structs. Legacy top-level `{:error, reason}` results keep their original
internal reason; this normalization applies only to structured delivery reports.
Upload failures have `stage: :upload`; entries without a more precise stage
default to `:transport`.

Server configuration can change after preflight. HTTP failures still propagate.
Metadata contains ordered `file_ids`, `media`, and attachment snapshots; singular
metadata fields describe the first file for compatibility.
