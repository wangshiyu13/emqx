%%--------------------------------------------------------------------
%% Copyright (c) 2024 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(emqx_mgmt_api_ds).

-if(?EMQX_RELEASE_EDITION == ee).

-behaviour(minirest_api).

-import(hoconsc, [mk/2, ref/1, enum/1, array/1]).

%% API:
-export([
    list_sites/2,
    get_site/2,
    list_dbs/2,
    get_db/2,
    db_replicas/2,
    db_replica/2,

    update_db_sites/3,
    join/3,
    leave/3,

    forget/2
]).

%% behavior callbacks:
-export([
    namespace/0,
    api_spec/0,
    schema/1,
    paths/0,
    fields/1
]).

-include_lib("emqx/include/logger.hrl").
-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").
-include_lib("emqx_utils/include/emqx_utils_api.hrl").
-include_lib("emqx/include/emqx_persistent_message.hrl").

%%================================================================================
%% Type declarations
%%================================================================================

-define(TAGS, [<<"Durable storage">>]).

%%================================================================================
%% behavior callbacks
%%================================================================================

namespace() ->
    undefined.

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

paths() ->
    [
        "/ds/sites",
        "/ds/sites/:site",
        "/ds/storages",
        "/ds/storages/:ds",
        "/ds/storages/:ds/replicas",
        "/ds/storages/:ds/replicas/:site"
    ].

schema("/ds/sites") ->
    #{
        'operationId' => list_sites,
        get =>
            #{
                description => <<"List sites">>,
                tags => ?TAGS,
                responses =>
                    #{
                        200 => mk(array(binary()), #{desc => <<"List sites">>}),
                        404 => disabled_schema()
                    }
            }
    };
schema("/ds/sites/:site") ->
    #{
        'operationId' => get_site,
        get =>
            #{
                description => <<"Get sites">>,
                parameters => [param_site_id()],
                tags => ?TAGS,
                responses =>
                    #{
                        200 => mk(ref(site), #{desc => <<"Get information about the site">>}),
                        404 => not_found(<<"Site">>)
                    }
            }
    };
schema("/ds/storages") ->
    #{
        'operationId' => list_dbs,
        get =>
            #{
                description => <<"List durable storages">>,
                tags => ?TAGS,
                responses =>
                    #{
                        200 => mk(array(atom()), #{desc => <<"List durable storages">>}),
                        404 => disabled_schema()
                    }
            }
    };
schema("/ds/storages/:ds") ->
    #{
        'operationId' => get_db,
        get =>
            #{
                description => <<"Get durable storage">>,
                tags => ?TAGS,
                parameters => [param_storage_id()],
                responses =>
                    #{
                        200 => mk(ref(db), #{desc => <<"Get information about a durable storage">>}),
                        400 => not_found(<<"Durable storage">>),
                        404 => disabled_schema()
                    }
            }
    };
schema("/ds/storages/:ds/replicas") ->
    Parameters = [param_storage_id()],
    #{
        'operationId' => db_replicas,
        get =>
            #{
                description => <<"List replicas of the durable storage">>,
                tags => ?TAGS,
                parameters => Parameters,
                responses =>
                    #{
                        200 => mk(array(binary()), #{
                            desc => <<"List sites that contain replicas of the durable storage">>
                        }),
                        400 => not_found(<<"Durable storage">>),
                        404 => disabled_schema()
                    }
            },
        put =>
            #{
                description => <<"Update replicas of the durable storage">>,
                tags => ?TAGS,
                parameters => Parameters,
                responses =>
                    #{
                        202 => mk(array(binary()), #{}),
                        400 => bad_request(),
                        404 => disabled_schema()
                    },
                'requestBody' => mk(array(binary()), #{desc => <<"New list of sites">>})
            }
    };
schema("/ds/storages/:ds/replicas/:site") ->
    Parameters = [param_storage_id(), param_site_id()],
    #{
        'operationId' => db_replica,
        put =>
            #{
                description => <<"Add site as a replica for the durable storage">>,
                tags => ?TAGS,
                parameters => Parameters,
                responses =>
                    #{
                        202 => <<"OK">>,
                        400 => bad_request(),
                        404 => not_found(<<"Object">>)
                    }
            },
        delete =>
            #{
                description => <<"Remove site as a replica for the durable storage">>,
                tags => ?TAGS,
                parameters => Parameters,
                responses =>
                    #{
                        202 => <<"OK">>,
                        400 => bad_request(),
                        404 => not_found(<<"Object">>)
                    }
            }
    }.

fields(site) ->
    [
        {node,
            mk(
                atom(),
                #{
                    desc => <<"Name of the EMQX handling the site">>,
                    example => <<"'emqx@example.com'">>
                }
            )},
        {up,
            mk(
                boolean(),
                #{desc => <<"Site is up and running">>}
            )},
        {shards,
            mk(
                array(ref(sites_shard)),
                #{desc => <<"Durable storages that have replicas at the site">>}
            )}
    ];
