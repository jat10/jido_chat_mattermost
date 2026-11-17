defmodule Jido.Chat.Mattermost.Transport do
  @moduledoc """
  Behaviour defining the HTTP transport contract for the Mattermost adapter.

  Implement this behaviour to swap out the real HTTP client with a test double
  without hitting a live Mattermost server.

  Upload preparation encodes one host-selected candidate without I/O. Upload
  submission makes one HTTP attempt using those exact bytes. No callback selects
  batches, applies failure policy, retries, creates continuations or returns
  delivery plans. Upload and publication failures are neutral atoms or
  `{:http_error, status}`, excluding credentials, response bodies and exceptions.
  An unconfirmed upload/publication may have affected the server; hosts own
  reconciliation and must not assume an error makes retry safe.
  """

  @callback send_message(channel_id :: String.t(), text :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Uploads exactly one supplied candidate. May materialize paths for convenience,
  but must never split it into multiple requests. Returns one unique server ID
  per input in `file_infos`, in input order, only after complete confirmation.
  Encoded request limits are independent of individual file size limits.
  """
  @callback upload_files(String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}

  @doc "Pure exact encoding of materialized files, with no filesystem/network I/O."
  @callback prepare_upload(String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}

  @doc "Uploads the exact prepared bytes once, returning ordered file_infos."
  @callback upload_prepared(map(), keyword()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks prepare_upload: 3, upload_prepared: 2

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
