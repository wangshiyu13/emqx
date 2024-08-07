%%--------------------------------------------------------------------
%% Copyright (c) 2022-2024 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(emqx_ds_storage_layout_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("emqx_ds.hrl").
-include("../../emqx/include/emqx.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(assertSameSet(A, B), ?assertEqual(lists:sort(A), lists:sort(B))).

-define(FUTURE, (1 bsl 64 - 1)).

-define(SHARD, shard(?FUNCTION_NAME)).

-define(DB_CONFIG(CONFIG), #{
    backend => builtin_local,
    storage => ?config(layout, CONFIG),
    n_shards => 1
}).

all() ->
    [
        {group, bitfield_lts},
        {group, skipstream_lts}
    ].

init_per_group(Group, Config) ->
    LayoutConf =
        case Group of
            skipstream_lts ->
                {emqx_ds_storage_skipstream_lts, #{with_guid => true}};
            bitfield_lts ->
                {emqx_ds_storage_bitfield_lts, #{}}
        end,
    [{layout, LayoutConf} | Config].

end_per_group(_Group, Config) ->
    Config.

%% Smoke test of store function
t_store(_Config) ->
    MessageID = emqx_guid:gen(),
    PublishedAt = 1000,
    Topic = <<"foo/bar">>,
    Payload = <<"message">>,
    Msg = #message{
        id = MessageID,
        topic = Topic,
        payload = Payload,
        timestamp = PublishedAt
    },
    ?assertMatch(ok, emqx_ds:store_batch(?FUNCTION_NAME, [Msg])).

%% Smoke test of applying batch operations
t_operations(db_config, _Config) ->
    #{force_monotonic_timestamps => false}.

t_operations(_Config) ->
    Batch1 = [
        make_message(100, <<"t/1">>, <<"M1">>),
        make_message(200, <<"t/2">>, <<"M2">>),
        make_message(300, <<"t/3">>, <<"M3">>)
    ],
    Batch2 = [
        make_deletion(200, <<"t/2">>, <<"M2">>),
        make_deletion(300, <<"t/3">>, '_'),
        make_deletion(400, <<"t/4">>, '_')
    ],
    ?assertEqual(ok, emqx_ds:store_batch(?FUNCTION_NAME, Batch1)),
    ?assertEqual(ok, emqx_ds:store_batch(?FUNCTION_NAME, Batch2)),
    ?assertMatch(
        [
            #message{timestamp = 100, topic = <<"t/1">>, payload = <<"M1">>}
        ],
        dump_messages(?SHARD, <<"t/#">>, 0)
    ).

%% Smoke test for iteration through a concrete topic
t_iterate(_Config) ->
    %% Prepare data:
    Topics = [<<"foo/bar">>, <<"foo/bar/baz">>, <<"a">>],
    Timestamps = lists:seq(1, 10),
    Batch = [
        make_message(PublishedAt, Topic, integer_to_binary(PublishedAt))
     || Topic <- Topics, PublishedAt <- Timestamps
    ],
    ok = emqx_ds:store_batch(?FUNCTION_NAME, Batch),
    %% Iterate through individual topics:
    [
        begin
            [{Rank, Stream}] = emqx_ds_storage_layer:get_streams(?SHARD, parse_topic(Topic), 0),
            ct:pal("Streams for ~p: {~p, ~p}", [Topic, Rank, Stream]),
            {ok, It} = emqx_ds_storage_layer:make_iterator(?SHARD, Stream, parse_topic(Topic), 0),
            ct:pal("Iterator for ~p: ~p", [Topic, It]),
            {ok, NextIt, MessagesAndKeys} = emqx_ds_storage_layer:next(
                ?SHARD, It, 100, emqx_ds:timestamp_us()
            ),
            Messages = [Msg || {_DSKey, Msg} <- MessagesAndKeys],
            ?assertEqual(
                lists:map(fun integer_to_binary/1, Timestamps),
                payloads(Messages)
            ),
            {ok, _, []} = emqx_ds_storage_layer:next(?SHARD, NextIt, 100, emqx_ds:timestamp_us())
        end
     || Topic <- Topics
    ],
    ok.

%% Smoke test for deleting messages.
t_delete(_Config) ->
    %% Prepare data:
    TopicToDelete = <<"foo/bar/baz">>,
    Topics = [<<"foo/bar">>, TopicToDelete, <<"a">>],
    Timestamps = lists:seq(1, 10),
    Batch = [
        make_message(PublishedAt, Topic, integer_to_binary(PublishedAt))
     || Topic <- Topics, PublishedAt <- Timestamps
    ],
    ok = emqx_ds:store_batch(?FUNCTION_NAME, Batch),

    %% Iterate through topics:
    StartTime = 0,
    TopicFilter = parse_topic(<<"#">>),
    Selector = fun(#message{topic = T}) ->
        T == TopicToDelete
    end,
    NumDeleted = delete(?SHARD, TopicFilter, StartTime, Selector),
    ?assertEqual(10, NumDeleted),

    %% Read surviving messages.
    Messages = [Msg || {_DSKey, Msg} <- replay(?SHARD, TopicFilter, StartTime)],
    MessagesByTopic = maps:groups_from_list(fun emqx_message:topic/1, Messages),
    ?assertNot(is_map_key(TopicToDelete, MessagesByTopic), #{msgs => MessagesByTopic}),
    ?assertEqual(20, length(Messages)).

%% Smoke test that verifies that concrete topics are mapped to
%% individual streams, unless there's too many of them.
t_get_streams(Config) ->
    %% Prepare data (without wildcards):
    Topics = [<<"foo/bar">>, <<"foo/bar/baz">>, <<"a">>],
    Timestamps = lists:seq(1, 10),
    Batch = [
        make_message(PublishedAt, Topic, integer_to_binary(PublishedAt))
     || Topic <- Topics, PublishedAt <- Timestamps
    ],
    ok = emqx_ds:store_batch(?FUNCTION_NAME, Batch),
    GetStream = fun(Topic) ->
        StartTime = 0,
        emqx_ds_storage_layer:get_streams(?SHARD, parse_topic(Topic), StartTime)
    end,
    %% Get streams for individual topics to use as a reference for later:
    [FooBar = {_, _}] = GetStream(<<"foo/bar">>),
    [FooBarBaz] = GetStream(<<"foo/bar/baz">>),
    [A] = GetStream(<<"a">>),
    %% Restart shard to make sure trie is persisted and restored:
    ok = emqx_ds:close_db(?FUNCTION_NAME),
    ok = emqx_ds:open_db(?FUNCTION_NAME, ?DB_CONFIG(Config)),
    %% Verify that there are no "ghost streams" for topics that don't
    %% have any messages:
    [] = GetStream(<<"bar/foo">>),
    %% Test some wildcard patterns:
    ?assertEqual([FooBar], GetStream("+/+")),
    ?assertSameSet([FooBar, FooBarBaz], GetStream(<<"foo/#">>)),
    ?assertSameSet([FooBar, FooBarBaz, A], GetStream(<<"#">>)),
    %% Now insert a bunch of messages with different topics to create wildcards:
    NewBatch = [
        begin
            B = integer_to_binary(I),
            make_message(100, <<"foo/bar/", B/binary>>, <<"filler", B/binary>>)
        end
     || I <- lists:seq(1, 200)
    ],
    ok = emqx_ds:store_batch(?FUNCTION_NAME, NewBatch),
    %% Check that "foo/bar/baz" topic now appears in two streams:
    %% "foo/bar/baz" and "foo/bar/+":
    NewStreams = lists:sort(GetStream("foo/bar/baz")),
    ?assertMatch([_, _], NewStreams),
    ?assert(lists:member(FooBarBaz, NewStreams)),
    %% Verify that size of the trie is still relatively small, even
    %% after processing 200+ topics:
    AllStreams = GetStream("#"),
    NTotal = length(AllStreams),
    ?assert(NTotal < 30, {NTotal, '<', 30}),
    ?assert(lists:member(FooBar, AllStreams)),
    ?assert(lists:member(FooBarBaz, AllStreams)),
    ?assert(lists:member(A, AllStreams)),
    ok.

t_new_generation_inherit_trie(Config) ->
    %% This test checks that we inherit the previous generation's LTS when creating a new
    %% generation.
    ?check_trace(
        begin
            %% Create a bunch of topics to be learned in the first generation
            TS1 = 500,
            Batch1 = [
                make_message(TS1, make_topic([wildcard, I, suffix, Suffix]), bin(I))
             || I <- lists:seq(1, 200),
                Suffix <- [<<"foo">>, <<"bar">>]
            ],
            ok = emqx_ds:store_batch(?FUNCTION_NAME, Batch1),
            %% Now we create a new generation with the same LTS module.  It should inherit the
            %% learned trie.
            ok = emqx_ds_storage_layer:add_generation(?SHARD, _Since = 1_000),
            %% Restart the shard, to verify that LTS is persisted.
            ok = emqx_ds:close_db(?FUNCTION_NAME),
            ok = emqx_ds:open_db(?FUNCTION_NAME, ?DB_CONFIG(Config)),
            %% Store a batch of messages with the same set of topics.
            TS2 = 1_500,
            Batch2 = [
                make_message(TS2, make_topic([wildcard, I, suffix, Suffix]), bin(I))
             || I <- lists:seq(1, 200),
                Suffix <- [<<"foo">>, <<"bar">>]
            ],
            ok = emqx_ds:store_batch(?FUNCTION_NAME, Batch2),
            %% We should get only two streams for wildcard query, for "foo" and for "bar".
            ?assertMatch(
                [_Foo, _Bar],
                emqx_ds_storage_layer:get_streams(?SHARD, [<<"wildcard">>, '#'], 1_000)
            ),
            ok
        end,
        fun(Trace) ->
            ?assertMatch([_], ?of_kind(layout_inherited_lts_trie, Trace)),
            ok
        end
    ),
    ok.

t_replay(Config) ->
    %% Create concrete topics:
    Topics = [<<"foo/bar">>, <<"foo/bar/baz">>],
    Values = lists:seq(1, 1_000, 100),
    Batch1 = [
        make_message(Val, Topic, bin(Val))
     || Topic <- Topics, Val <- Values
    ],
    ok = emqx_ds:store_batch(?FUNCTION_NAME, Batch1),
    %% Create wildcard topics `wildcard/+/suffix/foo' and `wildcard/+/suffix/bar':
    Batch2 = [
        make_message(Val, make_topic([wildcard, Prefix, suffix, Suffix]), bin(Val))
     || Prefix <- lists:seq(1, 200), Val <- Values, Suffix <- [<<"foo">>, <<"bar">>]
    ],
    ok = emqx_ds:store_batch(?FUNCTION_NAME, Batch2),
    timer:sleep(5_000),
    %% Check various topic filters:
    Messages = Batch1 ++ Batch2,
    %% Missing topics (no ghost messages):
    ?assertNot(check(?SHARD, <<"missing/foo/bar">>, 0, Messages)),
    %% Regular topics:
    ?assert(check(?SHARD, <<"foo/bar">>, 0, Messages)),
    ?assert(check(?SHARD, <<"foo/bar/baz">>, 0, Messages)),
    ?assert(check(?SHARD, <<"foo/#">>, 0, Messages)),
    ?assert(check(?SHARD, <<"foo/+">>, 0, Messages)),
    ?assert(check(?SHARD, <<"foo/+/+">>, 0, Messages)),
    ?assert(check(?SHARD, <<"+/+/+">>, 0, Messages)),
    ?assert(check(?SHARD, <<"+/+/baz">>, 0, Messages)),
    %% Restart the DB to make sure trie is persisted and restored:
    ok = emqx_ds:close_db(?FUNCTION_NAME),
    ok = emqx_ds:open_db(?FUNCTION_NAME, ?DB_CONFIG(Config)),
    %% Learned wildcard topics:
    ?assertNot(check(?SHARD, <<"wildcard/1000/suffix/foo">>, 0, [])),
    ?assert(check(?SHARD, <<"wildcard/1/suffix/foo">>, 0, Messages)),
    ?assert(check(?SHARD, <<"wildcard/100/suffix/foo">>, 0, Messages)),
    ?assert(check(?SHARD, <<"wildcard/+/suffix/foo">>, 0, Messages)),
    ?assert(check(?SHARD, <<"wildcard/1/suffix/+">>, 0, Messages)),
    ?assert(check(?SHARD, <<"wildcard/100/suffix/+">>, 0, Messages)),
    ?assert(check(?SHARD, <<"wildcard/#">>, 0, Messages)),
    ?assert(check(?SHARD, <<"wildcard/1/#">>, 0, Messages)),
    ?assert(check(?SHARD, <<"wildcard/100/#">>, 0, Messages)),
    ?assert(check(?SHARD, <<"#">>, 0, Messages)),
    ok.

t_atomic_store_batch(_Config) ->
    DB = ?FUNCTION_NAME,
    ?check_trace(
        begin
            application:set_env(emqx_durable_storage, egress_batch_size, 1),
            Msgs = [
                make_message(0, <<"1">>, <<"1">>),
                make_message(1, <<"2">>, <<"2">>),
                make_message(2, <<"3">>, <<"3">>)
            ],
            ?assertEqual(
                ok,
                emqx_ds:store_batch(DB, Msgs, #{
                    atomic => true,
                    sync => true
                })
            ),
            timer:sleep(1000)
        end,
        fun(Trace) ->
            %% Must contain exactly one flush with all messages.
            ?assertMatch(
                [#{batch := [_, _, _]}],
                ?of_kind(emqx_ds_buffer_flush, Trace)
            ),
            ok
        end
    ),
    ok.

t_non_atomic_store_batch(_Config) ->
    DB = ?FUNCTION_NAME,
    ?check_trace(
        begin
            application:set_env(emqx_durable_storage, egress_batch_size, 1),
            Msgs = [
                make_message(0, <<"1">>, <<"1">>),
                make_message(1, <<"2">>, <<"2">>),
                make_message(2, <<"3">>, <<"3">>)
            ],
            %% Non-atomic batches may be split.
            ?assertEqual(
                ok,
                emqx_ds:store_batch(DB, Msgs, #{
                    atomic => false,
                    sync => true
                })
            ),
            Msgs
        end,
        fun(ExpectedMsgs, Trace) ->
            ProcessedMsgs = lists:append(
                ?projection(batch, ?of_kind(emqx_ds_buffer_flush, Trace))
            ),
            ?assertEqual(
                ExpectedMsgs,
                ProcessedMsgs
            )
        end
    ).

check(Shard, TopicFilter, StartTime, ExpectedMessages) ->
    ?tp(notice, ?MODULE_STRING "_check", #{
        shard => Shard, tf => TopicFilter, start_time => StartTime
    }),
    ExpectedFiltered = lists:filter(
        fun(#message{topic = Topic, timestamp = TS}) ->
            emqx_topic:match(Topic, TopicFilter) andalso TS >= StartTime
        end,
        ExpectedMessages
    ),
    ?check_trace(
        #{timetrap => 10_000},
        begin
            Dump = dump_messages(Shard, TopicFilter, StartTime),
            verify_dump(TopicFilter, StartTime, Dump),
            emqx_ds_test_helpers:assert_same_set(ExpectedFiltered, Dump, #{
                topic_filter => TopicFilter, start_time => StartTime
            })
        end,
        []
    ),
    length(ExpectedFiltered) > 0.

verify_dump(TopicFilter, StartTime, Dump) ->
    lists:foldl(
        fun(#message{topic = Topic, timestamp = TS}, Acc) ->
            %% Verify that the topic of the message returned by the
            %% iterator matches the expected topic filter:
            ?assert(emqx_topic:match(Topic, TopicFilter), {unexpected_topic, Topic, TopicFilter}),
            %% Verify that timestamp of the message is greater than
            %% the StartTime of the iterator:
            ?assert(TS >= StartTime, {start_time, TopicFilter, TS, StartTime}),
            %% Verify that iterator didn't reorder messages
            %% (timestamps for each topic are growing):
            LastTopicTs = maps:get(Topic, Acc, -1),
            ?assert(TS >= LastTopicTs, {topic_ts_reordering, Topic, TS, LastTopicTs}),
            Acc#{Topic => TS}
        end,
        #{},
        Dump
    ).

dump_messages(Shard, TopicFilter, StartTime) ->
    Streams = emqx_ds_storage_layer:get_streams(Shard, parse_topic(TopicFilter), StartTime),
    ct:pal("Streams for ~p:~n ~p", [TopicFilter, Streams]),
    lists:flatmap(
        fun({_Rank, Stream}) ->
            dump_stream(Shard, Stream, TopicFilter, StartTime)
        end,
        Streams
    ).

dump_stream(Shard, Stream, TopicFilter, StartTime) ->
    BatchSize = 100,
    {ok, Iterator} = emqx_ds_storage_layer:make_iterator(
        Shard, Stream, parse_topic(TopicFilter), StartTime
    ),
    ct:pal("Iterator for ~p at stream ~p:~n  ~p", [TopicFilter, Stream, Iterator]),
    Loop = fun
        F(It, 0) ->
            error({too_many_iterations, It});
        F(It, N) ->
            case emqx_ds_storage_layer:next(Shard, It, BatchSize, emqx_ds:timestamp_us()) of
                end_of_stream ->
                    [];
                {ok, _NextIt, []} ->
                    [];
                {ok, NextIt, Batch} ->
                    [Msg || {_DSKey, Msg} <- Batch] ++ F(NextIt, N - 1)
            end
    end,
    MaxIterations = 1000000,
    Loop(Iterator, MaxIterations).

%% t_create_gen(_Config) ->
%%     {ok, 1} = emqx_ds_storage_layer:create_generation(?SHARD, 5, ?DEFAULT_CONFIG),
%%     ?assertEqual(
%%         {error, nonmonotonic},
%%         emqx_ds_storage_layer:create_generation(?SHARD, 1, ?DEFAULT_CONFIG)
%%     ),
%%     ?assertEqual(
%%         {error, nonmonotonic},
%%         emqx_ds_storage_layer:create_generation(?SHARD, 5, ?DEFAULT_CONFIG)
%%     ),
%%     {ok, 2} = emqx_ds_storage_layer:create_generation(?SHARD, 10, ?COMPACT_CONFIG),
%%     Topics = ["foo/bar", "foo/bar/baz"],
%%     Timestamps = lists:seq(1, 100),
%%     [
%%         ?assertMatch({ok, [_]}, store(?SHARD, PublishedAt, Topic, <<>>))
%%      || Topic <- Topics, PublishedAt <- Timestamps
%%     ].

make_message(PublishedAt, Topic, Payload) when is_list(Topic) ->
    make_message(PublishedAt, list_to_binary(Topic), Payload);
make_message(PublishedAt, Topic, Payload) when is_binary(Topic) ->
    ID = emqx_guid:gen(),
    #message{
        id = ID,
        from = <<?MODULE_STRING>>,
        topic = Topic,
        timestamp = PublishedAt,
        payload = Payload
    }.

make_deletion(Timestamp, Topic, Payload) ->
    {delete, #message_matcher{
        from = <<?MODULE_STRING>>,
        topic = Topic,
        timestamp = Timestamp,
        payload = Payload
    }}.

make_topic(Tokens = [_ | _]) ->
    emqx_topic:join([bin(T) || T <- Tokens]).

payloads(Messages) ->
    lists:map(
        fun(#message{payload = P}) ->
            P
        end,
        Messages
    ).

parse_topic(Topic = [L | _]) when is_binary(L); is_atom(L) ->
    Topic;
parse_topic(Topic) ->
    emqx_topic:words(iolist_to_binary(Topic)).

bin(X) ->
    emqx_utils_conv:bin(X).

%% CT callbacks

groups() ->
    TCs = emqx_common_test_helpers:all(?MODULE),
    [
        {bitfield_lts, TCs},
        {skipstream_lts, TCs}
    ].

suite() -> [{timetrap, {seconds, 20}}].

init_per_suite(Config) ->
    WorkDir = emqx_cth_suite:work_dir(Config),
    Apps = emqx_cth_suite:start(
        [emqx_ds_builtin_local],
        #{work_dir => WorkDir}
    ),
    [{apps, Apps}, {work_dir, WorkDir} | Config].

end_per_suite(Config) ->
    Apps = ?config(apps, Config),
    ok = emqx_cth_suite:stop(Apps),
    emqx_cth_suite:clean_work_dir(?config(work_dir, Config)),
    ok.

init_per_testcase(TC, Config) ->
    ok = emqx_ds:open_db(TC, db_config(TC, Config)),
    Config.

end_per_testcase(TC, _Config) ->
    emqx_ds:drop_db(TC),
    ok.

db_config(TC, Config) ->
    ConfigBase = ?DB_CONFIG(Config),
    SpecificConfig =
        try
            ?MODULE:TC(?FUNCTION_NAME, Config)
        catch
            error:undef -> #{}
        end,
    maps:merge(ConfigBase, SpecificConfig).

shard(TC) ->
    {TC, <<"0">>}.

keyspace(TC) ->
    TC.

set_keyspace_config(Keyspace, Config) ->
    ok = application:set_env(emqx_ds, keyspace_config, #{Keyspace => Config}).

delete(Shard, TopicFilter, Time, Selector) ->
    Streams = emqx_ds_storage_layer:get_delete_streams(Shard, TopicFilter, Time),
    Iterators = lists:map(
        fun(Stream) ->
            {ok, Iterator} = emqx_ds_storage_layer:make_delete_iterator(
                Shard,
                Stream,
                TopicFilter,
                Time
            ),
            Iterator
        end,
        Streams
    ),
    delete(Shard, Iterators, Selector).

delete(_Shard, [], _Selector) ->
    0;
delete(Shard, Iterators, Selector) ->
    {NewIterators0, N} = lists:foldl(
        fun(Iterator0, {AccIterators, NAcc}) ->
            case
                emqx_ds_storage_layer:delete_next(
                    Shard, Iterator0, Selector, 10, ?FUTURE
                )
            of
                {ok, end_of_stream} ->
                    {AccIterators, NAcc};
                {ok, _Iterator1, 0} ->
                    {AccIterators, NAcc};
                {ok, Iterator1, NDeleted} ->
                    {[Iterator1 | AccIterators], NDeleted + NAcc}
            end
        end,
        {[], 0},
        Iterators
    ),
    NewIterators1 = lists:reverse(NewIterators0),
    N + delete(Shard, NewIterators1, Selector).

replay(Shard, TopicFilter, Time) ->
    StreamsByRank = emqx_ds_storage_layer:get_streams(Shard, TopicFilter, Time),
    Iterators = lists:map(
        fun({_Rank, Stream}) ->
            {ok, Iterator} = emqx_ds_storage_layer:make_iterator(Shard, Stream, TopicFilter, Time),
            Iterator
        end,
        StreamsByRank
    ),
    replay(Shard, Iterators).

replay(_Shard, []) ->
    [];
replay(Shard, Iterators) ->
    {NewIterators0, Messages0} = lists:foldl(
        fun(Iterator0, {AccIterators, AccMessages}) ->
            case emqx_ds_storage_layer:next(Shard, Iterator0, 10, ?FUTURE) of
                {ok, end_of_stream} ->
                    {AccIterators, AccMessages};
                {ok, _Iterator1, []} ->
                    {AccIterators, AccMessages};
                {ok, Iterator1, NewMessages} ->
                    {[Iterator1 | AccIterators], [NewMessages | AccMessages]}
            end
        end,
        {[], []},
        Iterators
    ),
    Messages1 = lists:flatten(lists:reverse(Messages0)),
    NewIterators1 = lists:reverse(NewIterators0),
    Messages1 ++ replay(Shard, NewIterators1).
