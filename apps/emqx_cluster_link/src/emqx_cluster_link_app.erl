%%--------------------------------------------------------------------
%% Copyright (c) 2024 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_cluster_link_app).

-behaviour(application).

-export([start/2, prep_stop/1, stop/1]).

-define(BROKER_MOD, emqx_cluster_link).

start(_StartType, _StartArgs) ->
    ok = mria:wait_for_tables(emqx_cluster_link_extrouter:create_tables()),
    emqx_cluster_link_config:add_handler(),
    LinksConf = emqx_cluster_link_config:enabled_links(),
    case LinksConf of
        [_ | _] ->
            ok = emqx_cluster_link:register_external_broker(),
            ok = emqx_cluster_link:put_hook(),
            ok = start_msg_fwd_resources(LinksConf);
        _ ->
            ok
    end,
    {ok, Sup} = emqx_cluster_link_sup:start_link(LinksConf),
    ok = create_metrics(LinksConf),
    {ok, Sup}.

prep_stop(State) ->
    emqx_cluster_link_config:remove_handler(),
    State.

stop(_State) ->
    _ = emqx_cluster_link:delete_hook(),
    _ = emqx_cluster_link:unregister_external_broker(),
    _ = remove_msg_fwd_resources(emqx_cluster_link_config:links()),
    ok.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

start_msg_fwd_resources(LinksConf) ->
    lists:foreach(
        fun(LinkConf) ->
            {ok, _} = emqx_cluster_link_mqtt:ensure_msg_fwd_resource(LinkConf)
        end,
        LinksConf
    ).

remove_msg_fwd_resources(LinksConf) ->
    lists:foreach(
        fun(#{name := Name}) ->
            emqx_cluster_link_mqtt:remove_msg_fwd_resource(Name)
        end,
        LinksConf
    ).

create_metrics(LinksConf) ->
    lists:foreach(
        fun(#{name := ClusterName}) ->
            ok = emqx_cluster_link_metrics:maybe_create_metrics(ClusterName)
        end,
        LinksConf
    ).