fields(sites_shard) ->
    [
        {storage,
            mk(
                atom(),
                #{
                    desc => <<"Durable storage ID">>,
                    example => ?PERSISTENT_MESSAGE_DB
                }
            )},
        {id,
            mk(
                binary(),
                #{
                    desc => <<"Shard ID">>,
                    example => <<"1">>
                }
            )},
        {status,
            mk(
                atom(),
                #{
                    desc => <<"Shard status">>,
                    example => up
                }
            )}
    ];
fields(db) ->
    [
        {name,
            mk(
                atom(),
                #{
                    desc => <<"Name of the durable storage">>,
                    example => ?PERSISTENT_MESSAGE_DB
                }
            )},
        {shards,
            mk(
                array(ref(db_shard)),
                #{desc => <<"List of storage shards">>}
            )}
    ];
fields(db_shard) ->
    [
        {id,
            mk(
                binary(),
                #{
                    desc => <<"Shard ID">>,
                    example => <<"1">>
                }
            )},
        {replicas,
            mk(
                hoconsc:array(ref(db_site)),
                #{desc => <<"List of sites containing replicas of the storage">>}
            )}
    ];
fields(db_site) ->
    [
        {site,
            mk(
                binary(),
                #{
                    desc => <<"Site ID">>,
                    example => example_site()
                }
            )},
        {status,
            mk(
                enum([up, joining]),
                #{desc => <<"Status of the replica">>}
            )}
    ].

%%================================================================================
%% Internal exports
%%================================================================================

list_sites(get, _Params) ->
    case is_enabled() of
        true ->
            {200, emqx_ds_replication_layer_meta:sites()};
        false ->
            err_disabled()
    end.

get_site(get, #{bindings := #{site := Site}}) ->
    case is_enabled() andalso lists:member(Site, emqx_ds_replication_layer_meta:sites()) of
        false ->
            ?NOT_FOUND(<<"Site not found: ", Site/binary>>);
        true ->
            Node = emqx_ds_replication_layer_meta:node(Site),
            IsUp = mria:cluster_status(Node) =:= running,
            Shards = shards_of_site(Site),
            ?OK(#{
                node => Node,
                up => IsUp,
                shards => Shards
            })
    end.

list_dbs(get, _Params) ->
    case is_enabled() of
        true ->
            ?OK(dbs());
        false ->
            err_disabled()
    end.

get_db(get, #{bindings := #{ds := DB}}) ->
    case is_enabled() of
        true ->
            ?OK(#{
                name => DB,
                shards => list_shards(DB)
            });
        false ->
            err_disabled()
    end.

db_replicas(get, #{bindings := #{ds := DB}}) ->
    case is_enabled() of
        true ->
            Replicas = emqx_ds_replication_layer_meta:db_sites(DB),
            ?OK(Replicas);
        false ->
            err_disabled()
    end;
db_replicas(put, #{bindings := #{ds := DB}, body := Sites}) ->
    case is_enabled() of
        true ->
            case update_db_sites(DB, Sites, rest) of
                {ok, _} ->
                    {202, <<"OK">>};
                {error, Description} ->
                    ?BAD_REQUEST(400, Description)
            end;
        false ->
            err_disabled()
    end.

db_replica(put, #{bindings := #{ds := DB, site := Site}}) ->
    case is_enabled() of
        true ->
            case join(DB, Site, rest) of
                {ok, _} ->
                    {202, <<"OK">>};
                {error, Description} ->
                    ?BAD_REQUEST(400, Description)
            end;
        false ->
            err_disabled()
    end;
db_replica(delete, #{bindings := #{ds := DB, site := Site}}) ->
    case is_enabled() of
        true ->
            case leave(DB, Site, rest) of
                {ok, Sites} when is_list(Sites) ->
                    {202, <<"OK">>};
                {ok, unchanged} ->
                    ?NOT_FOUND(<<"Site is not part of replica set">>);
                {error, Description} ->
                    ?BAD_REQUEST(400, Description)
            end;
        false ->
            err_disabled()
    end.

-spec update_db_sites(emqx_ds:db(), [emqx_ds_replication_layer_meta:site()], rest | cli) ->
    {ok, [emqx_ds_replication_layer_meta:site()]} | {error, _}.
update_db_sites(DB, Sites, Via) when is_list(Sites) ->
    ?SLOG(warning, #{
        msg => "durable_storage_rebalance_request", ds => DB, sites => Sites, via => Via
    }),
    meta_result_to_binary(emqx_ds_replication_layer_meta:assign_db_sites(DB, Sites));
update_db_sites(_, _, _) ->
    {error, <<"Bad type">>}.

-spec join(emqx_ds:db(), emqx_ds_replication_layer_meta:site(), rest | cli) ->
    {ok, unchanged | [emqx_ds_replication_layer_meta:site()]} | {error, _}.
join(DB, Site, Via) ->
    ?SLOG(warning, #{
        msg => "durable_storage_join_request", ds => DB, site => Site, via => Via
    }),
    meta_result_to_binary(emqx_ds_replication_layer_meta:join_db_site(DB, Site)).

-spec leave(emqx_ds:db(), emqx_ds_replication_layer_meta:site(), rest | cli) ->
    {ok, unchanged | [emqx_ds_replication_layer_meta:site()]} | {error, _}.
leave(DB, Site, Via) ->
    ?SLOG(warning, #{
        msg => "durable_storage_leave_request", ds => DB, site => Site, via => Via
    }),
    meta_result_to_binary(emqx_ds_replication_layer_meta:leave_db_site(DB, Site)).

-spec forget(emqx_ds_replication_layer_meta:site(), rest | cli) ->
    ok | {error, _}.
forget(Site, Via) ->
    ?SLOG(warning, #{
        msg => "durable_storage_forget_request", site => Site, via => Via
    }),
    meta_result_to_binary(emqx_ds_replication_layer_meta:forget_site(Site)).

