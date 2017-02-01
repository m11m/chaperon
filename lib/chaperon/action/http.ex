defmodule Chaperon.Action.HTTP do
  @moduledoc """
  HTTP based actions to be run in a `Chaperon.Scenario` module for a given
  `Chaperon.Session`.

  This supports `GET`, `POST`, `PUT`, `PATCH`, `DELETE` & `HEAD` requests with
  support for optional headers & query params.
  """

  defstruct [
    method: :get,
    path: nil,
    headers: %{},
    params: %{},
    response: nil,
    body: nil
  ]

  @type method :: :get | :post | :put | :patch | :delete | :head

  @type t :: %Chaperon.Action.HTTP{
    method: method,
    path: String.t,
    headers: map,
    params: map,
    response: HTTPoison.Response.t | HTTPoison.AsyncResponse.t,
    body: binary
  }

  def get(path, params) do
    %Chaperon.Action.HTTP{
      method: :get,
      path: path,
      params: params
    }
  end

  def post(path, opts) do
    %Chaperon.Action.HTTP{
      method: :post,
      path: path
    }
    |> add_options(opts)
  end

  def put(path, opts)  do
    %Chaperon.Action.HTTP{
      method: :put,
      path: path
    }
    |> add_options(opts)
  end

  def patch(path, opts) do
    %Chaperon.Action.HTTP{
      method: :patch,
      path: path
    }
    |> add_options(opts)
  end

  def delete(path, opts \\ []) do
    %Chaperon.Action.HTTP{
      method: :delete,
      path: path
    }
    |> add_options(opts)
  end

  alias __MODULE__
  alias Chaperon.Session

  def url(%{path: "/"}, %Session{config: %{base_url: base_url}}) do
    base_url
  end

  def url(%{path: path}, %Session{config: %{base_url: base_url}}) do
    base_url <> path
  end

  def url(%{path: path}, _), do: path

  def full_url(action = %HTTP{method: method, params: params}, session) do
    url = url(action, session)
    case method do
      :get -> url <> query_params_string(params)
      _    -> url
    end
  end

  def metrics_url(action, session) do
    if session.config[:skip_metrics_in_query_params] do
      action
      |> url(session)
    else
      action
      |> full_url(session)
    end
  end

  def full_path(%{path: path, params: params}),
    do: path <> query_params_string(params)

  def query_params_string([]),
    do: ""
  def query_params_string(params),
    do: "?" <> URI.encode_query(params)

  def options(action, session) do
    session.config
    |> Map.get(:http, %{})
    |> Enum.into([])
    |> Keyword.merge(params: action.params)
  end

  def add_options(action, opts) do
    alias Keyword, as: KW
    import Map, only: [merge: 2]

    headers = opts[:headers] || %{}
    params  = opts[:params] || %{}

    {new_headers, body} =
      opts
      |> KW.delete(:headers)
      |> KW.delete(:params)
      |> parse_body

    headers = action.headers |> merge(headers) |> merge(new_headers)

    %{ action |
      headers: headers,
      params: params,
      body: body
    }
  end

  defp parse_body([]), do: {%{}, ""}
  defp parse_body(json: data) when is_list(data) do
    data = if Keyword.keyword?(data) do
      data |> Enum.into(%{})
    else
      data
    end

    data
    |> json_body
  end

  defp parse_body(json: data), do: data |> json_body
  defp parse_body(form: data), do: data |> form_body

  defp json_body(data) do
    {
      %{"Content-Type": "application/json"},
      data |> Poison.encode!
    }
  end

  defp form_body(data) do
    {
      %{"Content-Type": "x-www-form-urlencoded"},
      data |> URI.encode_query
    }
  end
end

defimpl Chaperon.Actionable, for: Chaperon.Action.HTTP do
  alias Chaperon.Action.Error
  alias Chaperon.Action.HTTP
  alias Chaperon.Session
  import Chaperon.Timing
  require Logger

  def run(action, session) do
    url = HTTP.full_url(action, session)
    Logger.info "#{action.method |> to_string |> String.upcase} #{url}"

    start = timestamp
    case HTTPoison.request(
      action.method,
      url,
      action.body || "",
      action.headers,
      HTTP.options(action, session)
    ) do
      {:ok, response} ->
        Logger.debug "HTTP Response #{action} : #{response.status_code}"
        session
        |> Session.assign(last_action: action)
        |> Session.add_result(action, response)
        |> Session.add_metric([:duration, action.method, action |> HTTP.metrics_url(session)], timestamp - start)
        |> Session.ok

      {:error, reason} ->
        Logger.error "HTTP action #{action} failed: #{inspect reason}"
        {:error, %Error{reason: reason, action: action, session: session}}
    end
  end

  def abort(action, session) do
    # TODO
    {:ok, action, session}
  end
end

defimpl String.Chars, for: Chaperon.Action.HTTP do
  alias Chaperon.Action.HTTP

  @methods [:get, :post, :put, :patch, :delete, :head]
  @method_strings @methods
                  |> Enum.map(&{&1, &1 |> Kernel.to_string |> String.upcase})
                  |> Enum.into(%{})


  def to_string(http) do
    "#{@method_strings[http.method]} #{HTTP.full_url(http, %{})}"
  end
end
