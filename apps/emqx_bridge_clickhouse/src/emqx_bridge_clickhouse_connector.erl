%%--------------------------------------------------------------------
%% Copyright (c) 2023-2024 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_clickhouse_connector).

-include_lib("emqx_connector/include/emqx_connector.hrl").
-include_lib("emqx_resource/include/emqx_resource.hrl").
-include_lib("typerefl/include/types.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("hocon/include/hoconsc.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-behaviour(emqx_resource).

-import(hoconsc, [mk/2, enum/1, ref/2]).

%%=====================================================================
%% Exports
%%=====================================================================

%% Hocon config schema exports
-export([
    roots/0,
    fields/1,
    values/1,
    namespace/0
]).

%% callbacks for behaviour emqx_resource
-export([
    resource_type/0,
    callback_mode/0,
    on_start/2,
    on_stop/2,
    on_add_channel/4,
    on_remove_channel/3,
    on_get_channel_status/3,
    on_get_channels/1,
    on_query/3,
    on_batch_query/3,
    on_get_status/2,
    on_format_query_result/1
]).

%% callbacks for ecpool
-export([connect/1]).

%% Internal exports used to execute code with ecpool worker
-export([
    execute_sql_in_clickhouse_server_using_connection/2
]).

%%=====================================================================
%% Types
%%=====================================================================

-type url() :: emqx_http_lib:uri_map().
-reflect_type([url/0]).
-typerefl_from_string({url/0, emqx_http_lib, uri_parse}).

-type templates() ::
    #{}
    | #{
        send_message_template := term(),
        extend_send_message_template := term()
    }.

-type state() ::
    #{
        channels => #{binary() => templates()},
        templates := templates(),
        pool_name := binary(),
        connect_timeout := pos_integer()
    }.

-type clickhouse_config() :: map().

%%=====================================================================
%% Configuration and default values
%%=====================================================================

namespace() -> clickhouse.

roots() ->
    [{config, #{type => hoconsc:ref(?MODULE, config)}}].

fields(config) ->
    [
        {url,
            hoconsc:mk(
                url(),
                #{
                    required => true,
                    validator => fun
                        (#{query := _Query}) ->
                            {error, "There must be no query in the url"};
                        (_) ->
                            ok
                    end,
                    desc => ?DESC("base_url")
                }
            )},
        {connect_timeout,
            hoconsc:mk(
                emqx_schema:timeout_duration_ms(),
                #{
                    default => <<"15s">>,
                    desc => ?DESC("connect_timeout")
                }
            )}
    ] ++ emqx_connector_schema_lib:relational_db_fields().

values(post) ->
    maps:merge(values(put), #{name => <<"connector">>});
values(get) ->
    values(post);
values(put) ->
    #{
        database => <<"mqtt">>,
        enable => true,
        pool_size => 8,
        type => clickhouse,
        url => <<"http://127.0.0.1:8123">>
    };
values(_) ->
    #{}.

%% ===================================================================
%% Callbacks defined in emqx_resource
%% ===================================================================
resource_type() -> clickhouse.

callback_mode() -> always_sync.

%% -------------------------------------------------------------------
%% on_start callback and related functions
%% -------------------------------------------------------------------

-spec on_start(resource_id(), clickhouse_config()) -> {ok, state()} | {error, _}.

on_start(
    InstanceID,
    #{
        url := URL,
        database := DB,
        pool_size := PoolSize,
        connect_timeout := ConnectTimeout
    } = Config
) ->
    ?SLOG(info, #{
        msg => "starting_clickhouse_connector",
        connector => InstanceID,
        config => emqx_utils:redact(Config)
    }),
    Options = [
        {url, URL},
        {user, maps:get(username, Config, "default")},
        {key, maps:get(password, Config, emqx_secret:wrap("public"))},
        {database, DB},
        {auto_reconnect, ?AUTO_RECONNECT_INTERVAL},
        {pool_size, PoolSize},
        {pool, InstanceID}
    ],
    try
        State = #{
            channels => #{},
            pool_name => InstanceID,
            connect_timeout => ConnectTimeout
        },
        case emqx_resource_pool:start(InstanceID, ?MODULE, Options) of
            ok ->
                {ok, State};
            {error, Reason} ->
                ?tp(
                    info,
                    "clickhouse_connector_start_failed",
                    #{
                        error => Reason,
                        config => emqx_utils:redact(Config)
                    }
                ),
                {error, Reason}
        end
    catch
        _:CatchReason:Stacktrace ->
            ?tp(
                info,
                "clickhouse_connector_start_failed",
                #{
                    error => CatchReason,
                    stacktrace => Stacktrace,
                    config => emqx_utils:redact(Config)
                }
            ),
            {error, CatchReason}
    end.

