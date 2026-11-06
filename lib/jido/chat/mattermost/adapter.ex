defmodule Jido.Chat.Mattermost.Adapter do
  @moduledoc """
  `Jido.Chat.Adapter` implementation for Mattermost.

  Uses the Mattermost REST API v4 via the injectable `Jido.Chat.Mattermost.Transport`
  behaviour.  The default transport is `Jido.Chat.Mattermost.Transport.ReqClient`.

  ## Configuration

  Set globally via application env:

      config :jido_chat_mattermost,
        url: "https://mattermost.example.com",
        token: "your-bot-token"

  Or pass per-call via `opts`:

      Adapter.send_message(channel_id, text, token: "...", url: "...")

  ## Ingress

  Mattermost ingress uses a persistent WebSocket connection. Start a listener
  via `Jido.Chat.Mattermost.Listener.child_spec/1` with a `sink_mfa` that
  receives normalized `%Incoming{}` structs.
  """

  use Jido.Chat.Adapter

  alias Jido.Chat.Mattermost.{
    DeleteOptions,
    EditOptions,
    FetchOptions,
    Listener,
    MetadataOptions,
    ReactionOptions,
    SendOptions,
    Transport.ReqClient,
    TypingOptions
  }

  alias Jido.Chat.{ChannelInfo, FileUpload, Media, MediaType, Mention, Response, Thread}

  # --- Adapter identity ---

  @impl true
  def channel_type, do: :mattermost

  @impl true
  def capabilities do
    %{
      initialize: :fallback,
      shutdown: :fallback,
      send_message: :native,
      send_file: :native,
      post_message: :native,
      multi_file: :native,
      edit_message: :native,
      edit_attachments: :native,
      delete_message: :native,
      start_typing: :native,
      fetch_metadata: :native,
      fetch_thread: :native,
      fetch_message: :native,
      fetch_media: :native,
      add_reaction: :native,
      remove_reaction: :native,
      fetch_messages: :native,
      fetch_channel_messages: :native,
      post_ephemeral: :unsupported,
      open_dm: :native,
      list_threads: :unsupported,
      open_modal: :unsupported,
      open_thread: :native,
      webhook: :unsupported,
      verify_webhook: :unsupported,
      post_channel_message: :fallback,
      stream: :fallback,
      parse_event: :unsupported,
      format_webhook_response: :unsupported
    }
  end

  # --- Incoming payload normalization ---

  @impl true
  def transform_incoming(%{"post" => post} = payload) when is_map(post) do
    text = Map.get(post, "message", "")
    user_id = Map.get(post, "user_id")
    channel_id = Map.get(post, "channel_id")
    post_id = Map.get(post, "id")
    root_id = nilify(Map.get(post, "root_id"))
    metadata = Map.get(post, "metadata", %{})

    channel_type = Map.get(payload, "channel_type")
    channel_display_name = Map.get(payload, "channel_display_name")

    media = extract_media(metadata)
    {was_mentioned, mentions} = extract_mentions(payload, post, text)

    bot_user_id = Application.get_env(:jido_chat_mattermost, :bot_user_id)

    {:ok,
     %{
       text: text,
       external_user_id: user_id,
       author: %{
         user_id: user_id || "",
         user_name: user_id || "",
         is_me: is_binary(user_id) && user_id == bot_user_id
       },
       external_room_id: channel_id,
       external_message_id: post_id,
       external_thread_id: root_id,
       chat_title: channel_display_name,
       chat_type: mattermost_channel_type(channel_type),
       media: media,
       was_mentioned: was_mentioned,
       mentions: mentions,
       raw: payload,
       channel_meta: %{
         adapter_name: :mattermost,
         external_room_id: channel_id,
         external_thread_id: root_id,
         chat_type: mattermost_channel_type(channel_type),
         chat_title: channel_display_name,
         is_dm: channel_type == "D"
       }
     }}
  end

  def transform_incoming(%{"channel_id" => channel_id, "user_id" => user_id} = payload)
      when is_binary(channel_id) and is_binary(user_id) do
    text = Map.get(payload, "text", "")
    post_id = Map.get(payload, "post_id")
    root_id = nilify(Map.get(payload, "root_id"))
    channel_type = Map.get(payload, "channel_type")
    channel_display_name = Map.get(payload, "channel_display_name")

    {:ok,
     %{
       text: text,
       external_user_id: user_id,
       external_room_id: channel_id,
       external_message_id: post_id,
       external_thread_id: root_id,
       chat_title: channel_display_name,
       chat_type: mattermost_channel_type(channel_type),
       media: [],
       was_mentioned: false,
       mentions: [],
       raw: payload,
       channel_meta: %{
         adapter_name: :mattermost,
         external_room_id: channel_id,
         external_thread_id: root_id,
         chat_type: mattermost_channel_type(channel_type),
         chat_title: channel_display_name,
         is_dm: channel_type == "D"
       }
     }}
  end

  def transform_incoming(_payload), do: {:error, :invalid_payload}

  # --- Send / Edit / Delete ---

  @impl true
  def send_message(channel_id, text, opts \\ []) do
    o = SendOptions.new(opts)

    with {:ok, result} <-
           transport(o).send_message(channel_id, text, SendOptions.transport_opts(o)) do
      {:ok, response_from_post(result, channel_id, :sent)}
    end
  end

  @impl true
  def send_file(channel_id, file, opts \\ []) do
    upload = FileUpload.normalize(file)
    o = SendOptions.new(opts)
    transport_opts = SendOptions.transport_opts(o)

    with {:ok, metadata, file_ids} <-
           upload_files(channel_id, [upload], transport(o), transport_opts),
         {:ok, post_result} <-
           transport(o).send_message(
             channel_id,
             upload_caption(upload, opts),
             Keyword.put(transport_opts, :file_ids, file_ids)
           ) do
      {:ok, upload_response(metadata, post_result, channel_id)}
    end
  end

  @impl true
  def post_message(channel_id, payload, opts \\ []) do
    files = Jido.Chat.PostPayload.upload_candidates(payload)
    text = Jido.Chat.PostPayload.display_text(payload) || ""

    case files do
      [] ->
        send_message(channel_id, text, opts)

      [file] ->
        send_file(channel_id, file, if(text == "", do: opts, else: Keyword.put(opts, :caption, text)))

      _ ->
        o = SendOptions.new(opts)
        transport_opts = SendOptions.transport_opts(o)

        with {:ok, metadata, ids} <- upload_files(channel_id, files, transport(o), transport_opts),
             {:ok, post} <- transport(o).send_message(channel_id, text, Keyword.put(transport_opts, :file_ids, ids)),
             :ok <- confirm_edited_files(post, ids) do
          response = response_from_post(post, channel_id, :sent)
          {:ok, %{response | metadata: edit_response_metadata(response.metadata, post, metadata, %{})}}
        end
    end
  end

  @doc """
  Edits a post, optionally replacing its attachments through `files: uploads`.
  Text-only edits reconcile attachments from the server response. When called through
  `SentMessage`, `:previous_metadata` preserves omitted details for matching file IDs.
  File edits reuse the upload path and update
  the existing post; upload/edit errors never fall back to creating another post.
  As with send_file, an upload can remain stored if the subsequent edit fails.
  """
  @impl true
  def edit_message(channel_id, post_id, text, opts \\ []) do
    o = EditOptions.new(opts)

    with {:ok, transport_opts, attachment_metadata} <- edit_file_opts(channel_id, o),
         {:ok, result} <- transport(o).edit_message(channel_id, post_id, text, transport_opts),
         :ok <- confirm_edited_files(result, transport_opts[:file_ids]) do
      response = response_from_post(result, channel_id, :edited, post_id)

      {:ok,
       %{
         response
         | metadata: edit_response_metadata(response.metadata, result, attachment_metadata, o.previous_metadata)
       }}
    end
  end

  defp edit_file_opts(_channel_id, %EditOptions{files: []} = o),
    do: {:ok, EditOptions.transport_opts(o), nil}

  defp edit_file_opts(channel_id, %EditOptions{files: files} = o) when is_list(files) do
    opts = EditOptions.transport_opts(o)

    with {:ok, metadata, ids} <- upload_files(channel_id, files, transport(o), opts) do
      {:ok, Keyword.put(opts, :file_ids, ids), metadata}
    end
  end

  defp edit_response_metadata(metadata, post, nil, previous) do
    file_ids = map_get(post, ["file_ids", :file_ids])
    files = post |> map_get(["metadata", :metadata]) |> map_get(["files", :files])

    if is_list(file_ids) or is_list(files) do
      Map.merge(metadata, post_file_metadata(files, file_ids, previous))
    else
      metadata
    end
  end

  defp edit_response_metadata(metadata, post, attachment_metadata, _previous) do
    reconciled = edit_response_metadata(metadata, post, nil, attachment_metadata)

    attachment_metadata
    |> Map.merge(reconciled)
    |> Map.put(:upload, attachment_metadata.upload)
    |> Map.put(:upload_kind, attachment_metadata.upload_kind)
  end

  defp post_file_metadata(files, file_ids, previous) do
    media = post_file_media(files, file_ids, previous)
    first = List.first(media)
    file_ids = Enum.map(media, & &1.metadata[:file_id]) |> Enum.reject(&is_nil/1)

    first_id = List.first(file_ids)
    first_info = Enum.find(List.wrap(files), &(map_get(&1, [:id, "id"]) == first_id))

    previous_type =
      if first_id != nil and first_id == map_get(previous, [:file_id, "file_id"]),
        do: map_get(previous, [:content_type, "content_type"])

    content_type =
      get_non_blank(first_info || %{}, ["mime_type", :mime_type]) || previous_type || (first && first.media_type)

    %{
      media: media,
      attachments: Enum.map(media, &Jido.Chat.Attachment.normalize/1),
      file_id: List.first(file_ids),
      file_ids: file_ids,
      filename: first && first.filename,
      size: first && first.size_bytes,
      content_type: content_type,
      delivered_kind: first && first.kind,
      upload_kind: nil,
      upload: nil
    }
  end

  defp post_file_media(files, file_ids, previous) do
    files = if is_list(files), do: Enum.filter(files, &is_map/1), else: []
    known = previous |> map_get([:media, "media"]) |> List.wrap()

    previous_by_id =
      Map.new(known, fn media ->
        id = media |> map_get([:metadata, "metadata"]) |> map_get([:file_id, "file_id"])

        {id,
         %{
           "id" => id,
           "name" => map_get(media, [:filename, "filename"]),
           "mime_type" => map_get(media, [:media_type, "media_type"]),
           "size" => map_get(media, [:size_bytes, "size_bytes"]),
           "width" => map_get(media, [:width, "width"]),
           "height" => map_get(media, [:height, "height"])
         }}
      end)

    first_id = map_get(previous, [:file_id, "file_id"])

    flat = %{
      "name" => map_get(previous, [:filename, "filename"]),
      "mime_type" => map_get(previous, [:content_type, "content_type"]),
      "size" => map_get(previous, [:size, "size"])
    }

    previous_by_id =
      Map.update(previous_by_id, first_id, flat, fn details ->
        Map.merge(flat, Map.reject(details, fn {_key, value} -> is_nil(value) end))
      end)

    current_by_id = Map.new(files, &{map_get(&1, [:id, "id"]), &1})
    ids = if is_list(file_ids), do: file_ids, else: Enum.map(files, &map_get(&1, [:id, "id"]))

    Enum.map(ids, fn id ->
      prior = if is_nil(id), do: %{}, else: Map.get(previous_by_id, id, %{})
      current = Map.get(current_by_id, id, %{"id" => id})
      current = Map.new(current, fn {key, value} -> {to_string(key), value} end)
      normalize_file_media(Map.merge(prior, Map.reject(current, fn {_key, value} -> is_nil(value) end)))
    end)
  end

  defp confirm_edited_files(_result, nil), do: :ok

  defp confirm_edited_files(result, ids) do
    if Enum.all?(ids, &(&1 in (map_get(result, ["file_ids", :file_ids]) || []))),
      do: :ok,
      else: {:error, :unconfirmed_delivery}
  end

  @impl true
  def delete_message(channel_id, post_id, opts \\ []) do
    o = DeleteOptions.new(opts)
    transport(o).delete_message(channel_id, post_id, DeleteOptions.transport_opts(o))
  end

  # --- Typing ---

  @impl true
  def start_typing(channel_id, opts \\ []) do
    o = TypingOptions.new(opts)
    transport(o).send_typing(channel_id, TypingOptions.transport_opts(o))
  end

  # --- Metadata ---

  @impl true
  def fetch_metadata(channel_id, opts \\ []) do
    o = MetadataOptions.new(opts)

    with {:ok, channel} <-
           transport(o).fetch_channel(channel_id, MetadataOptions.transport_opts(o)) do
      {:ok,
       ChannelInfo.new(%{
         id: stringify(channel["id"] || channel_id),
         name: channel["display_name"] || channel["name"],
         is_dm: channel["type"] == "D",
         member_count: channel["member_count"],
         metadata: channel
       })}
    end
  end

  # --- Thread / Message fetch ---

  @impl true
  def fetch_thread(root_id, opts \\ []) do
    o = FetchOptions.new(opts)

    with {:ok, thread} <- transport(o).fetch_thread(root_id, FetchOptions.transport_opts(o)) do
      {:ok,
       Thread.new(%{
         id: default_thread_id(nil, root_id),
         adapter_name: :mattermost,
         adapter: __MODULE__,
         external_room_id: opts[:channel_id],
         external_thread_id: root_id,
         channel_id: opts[:channel_id],
         metadata: thread
       })}
    end
  end

  @impl true
  def fetch_message(_channel_id, post_id, opts \\ []) do
    o = FetchOptions.new(opts)
    transport(o).fetch_post(post_id, FetchOptions.transport_opts(o))
  end

  @impl true
  def fetch_media(reference, opts \\ []) do
    o = FetchOptions.new(opts)

    with {:ok, file_id} <- media_file_id(reference) do
      transport(o).download_file(file_id, FetchOptions.transport_opts(o))
    end
  end

  @impl true
  def open_thread(channel_id, post_id, opts \\ []) do
    o = FetchOptions.new(opts)

    with {:ok, post} <- transport(o).fetch_post(post_id, FetchOptions.transport_opts(o)) do
      external_thread_id = nilify(post["root_id"]) || stringify(post["id"]) || stringify(post_id)

      {:ok,
       Thread.new(%{
         id: default_thread_id(channel_id, external_thread_id),
         adapter_name: :mattermost,
         adapter: __MODULE__,
         external_room_id: channel_id,
         external_thread_id: external_thread_id,
         channel_id: channel_id,
         metadata: %{root_post: post}
       })}
    end
  end

  # --- Reactions ---

  @impl true
  def add_reaction(_channel_id, post_id, emoji, opts \\ []) do
    o = ReactionOptions.new(opts)
    transport(o).add_reaction(post_id, emoji, ReactionOptions.transport_opts(o))
  end

  @impl true
  def remove_reaction(_channel_id, post_id, emoji, opts \\ []) do
    o = ReactionOptions.new(opts)
    user_id = o.user_id || raise ":user_id is required for remove_reaction"
    transport(o).remove_reaction(post_id, emoji, user_id, ReactionOptions.transport_opts(o))
  end

  # --- Message history ---

  @impl true
  def fetch_messages(channel_id, opts \\ []) do
    o = FetchOptions.new(opts)
    transport(o).fetch_posts(channel_id, FetchOptions.transport_opts(o))
  end

  @impl true
  def fetch_channel_messages(channel_id, opts \\ []) do
    fetch_messages(channel_id, opts)
  end

  # --- User profile ---

  @impl true
  def get_user(user_id, opts \\ []) do
    o = FetchOptions.new(opts)

    with {:ok, user} <- transport(o).get_user(user_id, FetchOptions.transport_opts(o)) do
      display_name =
        [user["first_name"], user["last_name"]]
        |> Enum.reject(&(is_nil(&1) || &1 == ""))
        |> Enum.join(" ")
        |> case do
          "" -> user["username"]
          name -> name
        end

      {:ok, Map.put(user, "display_name", display_name)}
    end
  end

  # --- DM channel ---

  @doc "Opens or returns the existing DM channel between the bot and a target user."
  def open_dm_channel(bot_user_id, target_user_id, opts \\ []) do
    o = FetchOptions.new(opts)
    transport(o).open_dm_channel(bot_user_id, target_user_id, FetchOptions.transport_opts(o))
  end

  @impl true
  def open_dm(target_user_id, opts \\ []) do
    bot_user_id =
      Keyword.get(opts, :bot_user_id) || Application.get_env(:jido_chat_mattermost, :bot_user_id)

    with bot_user_id when is_binary(bot_user_id) and bot_user_id != "" <- bot_user_id,
         {:ok, channel} <- open_dm_channel(bot_user_id, target_user_id, opts),
         channel_id when is_binary(channel_id) and channel_id != "" <- channel["id"] do
      {:ok, channel_id}
    else
      nil -> {:error, :bot_user_id_required}
      "" -> {:error, :bot_user_id_required}
      {:error, _} = error -> error
      _ -> {:error, :invalid_dm_channel}
    end
  end

  # --- Listener / ingress ---

  @impl true
  def listener_child_specs(bridge_id, opts) do
    opts = Keyword.put_new(opts, :bridge_id, bridge_id)
    {:ok, [Listener.child_spec(opts)]}
  end

  # --- Private helpers ---

  defp transport(%{transport: mod}) when not is_nil(mod), do: mod
  defp transport(_), do: ReqClient

  defp default_thread_id(nil, external_thread_id), do: "mattermost:thread:#{external_thread_id}"

  defp default_thread_id(channel_id, external_thread_id),
    do: "mattermost:#{channel_id}:#{external_thread_id}"

  defp extract_media(%{"files" => files}) when is_list(files),
    do: normalize_file_media_list(files)

  defp extract_media(_), do: []

  defp normalize_file_media_list(files) do
    files
    |> Enum.map(&normalize_file_media/1)
    |> Enum.reject(&is_nil/1)
  end

  defp response_from_post(post, channel_id, status, fallback_post_id \\ nil) do
    Response.new(%{
      external_message_id: map_get(post, ["id", :id]) || fallback_post_id,
      external_room_id: map_get(post, ["channel_id", :channel_id]) || channel_id,
      channel_type: :mattermost,
      status: status,
      raw: post,
      metadata: %{
        root_id: nilify(map_get(post, ["root_id", :root_id])),
        source_author_id: map_get(post, ["user_id", :user_id])
      }
    })
  end

  defp normalize_file_media(file) when is_map(file) do
    file_id = map_get(file, ["id", :id])

    url =
      get_non_blank(file, ["link", :link, "permalink", :permalink]) ||
        media_reference_url(file_id)

    filename = get_non_blank(file, ["name", :name])
    extension = get_non_blank(file, ["extension", :extension])

    media_type =
      MediaType.resolve(map_get(file, ["mime_type", :mime_type]), filename: filename) ||
        media_type_from_extension(extension) ||
        MediaType.from_filename(url)

    Media.new(%{
      kind: MediaType.kind(media_type),
      url: url,
      filename: filename,
      media_type: media_type,
      size_bytes: map_get(file, ["size", :size]),
      width: map_get(file, ["width", :width]),
      height: map_get(file, ["height", :height]),
      metadata:
        %{
          file_id: file_id,
          extension: extension
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    })
  end

  defp normalize_file_media(_), do: nil

  defp media_type_from_extension(extension) when is_binary(extension) do
    extension
    |> String.trim()
    |> String.trim_leading(".")
    |> then(&MediaType.from_filename("file." <> &1))
  end

  defp media_type_from_extension(_extension), do: nil

  defp get_non_blank(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) -> if(String.trim(value) == "", do: nil, else: value)
        _other -> nil
      end
    end)
  end

  defp media_file_id(%Media{url: url, metadata: metadata}) do
    metadata
    |> map_get([:file_id, "file_id"])
    |> file_id_or_reference(url)
  end

  defp media_file_id(reference) when is_map(reference) do
    metadata = map_get(reference, [:metadata, "metadata"]) || %{}

    reference
    |> map_get([:file_id, "file_id", :id, "id"])
    |> Kernel.||(map_get(metadata, [:file_id, "file_id"]))
    |> file_id_or_reference(map_get(reference, [:url, "url", :link, "link", :permalink, "permalink"]))
  end

  defp media_file_id(reference) when is_binary(reference), do: parse_media_reference(reference)
  defp media_file_id(_reference), do: {:error, :invalid_media_reference}

  defp file_id_or_reference(file_id, _reference) when is_binary(file_id) and file_id != "",
    do: validate_file_id(file_id)

  defp file_id_or_reference(_file_id, reference) when is_binary(reference),
    do: parse_media_reference(reference)

  defp file_id_or_reference(_file_id, _reference), do: {:error, :invalid_media_reference}

  defp parse_media_reference("mattermost://file/" <> file_id), do: validate_file_id(file_id)

  defp parse_media_reference(reference) do
    case URI.parse(reference) do
      %URI{scheme: scheme, path: path} when scheme in ["http", "https"] ->
        file_id_from_api_path(path)

      %URI{scheme: nil, path: path} ->
        validate_file_id(path)

      _uri ->
        {:error, :invalid_media_reference}
    end
  end

  defp file_id_from_api_path(path) when is_binary(path) do
    case Regex.run(~r{/api/v4/files/([^/]+)$}, path, capture: :all_but_first) do
      [file_id] -> validate_file_id(file_id)
      _no_match -> {:error, :invalid_media_reference}
    end
  end

  defp file_id_from_api_path(_path), do: {:error, :invalid_media_reference}

  defp validate_file_id(file_id) when is_binary(file_id) do
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, file_id) do
      {:ok, file_id}
    else
      {:error, :invalid_media_reference}
    end
  end

  defp media_reference_url(file_id) when is_binary(file_id) and file_id != "",
    do: "mattermost://file/#{file_id}"

  defp media_reference_url(_file_id), do: nil

  defp upload_files(channel_id, files, transport, opts) do
    uploads = FileUpload.normalize_many(files)

    inputs =
      uploads
      |> Enum.reduce_while({:ok, []}, fn upload, {:ok, inputs} ->
        case upload_input(upload) do
          {:ok, input} -> {:cont, {:ok, [input | inputs]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, inputs} <- inputs,
         {:ok, result} <- transport.upload_files(channel_id, Enum.reverse(inputs), opts),
         {:ok, ids} <- uploaded_file_ids_result(result),
         :ok <- confirm_batch_upload(ids, length(files)) do
      # Batch file details come from the response, never from positional input pairing.
      metadata =
        case uploads do
          [upload] -> upload_metadata(upload, result)
          _ -> upload_metadata(%FileUpload{}, result) |> Map.put(:upload_kind, nil)
        end

      {:ok, metadata, ids}
    end
  end

  defp confirm_batch_upload(ids, count) do
    if length(ids) == count and length(Enum.uniq(ids)) == count and
         Enum.all?(ids, &(is_binary(&1) and &1 != "")),
       do: :ok,
       else: {:error, :unconfirmed_upload}
  end

  defp upload_input(%FileUpload{path: path} = upload) when is_binary(path) and path != "" do
    {:ok,
     %{
       path: path,
       filename: upload.filename || Path.basename(path),
       content_type: upload.media_type
     }}
  end

  defp upload_input(%FileUpload{data: data, filename: filename} = upload)
       when is_binary(data) and data != "" and is_binary(filename) and filename != "" do
    {:ok, %{body: data, filename: filename, content_type: upload.media_type}}
  end

  defp upload_input(%FileUpload{data: data}) when is_binary(data) and data != "" do
    {:error, :missing_filename}
  end

  defp upload_input(%FileUpload{url: url}) when is_binary(url) and url != "" do
    {:error, :unsupported_remote_url}
  end

  defp upload_input(_upload), do: {:error, :missing_file_source}

  defp upload_caption(%FileUpload{} = upload, opts) do
    metadata = upload.metadata

    [
      opts[:caption],
      opts[:text],
      metadata[:caption],
      metadata["caption"],
      metadata[:alt_text],
      metadata["alt_text"],
      metadata[:transcript],
      metadata["transcript"]
    ]
    |> first_present()
    |> Kernel.||("")
  end

  defp first_present(values) do
    Enum.find(values, fn
      value when value in [nil, ""] -> false
      _value -> true
    end)
  end

  defp uploaded_file_ids(upload_result) do
    upload_result
    |> uploaded_file_infos()
    |> Enum.map(&(map_get(&1, ["id", :id]) || &1))
    |> Enum.reject(&is_nil/1)
  end

  defp uploaded_file_ids_result(upload_result) do
    case uploaded_file_ids(upload_result) do
      [] -> {:error, :missing_uploaded_file_id}
      file_ids -> {:ok, file_ids}
    end
  end

  defp uploaded_file_infos(%{"file_infos" => file_infos}) when is_list(file_infos), do: file_infos
  defp uploaded_file_infos(%{file_infos: file_infos}) when is_list(file_infos), do: file_infos
  defp uploaded_file_infos(file_infos) when is_list(file_infos), do: file_infos
  defp uploaded_file_infos(_), do: []

  defp uploaded_media(upload_result, upload) do
    defaults = %{"name" => upload.filename, "mime_type" => upload.media_type, "size" => upload.size_bytes}

    upload_result
    |> uploaded_file_infos()
    |> Enum.map(fn info ->
      fields = Map.new(info, fn {key, value} -> {to_string(key), value} end)
      Map.merge(defaults, Map.reject(fields, fn {_key, value} -> is_nil(value) end))
    end)
    |> normalize_file_media_list()
  end

  defp upload_response(metadata, post_result, channel_id) do
    Response.new(%{
      external_message_id: map_get(post_result, ["id", :id]),
      external_room_id: map_get(post_result, ["channel_id", :channel_id]) || channel_id,
      timestamp: map_get(post_result, ["create_at", :create_at]),
      channel_type: :mattermost,
      status: :sent,
      raw: post_result,
      metadata:
        metadata
        |> Map.put(:source_author_id, map_get(post_result, ["user_id", :user_id]))
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    })
  end

  defp upload_metadata(%FileUpload{} = upload, upload_result) do
    file_info = upload_result |> uploaded_file_infos() |> List.first()

    media = uploaded_media(upload_result, upload)

    # Keep nil values so replacement edits clear details known only for the old file.
    %{
      media: media,
      attachments: Enum.map(media, &Jido.Chat.Attachment.normalize/1),
      file_id: map_get(file_info, ["id", :id]),
      file_ids: uploaded_file_ids(upload_result),
      filename: map_get(file_info, ["name", :name]) || upload.filename,
      size: map_get(file_info, ["size", :size]) || upload.size_bytes,
      content_type: map_get(file_info, ["mime_type", :mime_type]) || upload.media_type,
      upload_kind: upload.kind,
      delivered_kind: delivered_kind(upload, file_info),
      upload: upload_result
    }
  end

  defp delivered_kind(%FileUpload{} = upload, file_info) do
    media_type = map_get(file_info, ["mime_type", :mime_type]) || upload.media_type

    case media_type do
      <<"image/", _::binary>> -> :image
      <<"audio/", _::binary>> -> :audio
      <<"video/", _::binary>> -> :video
      _ -> upload.kind
    end
  end

  defp map_get(nil, _keys), do: nil

  defp map_get(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp nilify(v) when v in [nil, ""], do: nil
  defp nilify(v), do: v

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: to_string(v)

  defp mattermost_channel_type("D"), do: :dm
  defp mattermost_channel_type("P"), do: :private
  defp mattermost_channel_type("O"), do: :public
  defp mattermost_channel_type(_), do: :channel

  defp extract_mentions(_payload, post, text) do
    bot_name = Application.get_env(:jido_chat_mattermost, :bot_name)
    bot_user_id = Application.get_env(:jido_chat_mattermost, :bot_user_id)

    user_ids =
      post
      |> Map.get("props", %{})
      |> Map.get("mentions", [])
      |> List.wrap()

    was_mentioned =
      (bot_name && String.contains?(text, "@#{bot_name}")) ||
        (bot_user_id && bot_user_id in user_ids) ||
        user_ids != []

    mentions =
      Enum.map(user_ids, fn uid ->
        %Mention{
          user_id: uid,
          is_self: uid == bot_user_id,
          mention_text: "@#{uid}"
        }
      end)

    {was_mentioned, mentions}
  end
end