%%================================================================================
%% Internal functions
%%================================================================================

%% site_info(Site) ->
%%     #{}.

disabled_schema() ->
    emqx_dashboard_swagger:error_codes(['NOT_FOUND'], <<"Durable storage is disabled">>).

not_found(What) ->
    emqx_dashboard_swagger:error_codes(['NOT_FOUND'], <<What/binary, " not found">>).

bad_request() ->
    emqx_dashboard_swagger:error_codes(['BAD_REQUEST'], <<"Bad request">>).

param_site_id() ->
    Info = #{
        required => true,
        in => path,
        desc => <<"Site ID">>,
        example => example_site()
    },
    {site, mk(binary(), Info)}.

param_storage_id() ->
    Info = #{
        required => true,
        in => path,
        desc => <<"Durable storage ID">>,
        example => ?PERSISTENT_MESSAGE_DB
    },
    {ds, mk(enum(dbs()), Info)}.

example_site() ->
    try
        emqx_ds_replication_layer_meta:this_site()
    catch
        _:_ ->
            <<"AFA18CB1C22F0157">>
    end.

dbs() ->
    [?PERSISTENT_MESSAGE_DB].

shards_of_site(Site) ->
    lists:flatmap(
        fun({DB, Shard}) ->
            case emqx_ds_replication_layer_meta:shard_info(DB, Shard) of
                #{replica_set := #{Site := Info}} ->
                    [
                        #{
                            storage => DB,
                            id => Shard,
                            status => maps:get(status, Info)
                        }
                    ];
                _ ->
                    []
            end
        end,
        [
            {DB, Shard}
         || DB <- dbs(),
            Shard <- emqx_ds_replication_layer_meta:shards(DB)
        ]
    ).

list_shards(DB) ->
    [
        begin
            #{replica_set := RS} = emqx_ds_replication_layer_meta:shard_info(DB, Shard),
            Replicas = maps:fold(
                fun(Site, #{status := Status}, Acc) ->
                    [
                        #{
                            site => Site,
                            status => Status
                        }
                        | Acc
                    ]
                end,
                [],
                RS
            ),
            #{
                id => Shard,
                replicas => Replicas
            }
        end
     || Shard <- emqx_ds_replication_layer_meta:shards(DB)
    ].

meta_result_to_binary(Ok) when Ok == ok orelse element(1, Ok) == ok ->
    Ok;
meta_result_to_binary({error, {nonexistent_sites, UnknownSites}}) ->
    Msg = ["Unknown sites: " | lists:join(", ", UnknownSites)],
    {error, iolist_to_binary(Msg)};
meta_result_to_binary({error, {nonexistent_db, DB}}) ->
    IOList = io_lib:format("Unknown storage: ~p", [DB]),
    {error, iolist_to_binary(IOList)};
meta_result_to_binary({error, nonexistent_site}) ->
    {error, <<"Unknown site">>};
meta_result_to_binary({error, {member_of_replica_sets, DBNames}}) ->
    DBs = lists:map(fun atom_to_binary/1, DBNames),
    Msg = ["Site is still a member of replica sets of: " | lists:join(", ", DBs)],
    {error, iolist_to_binary(Msg)};
meta_result_to_binary({error, Err}) ->
    IOList = io_lib:format("Error: ~p", [Err]),
    {error, iolist_to_binary(IOList)}.

is_enabled() ->
    emqx_persistent_message:is_persistence_enabled().

err_disabled() ->
    ?NOT_FOUND(<<"Durable storage is disabled">>).

-endif.