%% Helper functions to prepare SQL tempaltes

prepare_sql_templates(#{
    sql := Template,
    batch_value_separator := Separator
}) ->
    InsertTemplate = emqx_placeholder:preproc_tmpl(Template),
    BulkExtendInsertTemplate = prepare_sql_bulk_extend_template(Template, Separator),
    #{
        send_message_template => InsertTemplate,
        extend_send_message_template => BulkExtendInsertTemplate
    };
prepare_sql_templates(_) ->
    %% We don't create any templates if this is a non-bridge connector
    #{}.

prepare_sql_bulk_extend_template(Template, Separator) ->
    ValuesTemplate = split_clickhouse_insert_sql(Template),
    %% The value part has been extracted
    %% Add separator before ValuesTemplate so that one can append it
    %% to an insert template
    ExtendParamTemplate = iolist_to_binary([Separator, ValuesTemplate]),
    emqx_placeholder:preproc_tmpl(ExtendParamTemplate).

%% This function is similar to emqx_utils_sql:parse_insert/1 but can
%% also handle Clickhouse's SQL extension for INSERT statments that allows the
%% user to specify different formats:
%%
%% https://clickhouse.com/docs/en/sql-reference/statements/insert-into/
%%
split_clickhouse_insert_sql(SQL) ->
    ErrorMsg = <<"The SQL template should be an SQL INSERT statement but it is something else.">>,
    case
        re:split(SQL, "(\\s+(?i:values)|(?i:format\\s+(?:[A-Za-z0-9_])+)\\s+)", [{return, binary}])
    of
        [Part1, _, Part3] ->
            case string:trim(Part1, leading) of
                <<"insert", _/binary>> ->
                    Part3;
                <<"INSERT", _/binary>> ->
                    Part3;
                _ ->
                    erlang:error(ErrorMsg)
            end;
        _ ->
            erlang:error(ErrorMsg)
    end.

% This is a callback for ecpool which is triggered by the call to
% emqx_resource_pool:start in on_start/2

connect(Options) ->
    URL = iolist_to_binary(emqx_http_lib:normalize(proplists:get_value(url, Options))),
    User = proplists:get_value(user, Options),
    Database = proplists:get_value(database, Options),
    %% TODO: teach `clickhouse` to accept 0-arity closures as passwords.
    Key = emqx_secret:unwrap(proplists:get_value(key, Options)),
    Pool = proplists:get_value(pool, Options),
    PoolSize = proplists:get_value(pool_size, Options),
    FixedOptions = [
        {url, URL},
        {database, Database},
        {user, User},
        {key, Key},
        {pool, Pool},
        {pool_size, PoolSize}
    ],
    case clickhouse:start_link(FixedOptions) of
        {ok, Connection} ->
            %% Check if we can connect and send a query
            case clickhouse:detailed_status(Connection) of
                ok ->
                    {ok, Connection};
                Error ->
                    ok = clickhouse:stop(Connection),
                    Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% -------------------------------------------------------------------
%% on_stop emqx_resouce callback
%% -------------------------------------------------------------------

-spec on_stop(resource_id(), resource_state()) -> term().

on_stop(InstanceID, _State) ->
    ?SLOG(info, #{
        msg => "stopping clickouse connector",
        connector => InstanceID
    }),
    emqx_resource_pool:stop(InstanceID).

