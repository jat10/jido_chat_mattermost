defmodule Jido.Chat.Mattermost.Transport do
  @moduledoc """
  Behaviour defining the HTTP transport contract for the Mattermost adapter.

  Implement this behaviour to swap out the real HTTP client with a test double
  without hitting a live Mattermost server.

  With `attachment_failure_policy: :continue | :abort`, upload and publication
  callbacks return transport-neutral failure reasons: a non-nil atom (such as
  `:timeout` or `:econnrefused`) or `{:http_error, status}` for HTTP statuses
  100..599. Use `:transport_exception` for raised exceptions, `:transport_exit`
  for exits, and `:attachment_delivery_failed` for unclassified failures.
  Never include response bodies, credentials, or HTTP-library exception structs
  in policy-mode failures. Partial upload results retain their confirmed prefix
  and put the neutral reason in `partial_upload.reason`.

  The adapter forwards the normalized policy to upload and publication callbacks.
  Calls without an explicit policy retain their legacy error results. To sanitize
  structured reports from those calls, the adapter also accepts `{status, body}`
  and generic `%{reason: reason}` envelopes, recursively keeping only the neutral
  category and discarding every other field. Custom transports can use these
  envelopes without coupling the adapter to their exception types.
  """

  @callback send_message(channel_id :: String.t(), text :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Uploads files, returning one `file_infos` entry per input in the same order.

  Each entry must contain a unique server file ID. Optional server details take
  precedence over the corresponding input's metadata. Preserve request order so
  sparse responses can be correlated without relying on filenames being unique.

  The adapter supplies the files for one post and `opts[:max_file_size]` in bytes.
  The transport owns encoded request sizing and may split them into multiple HTTP
  requests. Return success only after all uploads are confirmed; stop and return
  an error if a request fails or returns incomplete results. Uploaded files may
  remain stored after a later request fails. Do not create posts here.

  With `attachment_failure_policy: :continue | :abort`, retain confirmed earlier
  batches in `{:error, {:partial_upload, %{reason: reason, uploaded: result}}}`.
  `result.file_infos` contains only the confirmed input prefix, in order. The
  adapter decides whether to publish it; never retry a failed batch here.
  """
  @callback upload_files(channel_id :: String.t(), files :: [map()], opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback download_file(file_id :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @callback edit_message(
              channel_id :: String.t(),
              post_id :: String.t(),
              text :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, map()} | {:error, term()}

  @callback delete_message(channel_id :: String.t(), post_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback add_reaction(post_id :: String.t(), emoji :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback remove_reaction(
              post_id :: String.t(),
              emoji :: String.t(),
              user_id :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, map()} | {:error, term()}

  @callback fetch_posts(channel_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback fetch_post(post_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback fetch_thread(root_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback fetch_channel(channel_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback send_typing(channel_id :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback get_user(user_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback open_dm_channel(
              bot_user_id :: String.t(),
              target_user_id :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, map()} | {:error, term()}
end
