%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_ft_api_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-import(emqx_dashboard_api_test_helpers, [host/0, uri/1]).

all() ->
    [
        {group, single},
        {group, cluster}
    ].

groups() ->
    [
        {single, [], emqx_common_test_helpers:all(?MODULE)},
        {cluster, [], emqx_common_test_helpers:all(?MODULE) -- [t_ft_disabled]}
    ].

suite() ->
    [{timetrap, {seconds, 90}}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(Group = single, Config) ->
    WorkDir = ?config(priv_dir, Config),
    Apps = emqx_cth_suite:start(
        [
            {emqx, #{}},
            {emqx_ft, "file_transfer { enable = true }"},
            {emqx_management, #{}},
            {emqx_dashboard, "dashboard.listeners.http { enable = true, bind = 18083 }"}
        ],
        #{work_dir => WorkDir}
    ),
    {ok, App} = emqx_common_test_http:create_default_app(),
    [{group, Group}, {group_apps, Apps}, {api, App} | Config];
init_per_group(Group = cluster, Config) ->
    WorkDir = ?config(priv_dir, Config),
    Cluster = mk_cluster_specs(Config),
    Nodes = [Node1 | _] = emqx_cth_cluster:start(Cluster, #{work_dir => WorkDir}),
    {ok, App} = erpc:call(Node1, emqx_common_test_http, create_default_app, []),
    [{group, Group}, {cluster_nodes, Nodes}, {api, App} | Config].

end_per_group(single, Config) ->
    {ok, _} = emqx_common_test_http:delete_default_app(),
    ok = emqx_cth_suite:stop(?config(group_apps, Config));
end_per_group(cluster, Config) ->
    ok = emqx_cth_cluster:stop(?config(cluster_nodes, Config));
end_per_group(_Group, _Config) ->
    ok.

mk_cluster_specs(_Config) ->
    Apps = [
        {emqx_conf, #{start => false}},
        {emqx, #{override_env => [{boot_modules, [broker, listeners]}]}},
        {emqx_ft, "file_transfer { enable = true }"},
        {emqx_management, #{}}
    ],
    DashboardConfig =
        "dashboard { \n"
        "    listeners.http { enable = true, bind = 0 } \n"
        "    default_username = \"\" \n"
        "    default_password = \"\" \n"
        "}\n",
    [
        {emqx_ft_api_SUITE1, #{
            role => core,
            apps => Apps ++
                [
                    {emqx_dashboard, DashboardConfig ++ "dashboard.listeners.http.bind = 18083"}
                ]
        }},
        {emqx_ft_api_SUITE2, #{
            role => core,
            apps => Apps ++ [{emqx_dashboard, DashboardConfig}]
        }},
        {emqx_ft_api_SUITE3, #{
            role => replicant,
            apps => Apps ++ [{emqx_dashboard, DashboardConfig}]
        }}
    ].

init_per_testcase(Case, Config) ->
    [{tc, Case} | Config].
end_per_testcase(t_ft_disabled, _Config) ->
    emqx_config:put([file_transfer, enable], true);
end_per_testcase(_Case, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

t_list_files(Config) ->
    ClientId = client_id(Config),
    FileId = <<"f1">>,

    Node = lists:last(test_nodes(Config)),
    ok = emqx_ft_test_helpers:upload_file(ClientId, FileId, "f1", <<"data">>, Node),

    {ok, 200, #{<<"files">> := Files}} =
        request_json(get, uri(["file_transfer", "files"]), Config),

    ?assertMatch(
        [#{<<"clientid">> := ClientId, <<"fileid">> := <<"f1">>}],
        [File || File = #{<<"clientid">> := CId} <- Files, CId == ClientId]
    ),

    {ok, 200, #{<<"files">> := FilesTransfer}} =
        request_json(get, uri(["file_transfer", "files", ClientId, FileId]), Config),

    ?assertMatch(
        [#{<<"clientid">> := ClientId, <<"fileid">> := <<"f1">>}],
        FilesTransfer
    ),

    ?assertMatch(
        {ok, 404, #{<<"code">> := <<"FILES_NOT_FOUND">>}},
        request_json(get, uri(["file_transfer", "files", ClientId, <<"no-such-file">>]), Config)
    ).

t_download_transfer(Config) ->
    ClientId = client_id(Config),
    FileId = <<"f1">>,

    Nodes = [Node | _] = test_nodes(Config),
    NodeUpload = lists:last(Nodes),
    ok = emqx_ft_test_helpers:upload_file(ClientId, FileId, "f1", <<"data">>, NodeUpload),

    ?assertMatch(
        {ok, 400, #{<<"code">> := <<"BAD_REQUEST">>}},
        request_json(
            get,
            uri(["file_transfer", "file"]) ++ query(#{fileref => FileId}),
            Config
        )
    ),

    ?assertMatch(
        {ok, 503, _},
        request(
            get,
            uri(["file_transfer", "file"]) ++
                query(#{fileref => FileId, node => <<"nonode@nohost">>}),
            Config
        )
    ),

    ?assertMatch(
        {ok, 404, _},
        request(
            get,
            uri(["file_transfer", "file"]) ++
                query(#{fileref => <<"unknown_file">>, node => Node}),
            Config
        )
    ),

    ?assertMatch(
        {ok, 404, #{<<"message">> := <<"Invalid query parameter", _/bytes>>}},
        request_json(
            get,
            uri(["file_transfer", "file"]) ++
                query(#{fileref => <<>>, node => Node}),
            Config
        )
    ),

    ?assertMatch(
        {ok, 404, #{<<"message">> := <<"Invalid query parameter", _/bytes>>}},
        request_json(
            get,
            uri(["file_transfer", "file"]) ++
                query(#{fileref => <<"/etc/passwd">>, node => Node}),
            Config
        )
    ),

    {ok, 200, #{<<"files">> := [File]}} =
        request_json(get, uri(["file_transfer", "files", ClientId, FileId]), Config),

    {ok, 200, Response} = request(get, host() ++ maps:get(<<"uri">>, File), Config),

    ?assertEqual(
        <<"data">>,
        Response
    ).

t_list_files_paging(Config) ->
    ClientId = client_id(Config),
    NFiles = 20,
    Nodes = test_nodes(Config),
    Uploads = [
        {mk_file_id("file:", N), mk_file_name(N), pick(N, Nodes)}
     || N <- lists:seq(1, NFiles)
    ],
    ok = lists:foreach(
        fun({FileId, Name, Node}) ->
            ok = emqx_ft_test_helpers:upload_file(ClientId, FileId, Name, <<"data">>, Node)
        end,
        Uploads
    ),

    ?assertMatch(
        {ok, 200, #{<<"files">> := [_, _, _], <<"cursor">> := _}},
        request_json(get, uri(["file_transfer", "files"]) ++ query(#{limit => 3}), Config)
    ),

    {ok, 200, #{<<"files">> := Files}} =
        request_json(get, uri(["file_transfer", "files"]) ++ query(#{limit => 100}), Config),

    ?assert(length(Files) >= NFiles),

    ?assertNotMatch(
        {ok, 200, #{<<"cursor">> := _}},
        request_json(get, uri(["file_transfer", "files"]) ++ query(#{limit => 100}), Config)
    ),

    ?assertMatch(
        {ok, 400, #{<<"code">> := <<"BAD_REQUEST">>}},
        request_json(get, uri(["file_transfer", "files"]) ++ query(#{limit => 0}), Config)
    ),

    ?assertMatch(
        {ok, 400, #{<<"code">> := <<"BAD_REQUEST">>}},
        request_json(get, uri(["file_transfer", "files"]) ++ query(#{following => <<>>}), Config)
    ),

    ?assertMatch(
        {ok, 400, #{<<"code">> := <<"BAD_REQUEST">>}},
        request_json(
            get, uri(["file_transfer", "files"]) ++ query(#{following => <<"{\"\":}">>}), Config
        )
    ),

    ?assertMatch(
        {ok, 400, #{<<"code">> := <<"BAD_REQUEST">>}},
        request_json(
            get,
            uri(["file_transfer", "files"]) ++ query(#{following => <<"whatsthat!?">>}),
            Config
        )
    ),

    PageThrough = fun PageThrough(Query, Acc) ->
        case request_json(get, uri(["file_transfer", "files"]) ++ query(Query), Config) of
            {ok, 200, #{<<"files">> := FilesPage, <<"cursor">> := Cursor}} ->
                PageThrough(Query#{following => Cursor}, Acc ++ FilesPage);
            {ok, 200, #{<<"files">> := FilesPage}} ->
                Acc ++ FilesPage
        end
    end,

    ?assertEqual(Files, PageThrough(#{limit => 1}, [])),
    ?assertEqual(Files, PageThrough(#{limit => 8}, [])),
    ?assertEqual(Files, PageThrough(#{limit => NFiles}, [])).

t_ft_disabled(Config) ->
    ?assertMatch(
        {ok, 200, _},
        request_json(get, uri(["file_transfer", "files"]), Config)
    ),

    ?assertMatch(
        {ok, 400, _},
        request_json(
            get,
            uri(["file_transfer", "file"]) ++ query(#{fileref => <<"f1">>}),
            Config
        )
    ),

    ok = emqx_config:put([file_transfer, enable], false),

    ?assertMatch(
        {ok, 503, _},
        request_json(get, uri(["file_transfer", "files"]), Config)
    ),

    ?assertMatch(
        {ok, 503, _},
        request_json(
            get,
            uri(["file_transfer", "file"]) ++ query(#{fileref => <<"f1">>, node => node()}),
            Config
        )
    ).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

test_nodes(Config) ->
    case proplists:get_value(cluster_nodes, Config, []) of
        [] ->
            [node()];
        Nodes ->
            Nodes
    end.

client_id(Config) ->
    iolist_to_binary(io_lib:format("~s.~s", [?config(group, Config), ?config(tc, Config)])).

mk_file_id(Prefix, N) ->
    iolist_to_binary([Prefix, integer_to_list(N)]).

mk_file_name(N) ->
    "file." ++ integer_to_list(N).

request(Method, Url, Config) ->
    Opts = #{compatible_mode => true, httpc_req_opts => [{body_format, binary}]},
    emqx_mgmt_api_test_util:request_api(Method, Url, [], auth_header(Config), [], Opts).

request_json(Method, Url, Config) ->
    case request(Method, Url, Config) of
        {ok, Code, Body} ->
            {ok, Code, json(Body)};
        Otherwise ->
            Otherwise
    end.

json(Body) when is_binary(Body) ->
    emqx_utils_json:decode(Body, [return_maps]).

query(Params) ->
    KVs = lists:map(fun({K, V}) -> uri_encode(K) ++ "=" ++ uri_encode(V) end, maps:to_list(Params)),
    "?" ++ string:join(KVs, "&").

auth_header(Config) ->
    #{api_key := ApiKey, api_secret := Secret} = ?config(api, Config),
    emqx_common_test_http:auth_header(binary_to_list(ApiKey), binary_to_list(Secret)).

uri_encode(T) ->
    emqx_http_lib:uri_encode(to_list(T)).

to_list(A) when is_atom(A) ->
    atom_to_list(A);
to_list(A) when is_integer(A) ->
    integer_to_list(A);
to_list(B) when is_binary(B) ->
    binary_to_list(B);
to_list(L) when is_list(L) ->
    L.

pick(N, List) ->
    lists:nth(1 + (N rem length(List)), List).