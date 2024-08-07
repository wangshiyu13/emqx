%%--------------------------------------------------------------------
%% Copyright (c) 2018-2024 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_exclusive_sub_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(EXCLUSIVE_TOPIC, <<"$exclusive/t/1">>).
-define(NORMAL_TOPIC, <<"t/1">>).

-define(CHECK_SUB(Client, Code), ?CHECK_SUB(Client, ?EXCLUSIVE_TOPIC, Code)).
-define(CHECK_SUB(Client, Topic, Code),
    {ok, _, [Code]} = emqtt:subscribe(Client, Topic, [])
).

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    Apps = emqx_cth_suite:start(
        [{emqx, "mqtt.exclusive_subscription = true"}],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    emqx_cth_suite:stop(proplists:get_value(apps, Config)).

end_per_testcase(_TestCase, _Config) ->
    emqx_exclusive_subscription:clear().

t_exclusive_sub(_) ->
    {ok, C1} = emqtt:start_link([
        {clientid, <<"client1">>},
        {clean_start, false},
        {proto_ver, v5},
        {properties, #{'Session-Expiry-Interval' => 100}}
    ]),
    {ok, _} = emqtt:connect(C1),
    ?CHECK_SUB(C1, 0),

    ?CHECK_SUB(C1, 0),

    {ok, C2} = emqtt:start_link([
        {clientid, <<"client2">>},
        {clean_start, false},
        {proto_ver, v5}
    ]),
    {ok, _} = emqtt:connect(C2),
    ?CHECK_SUB(C2, ?RC_QUOTA_EXCEEDED),

    %% keep exclusive even disconnected
    ok = emqtt:disconnect(C1),
    timer:sleep(1000),

    ?CHECK_SUB(C2, ?RC_QUOTA_EXCEEDED),

    ok = emqtt:disconnect(C2).

t_allow_normal_sub(_) ->
    {ok, C1} = emqtt:start_link([
        {clientid, <<"client1">>},
        {proto_ver, v5}
    ]),
    {ok, _} = emqtt:connect(C1),
    ?CHECK_SUB(C1, 0),

    {ok, C2} = emqtt:start_link([
        {clientid, <<"client2">>},
        {proto_ver, v5}
    ]),
    {ok, _} = emqtt:connect(C2),
    ?CHECK_SUB(C2, ?NORMAL_TOPIC, 0),

    ok = emqtt:disconnect(C1),
    ok = emqtt:disconnect(C2).

t_unsub(_) ->
    {ok, C1} = emqtt:start_link([
        {clientid, <<"client1">>},
        {proto_ver, v5}
    ]),
    {ok, _} = emqtt:connect(C1),
    ?CHECK_SUB(C1, 0),

    {ok, C2} = emqtt:start_link([
        {clientid, <<"client2">>},
        {proto_ver, v5}
    ]),
    {ok, _} = emqtt:connect(C2),
    ?CHECK_SUB(C2, ?RC_QUOTA_EXCEEDED),

    {ok, #{}, [0]} = emqtt:unsubscribe(C1, ?EXCLUSIVE_TOPIC),

    ?CHECK_SUB(C2, 0),

    ok = emqtt:disconnect(C1),
    ok = emqtt:disconnect(C2).

t_clean_session(_) ->
    erlang:process_flag(trap_exit, true),
    {ok, C1} = emqtt:start_link([
        {clientid, <<"client1">>},
        {clean_start, true},
        {proto_ver, v5},
        {properties, #{'Session-Expiry-Interval' => 0}}
    ]),
    {ok, _} = emqtt:connect(C1),
    ?CHECK_SUB(C1, 0),

    {ok, C2} = emqtt:start_link([
        {clientid, <<"client2">>},
        {proto_ver, v5}
    ]),
    {ok, _} = emqtt:connect(C2),
    ?CHECK_SUB(C2, ?RC_QUOTA_EXCEEDED),

    %% auto clean when session was cleand
    ok = emqtt:disconnect(C1),

    timer:sleep(1000),

    ?CHECK_SUB(C2, 0),

    ok = emqtt:disconnect(C2).

t_feat_disabled(_) ->
    OldConf = emqx:get_config([zones], #{}),
    emqx_config:put_zone_conf(default, [mqtt, exclusive_subscription], false),

    {ok, C1} = emqtt:start_link([
        {clientid, <<"client1">>},
        {proto_ver, v5}
    ]),
    {ok, _} = emqtt:connect(C1),
    ?CHECK_SUB(C1, ?RC_TOPIC_FILTER_INVALID),
    ok = emqtt:disconnect(C1),

    emqx_config:put([zones], OldConf).