%% -------------------------------------------------------------------
%% channel related emqx_resouce callbacks
%% -------------------------------------------------------------------
on_add_channel(_InstId, #{channels := Channs} = OldState, ChannId, ChannConf0) ->
    #{parameters := ParamConf} = ChannConf0,
    NewChanns = Channs#{ChannId => #{templates => prepare_sql_templates(ParamConf)}},
    {ok, OldState#{channels => NewChanns}}.

on_remove_channel(_InstanceId, #{channels := Channels} = State, ChannId) ->
    NewState = State#{channels => maps:remove(ChannId, Channels)},
    {ok, NewState}.

on_get_channel_status(InstanceId, _ChannId, State) ->
    case on_get_status(InstanceId, State) of
        {connected, _} -> connected;
        {disconnected, _, _} -> disconnected
    end.

on_get_channels(InstanceId) ->
    emqx_bridge_v2:get_channels_for_connector(InstanceId).

%% -------------------------------------------------------------------
%% on_get_status emqx_resouce callback and related functions
%% -------------------------------------------------------------------

on_get_status(
    _InstanceID,
    #{pool_name := PoolName, connect_timeout := Timeout} = State
) ->
    case do_get_status(PoolName, Timeout) of
        ok ->
            {connected, State};
        {error, Reason} ->
            {disconnected, State, Reason}
    end.

do_get_status(PoolName, Timeout) ->
    Workers = [Worker || {_WorkerName, Worker} <- ecpool:workers(PoolName)],
    DoPerWorker =
        fun(Worker) ->
            case ecpool_worker:exec(Worker, fun clickhouse:detailed_status/1, Timeout) of
                ok ->
                    ok;
                {error, Reason} = Error ->
                    ?SLOG(error, #{
                        msg => "clickhouse_connector_get_status_failed",
                        reason => Reason,
                        worker => Worker
                    }),
                    Error
            end
        end,
    try emqx_utils:pmap(DoPerWorker, Workers, Timeout) of
        Results ->
            case [E || {error, _} = E <- Results] of
                [] ->
                    ok;
                Errors ->
                    hd(Errors)
            end
    catch
        exit:timeout ->
            ?SLOG(error, #{
                msg => "clickhouse_connector_pmap_failed",
                reason => timeout
            }),
            {error, timeout}
    end.

%% -------------------------------------------------------------------
%% on_query emqx_resouce callback and related functions
%% -------------------------------------------------------------------

-spec on_query
    (resource_id(), Request, resource_state()) -> query_result() when
        Request :: {ChannId, Data},
        ChannId :: binary(),
        Data :: map();
    (resource_id(), Request, resource_state()) -> query_result() when
        Request :: {RequestType, SQL},
        RequestType :: sql | query,
        SQL :: binary().

on_query(
    ResourceID,
    {RequestType, DataOrSQL},
    #{pool_name := PoolName} = State
) ->
    ?SLOG(debug, #{
        msg => "clickhouse_connector_received_sql_query",
        connector => ResourceID,
        type => RequestType,
        sql => DataOrSQL,
        state => State
    }),
    %% Have we got a query or data to fit into an SQL template?
    SimplifiedRequestType = query_type(RequestType),
    Templates = get_templates(RequestType, State),
    SQL = get_sql(SimplifiedRequestType, Templates, DataOrSQL),
    ClickhouseResult = execute_sql_in_clickhouse_server(RequestType, PoolName, SQL),
    transform_and_log_clickhouse_result(ClickhouseResult, ResourceID, SQL).

