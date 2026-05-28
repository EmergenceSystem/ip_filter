%%%-------------------------------------------------------------------
%%% @doc IP geolocation and network information agent.
%%%
%%% Looks up an IP address and returns its geolocation, ASN, ISP,
%%% and timezone via ipwho.is (free, no API key required).
%%%
%%% API: https://ipwho.is/{ip}
%%%
%%% Query: an IPv4 or IPv6 address, optionally prefixed with text
%%% ("ip 8.8.8.8", "lookup 2606:4700:4700::1111").
%%% If no valid IP is found in the query the raw query is used as-is
%%% (ipwho.is will return an error for invalid input).
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(ip_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(BASE_URL, "https://ipwho.is/").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"ip">>, <<"geolocation">>,
                                      <<"network">>, <<"asn">>,
                                      <<"isp">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case ip_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(ip_filter_query_listener),
    catch em_pop_sup:stop_node(ip_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(ip_filter, pop_port,   9446),
    QueryPort = application:get_env(ip_filter, query_port, 9447),
    Seeds     = application:get_env(ip_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(ip_filter),
    catch cowboy:stop_listener(ip_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(ip_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => ip_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(ip_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[ip_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Query processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Query, Timeout} = extract_params(JsonBinary),
    IP = extract_ip(Query),
    fetch_info(IP, Timeout).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Query = binary_to_list(maps:get(<<"value">>, Map,
                        maps:get(<<"query">>, Map, <<"">>))),
            Timeout = to_timeout(maps:get(<<"timeout">>, Map, undefined)),
            {Query, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

%% Extract IP address from a free-form query string.
%% Tries IPv4 pattern first, then IPv6, falls back to the raw query.
-spec extract_ip(string()) -> string().
extract_ip(Query) ->
    Stripped = string:trim(Query),
    case re:run(Stripped,
                "\\b(\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3})\\b",
                [{capture, all_but_first, list}]) of
        {match, [IP]} -> IP;
        nomatch ->
            %% Try to find an IPv6-looking token
            case re:run(Stripped, "([0-9a-fA-F:]{7,39})",
                        [{capture, all_but_first, list}]) of
                {match, [IP6]} -> IP6;
                nomatch        -> Stripped
            end
    end.

%%====================================================================
%% Fetch and parse
%%====================================================================

fetch_info("", _) -> [];
fetch_info(IP, Timeout) ->
    Url = lists:flatten(io_lib:format("~s~s", [?BASE_URL, IP])),
    case httpc:request(get, {Url, []},
                       [{timeout, Timeout * 1000},
                        {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} -> parse_info(Body);
        _                            -> []
    end.

parse_info(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"success">> := true} = Info ->
            [build_embryo(Info)];
        #{<<"success">> := false, <<"message">> := Msg} ->
            [error_embryo(Msg)];
        _ -> []
    catch
        _:_ -> []
    end.

build_embryo(Info) ->
    IP       = maps:get(<<"ip">>,        Info, <<"">>),
    Country  = maps:get(<<"country">>,   Info, <<"">>),
    Region   = maps:get(<<"region">>,    Info, <<"">>),
    City     = maps:get(<<"city">>,      Info, <<"">>),
    Lat      = maps:get(<<"latitude">>,  Info, null),
    Lon      = maps:get(<<"longitude">>, Info, null),
    Conn     = maps:get(<<"connection">>,Info, #{}),
    ASN      = maps:get(<<"asn">>,       Conn, null),
    ISP      = maps:get(<<"isp">>,       Conn, <<"">>),
    TZ       = maps:get(<<"timezone">>,  maps:get(<<"timezone">>, Info, #{}),
                        maps:get(<<"timezone">>, Info, <<"">>)),
    Type     = maps:get(<<"type">>,      Info, <<"">>),

    Title  = iolist_to_binary([IP, " — ", City, ", ", Region, ", ", Country]),
    Resume = build_resume(ISP, ASN, Lat, Lon, TZ, Type),
    Url    = iolist_to_binary(["https://ipwho.is/", IP]),

    #{<<"properties">> => #{
        <<"url">>     => Url,
        <<"title">>   => Title,
        <<"resume">>  => Resume,
        <<"source">>  => <<"ipwho.is">>
    }}.

build_resume(ISP, ASN, Lat, Lon, TZ, Type) ->
    Parts = lists:filtermap(fun
        ({_, <<>>})     -> false;
        ({_, null})     -> false;
        ({_, ""})       -> false;
        ({K, V}) when is_binary(V) ->
            {true, binary_to_list(K) ++ ": " ++ binary_to_list(V)};
        ({K, V}) when is_integer(V) ->
            {true, binary_to_list(K) ++ ": " ++ integer_to_list(V)};
        ({K, V}) when is_float(V) ->
            {true, binary_to_list(K) ++ ": " ++
                   lists:flatten(io_lib:format("~.4f", [V]))}
    end, [{<<"ISP">>, ISP}, {<<"ASN">>, ASN},
          {<<"lat">>, Lat}, {<<"lon">>, Lon},
          {<<"tz">>,  TZ},  {<<"type">>, Type}]),
    list_to_binary(string:join(Parts, " | ")).

error_embryo(Msg) ->
    #{<<"properties">> => #{
        <<"url">>    => <<"https://ipwho.is">>,
        <<"title">>  => <<"IP lookup error">>,
        <<"resume">> => Msg,
        <<"source">> => <<"ipwho.is">>
    }}.

%%====================================================================
%% Helpers
%%====================================================================

to_timeout(undefined)            -> 10;
to_timeout(T) when is_integer(T) -> T;
to_timeout(T) when is_binary(T)  ->
    try binary_to_integer(T) catch _:_ -> 10 end;
to_timeout(_) -> 10.