get_templates(ChannId, State) ->
    case maps:find(channels, State) of
        {ok, Channels} ->
            maps:get(templates, maps:get(ChannId, Channels, #{}), #{});
        error ->
            #{}
    end.

get_sql(channel_message, #{send_message_template := PreparedSQL}, Data) ->
    emqx_placeholder:proc_tmpl(PreparedSQL, Data, #{return => full_binary});
get_sql(_, _, SQL) ->
    SQL.

query_type(sql) ->
    query;
query_type(query) ->
    query;
%% Data that goes to bridges use the prepared template
query_type(ChannId) when is_binary(ChannId) ->
    channel_message.

%% -------------------------------------------------------------------
%% on_batch_query emqx_resouce callback and related functions
%% -------------------------------------------------------------------

-spec on_batch_query(resource_id(), BatchReq, resource_state()) -> query_result() when
    BatchReq :: nonempty_list({binary(), map()}).

on_batch_query(ResourceID, BatchReq, #{pool_name := PoolName} = State) ->
    %% Currently we only support batch requests with a binary ChannId
    {[ChannId | _] = Keys, ObjectsToInsert} = lists:unzip(BatchReq),
    ensure_channel_messages(Keys),
    Templates = get_templates(ChannId, State),
    %% Create batch insert SQL statement
    SQL = objects_to_sql(ObjectsToInsert, Templates),
    %% Do the actual query in the database
    ResultFromClickhouse = execute_sql_in_clickhouse_server(ChannId, PoolName, SQL),
    %% Transform the result to a better format
    transform_and_log_clickhouse_result(ResultFromClickhouse, ResourceID, SQL).

ensure_channel_messages(Keys) ->
    case lists:all(fun is_binary/1, Keys) of
        true ->
            ok;
        false ->
            erlang:error(
                {unrecoverable_error, <<"Unexpected type for batch message (Expected channel-id)">>}
            )
    end.

objects_to_sql(
    [FirstObject | RemainingObjects] = _ObjectsToInsert,
    #{
        send_message_template := InsertTemplate,
        extend_send_message_template := BulkExtendInsertTemplate
    }
) ->
    %% Prepare INSERT-statement and the first row after VALUES
    InsertStatementHead = emqx_placeholder:proc_tmpl(InsertTemplate, FirstObject),
    FormatObjectDataFunction =
        fun(Object) ->
            emqx_placeholder:proc_tmpl(BulkExtendInsertTemplate, Object)
        end,
    InsertStatementTail = lists:map(FormatObjectDataFunction, RemainingObjects),
    CompleteStatement = erlang:iolist_to_binary([InsertStatementHead, InsertStatementTail]),
    CompleteStatement;
objects_to_sql(_, _) ->
    erlang:error(<<"Templates for bulk insert missing.">>).

%% -------------------------------------------------------------------
%% Helper functions that are used by both on_query/3 and on_batch_query/3
%% -------------------------------------------------------------------

%% This function is used by on_query/3 and on_batch_query/3 to send a query to
%% the database server and receive a result
execute_sql_in_clickhouse_server(Id, PoolName, SQL) ->
    emqx_trace:rendered_action_template(Id, #{rendered_sql => SQL}),
    ecpool:pick_and_do(
        PoolName,
        {?MODULE, execute_sql_in_clickhouse_server_using_connection, [SQL]},
        no_handover
    ).

execute_sql_in_clickhouse_server_using_connection(Connection, SQL) ->
    clickhouse:query(Connection, SQL, []).

%% This function transforms the result received from clickhouse to something
%% that is a little bit more readable and creates approprieate log messages
transform_and_log_clickhouse_result({ok, ResponseCode, <<"">>} = _ClickhouseResult, _, _) when
    ResponseCode =:= 200; ResponseCode =:= 204
->
    snabbkaffe_log_return(ok),
    ok;
transform_and_log_clickhouse_result({ok, ResponseCode, Data}, _, _) when
    ResponseCode =:= 200; ResponseCode =:= 204
->
    Result = {ok, Data},
    snabbkaffe_log_return(Result),
    Result;
transform_and_log_clickhouse_result(ClickhouseErrorResult, ResourceID, SQL) ->
    ?SLOG(error, #{
        msg => "clickhouse_connector_do_sql_query_failed",
        connector => ResourceID,
        sql => SQL,
        reason => ClickhouseErrorResult
    }),
    case is_recoverable_error(ClickhouseErrorResult) of
        %% TODO: The hackney errors that the clickhouse library forwards are
        %% very loosely defined. We should try to make sure that the following
        %% handles all error cases that we need to handle as recoverable_error
        true ->
            ?SLOG(warning, #{
                msg => "clickhouse_connector_sql_query_failed_recoverable",
                recoverable_error => true,
                connector => ResourceID,
                sql => SQL,
                reason => ClickhouseErrorResult
            }),
            to_recoverable_error(ClickhouseErrorResult);
        false ->
            ?SLOG(error, #{
                msg => "clickhouse_connector_sql_query_failed_unrecoverable",
                recoverable_error => false,
                connector => ResourceID,
                sql => SQL,
                reason => ClickhouseErrorResult
            }),
            to_error_tuple(ClickhouseErrorResult)
    end.

on_format_query_result(ok) ->
    #{result => ok, message => <<"">>};
on_format_query_result({ok, Message}) ->
    #{result => ok, message => Message};
on_format_query_result(Result) ->
    Result.

to_recoverable_error({error, Reason}) ->
    {error, {recoverable_error, Reason}};
to_recoverable_error(Error) ->
    {error, {recoverable_error, Error}}.

to_error_tuple({error, Reason}) ->
    {error, {unrecoverable_error, Reason}};
to_error_tuple(Error) ->
    {error, {unrecoverable_error, Error}}.

is_recoverable_error({error, Reason}) ->
    is_recoverable_error_reason(Reason);
is_recoverable_error(_) ->
    false.

is_recoverable_error_reason(ecpool_empty) ->
    true;
is_recoverable_error_reason(econnrefused) ->
    true;
is_recoverable_error_reason(closed) ->
    true;
is_recoverable_error_reason({closed, _PartialBody}) ->
    true;
is_recoverable_error_reason(disconnected) ->
    true;
is_recoverable_error_reason(_) ->
    false.

snabbkaffe_log_return(_Result) ->
    ?tp(
        clickhouse_connector_query_return,
        #{result => _Result}
    ).
