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
-module(emqx_ds_storage_skipstream_lts).

-behaviour(emqx_ds_storage_layer).

%% API:
-export([]).

%% behavior callbacks:
-export([
    create/5,
    open/5,
    drop/5,
    prepare_batch/4,
    commit_batch/4,
    get_streams/4,
    get_delete_streams/4,
    make_iterator/5,
    make_delete_iterator/5,
    update_iterator/4,
    next/6,
    delete_next/7,
    lookup_message/3
]).

%% internal exports:
-export([]).

-export_type([schema/0, s/0]).

-include_lib("emqx_utils/include/emqx_message.hrl").
-include_lib("snabbkaffe/include/trace.hrl").
-include("emqx_ds.hrl").
-include("emqx_ds_metrics.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-elvis([{elvis_style, nesting_level, disable}]).

%%================================================================================
%% Type declarations
%%================================================================================

%% TLOG entry
%%   Keys:
-define(cooked_msg_ops, 6).
-define(cooked_lts_ops, 7).
%%   Payload:
-define(cooked_delete, 100).
-define(cooked_msg_op(TIMESTAMP, STATIC, VARYING, VALUE),
    {TIMESTAMP, STATIC, VARYING, VALUE}
).

-define(lts_persist_ops, emqx_ds_storage_skipstream_lts_ops).

%% Width of the wildcard layer, in bits:
-define(wcb, 16).
-type wildcard_idx() :: 0..16#ffff.

%% Width of the timestamp, in bits:
-define(tsb, 64).
-define(max_ts, 16#ffffffffffffffff).
-type ts() :: 0..?max_ts.

-type wildcard_hash() :: binary().

%% Permanent state:
-type schema() ::
    #{
        wildcard_hash_bytes := pos_integer(),
        topic_index_bytes := pos_integer(),
        keep_message_id := boolean(),
        serialization_schema := emqx_ds_msg_serializer:schema(),
        with_guid := boolean()
    }.

%% Runtime state:
-record(s, {
    db :: rocksdb:db_handle(),
    data_cf :: rocksdb:cf_handle(),
    trie :: emqx_ds_lts:trie(),
    trie_cf :: rocksdb:cf_handle(),
    serialization_schema :: emqx_ds_msg_serializer:schema(),
    hash_bytes :: pos_integer(),
    with_guid :: boolean()
}).

-type s() :: #s{}.

-record(stream, {
    static_index :: emqx_ds_lts:static_key()
}).

-record(it, {
    static_index :: emqx_ds_lts:static_key(),
    %% Timestamp of the last visited message:
    ts :: ts(),
    %% Compressed topic filter:
    compressed_tf :: binary(),
    misc = []
}).

%% Level iterator:
-record(l, {
    n :: non_neg_integer(),
    handle :: rocksdb:itr_handle(),
    hash :: binary()
}).

%%================================================================================
%% API functions
%%================================================================================

%%================================================================================
%% behavior callbacks
%%================================================================================

create(_ShardId, DBHandle, GenId, Schema0, SPrev) ->
    Defaults = #{
        wildcard_hash_bytes => 8,
        topic_index_bytes => 8,
        serialization_schema => asn1,
        with_guid => false
    },
    Schema = maps:merge(Defaults, Schema0),
    ok = emqx_ds_msg_serializer:check_schema(maps:get(serialization_schema, Schema)),
    DataCFName = data_cf(GenId),
    TrieCFName = trie_cf(GenId),
    {ok, DataCFHandle} = rocksdb:create_column_family(DBHandle, DataCFName, []),
    {ok, TrieCFHandle} = rocksdb:create_column_family(DBHandle, TrieCFName, []),
    case SPrev of
        #s{trie = TriePrev} ->
            ok = copy_previous_trie(DBHandle, TrieCFHandle, TriePrev),
            ?tp(layout_inherited_lts_trie, #{}),
            ok;
        undefined ->
            ok
    end,
    {Schema, [{DataCFName, DataCFHandle}, {TrieCFName, TrieCFHandle}]}.

open(_Shard, DBHandle, GenId, CFRefs, #{
    topic_index_bytes := TIBytes,
    wildcard_hash_bytes := WCBytes,
    serialization_schema := SSchema,
    with_guid := WithGuid
}) ->
    {_, DataCF} = lists:keyfind(data_cf(GenId), 1, CFRefs),
    {_, TrieCF} = lists:keyfind(trie_cf(GenId), 1, CFRefs),
    Trie = restore_trie(TIBytes, DBHandle, TrieCF),
    #s{
        db = DBHandle,
        data_cf = DataCF,
        trie_cf = TrieCF,
        trie = Trie,
        hash_bytes = WCBytes,
        serialization_schema = SSchema,
        with_guid = WithGuid
    }.

drop(_ShardId, DBHandle, _GenId, _CFRefs, #s{data_cf = DataCF, trie_cf = TrieCF, trie = Trie}) ->
    emqx_ds_lts:destroy(Trie),
    ok = rocksdb:drop_column_family(DBHandle, DataCF),
    ok = rocksdb:drop_column_family(DBHandle, TrieCF),
    ok.

prepare_batch(
    _ShardId,
    S = #s{trie = Trie},
    Operations,
    _Options
) ->
    _ = erase(?lts_persist_ops),
    OperationsCooked = emqx_utils:flattermap(
        fun
            ({Timestamp, Msg = #message{topic = Topic}}) ->
                Tokens = words(Topic),
                {Static, Varying} = emqx_ds_lts:topic_key(Trie, fun threshold_fun/1, Tokens),
                ?cooked_msg_op(Timestamp, Static, Varying, serialize(S, Varying, Msg));
            ({delete, #message_matcher{topic = Topic, timestamp = Timestamp}}) ->
                case emqx_ds_lts:lookup_topic_key(Trie, words(Topic)) of
                    {ok, {Static, Varying}} ->
                        ?cooked_msg_op(Timestamp, Static, Varying, ?cooked_delete);
                    undefined ->
                        %% Topic is unknown, nothing to delete.
                        []
                end
        end,
        Operations
    ),
    {ok, #{
        ?cooked_msg_ops => OperationsCooked,
        ?cooked_lts_ops => pop_lts_persist_ops()
    }}.

commit_batch(
    _ShardId,
    #s{db = DB, trie_cf = TrieCF, data_cf = DataCF, trie = Trie, hash_bytes = HashBytes},
    #{?cooked_lts_ops := LtsOps, ?cooked_msg_ops := Operations},
    Options
) ->
    {ok, Batch} = rocksdb:batch(),
    try
        %% Commit LTS trie to the storage:
        lists:foreach(
            fun({Key, Val}) ->
                ok = rocksdb:batch_put(Batch, TrieCF, term_to_binary(Key), term_to_binary(Val))
            end,
            LtsOps
        ),
        %% Apply LTS ops to the memory cache:
        _ = emqx_ds_lts:trie_update(Trie, LtsOps),
        %% Commit payloads:
        lists:foreach(
            fun
                (?cooked_msg_op(Timestamp, Static, Varying, ValBlob = <<_/bytes>>)) ->
                    MasterKey = mk_key(Static, 0, <<>>, Timestamp),
                    ok = rocksdb:batch_put(Batch, DataCF, MasterKey, ValBlob),
                    mk_index(Batch, DataCF, HashBytes, Static, Varying, Timestamp);
                (?cooked_msg_op(Timestamp, Static, Varying, ?cooked_delete)) ->
                    MasterKey = mk_key(Static, 0, <<>>, Timestamp),
                    ok = rocksdb:batch_delete(Batch, DataCF, MasterKey),
                    delete_index(Batch, DataCF, HashBytes, Static, Varying, Timestamp)
            end,
            Operations
        ),
        Result = rocksdb:write_batch(DB, Batch, [
            {disable_wal, not maps:get(durable, Options, true)}
        ]),
        %% NOTE
        %% Strictly speaking, `{error, incomplete}` is a valid result but should be impossible to
        %% observe until there's `{no_slowdown, true}` in write options.
        case Result of
            ok ->
                ok;
            {error, {error, Reason}} ->
                {error, unrecoverable, {rocksdb, Reason}}
        end
    after
        rocksdb:release_batch(Batch)
    end.

get_streams(_Shard, #s{trie = Trie}, TopicFilter, _StartTime) ->
    get_streams(Trie, TopicFilter).

get_delete_streams(_Shard, #s{trie = Trie}, TopicFilter, _StartTime) ->
    get_streams(Trie, TopicFilter).

make_iterator(_Shard, _State, _Stream, _TopicFilter, TS) when TS >= ?max_ts ->
    {error, unrecoverable, "Timestamp is too large"};
make_iterator(_Shard, #s{trie = Trie}, #stream{static_index = StaticIdx}, TopicFilter, StartTime) ->
    {ok, TopicStructure} = emqx_ds_lts:reverse_lookup(Trie, StaticIdx),
    CompressedTF = emqx_ds_lts:compress_topic(StaticIdx, TopicStructure, TopicFilter),
    {ok, #it{
        static_index = StaticIdx,
        ts = dec_ts(StartTime),
        compressed_tf = emqx_topic:join(CompressedTF)
    }}.

make_delete_iterator(Shard, Data, Stream, TopicFilter, StartTime) ->
    make_iterator(Shard, Data, Stream, TopicFilter, StartTime).

update_iterator(_Shard, _Data, OldIter, DSKey) ->
    case match_ds_key(OldIter#it.static_index, DSKey) of
        false ->
            {error, unrecoverable, "Invalid datastream key"};
        TS ->
            {ok, OldIter#it{ts = TS}}
    end.

next(ShardId = {_DB, Shard}, S, It, BatchSize, TMax, IsCurrent) ->
    init_counters(),
    Iterators = init_iterators(S, It),
    %% ?tp(notice, skipstream_init_iters, #{it => It, its => Iterators}),
    try
        case next_loop(Shard, S, It, Iterators, BatchSize, TMax) of
            {ok, _, []} when not IsCurrent ->
                {ok, end_of_stream};
            Result ->
                Result
        end
    after
        free_iterators(Iterators),
        collect_counters(ShardId)
    end.

delete_next(Shard, S, It0, Selector, BatchSize, Now, IsCurrent) ->
    case next(Shard, S, It0, BatchSize, Now, IsCurrent) of
        {ok, It, KVs} ->
            batch_delete(S, It, Selector, KVs);
        Ret ->
            Ret
    end.

lookup_message(
    Shard,
    S = #s{db = DB, data_cf = CF, trie = Trie},
    #message_matcher{topic = Topic, timestamp = Timestamp}
) ->
    case emqx_ds_lts:lookup_topic_key(Trie, words(Topic)) of
        {ok, {StaticIdx, _Varying}} ->
            DSKey = mk_key(StaticIdx, 0, <<>>, Timestamp),
            case rocksdb:get(DB, CF, DSKey, _ReadOpts = []) of
                {ok, Val} ->
                    {ok, TopicStructure} = emqx_ds_lts:reverse_lookup(Trie, StaticIdx),
                    Msg = deserialize(S, Val),
                    enrich(Shard, S, TopicStructure, DSKey, Msg);
                not_found ->
                    not_found;
                {error, Reason} ->
                    {error, unrecoverable, Reason}
            end;
        undefined ->
            not_found
    end.

%%================================================================================
%% Internal exports
%%================================================================================

%%================================================================================
%% Internal functions
%%================================================================================

%% Loop context:
-record(ctx, {
    shard,
    %% Generation runtime state
    s,
    %% RocksDB iterators:
    iters,
    %% Cached topic structure for the static index:
    topic_structure,
    %% Maximum time:
    tmax,
    %% Compressed topic filter, split into words:
    filter
}).

get_streams(Trie, TopicFilter) ->
    lists:map(
        fun({Static, _Varying}) ->
            #stream{static_index = Static}
        end,
        emqx_ds_lts:match_topics(Trie, TopicFilter)
    ).

%%%%%%%% Value (de)serialization %%%%%%%%%%

serialize(#s{serialization_schema = SSchema, with_guid = WithGuid}, Varying, Msg0) ->
    %% Replace original topic with the varying parts:
    Msg = Msg0#message{
        id =
            case WithGuid of
                true -> Msg0#message.id;
                false -> <<>>
            end,
        topic = emqx_topic:join(Varying)
    },
    emqx_ds_msg_serializer:serialize(SSchema, Msg).

enrich(#ctx{shard = Shard, s = S, topic_structure = TopicStructure}, DSKey, Msg0) ->
    enrich(Shard, S, TopicStructure, DSKey, Msg0).

enrich(
    Shard,
    #s{with_guid = WithGuid},
    TopicStructure,
    DSKey,
    Msg0
) ->
    Tokens = words(Msg0#message.topic),
    Topic = emqx_topic:join(emqx_ds_lts:decompress_topic(TopicStructure, Tokens)),
    Msg0#message{
        topic = Topic,
        id =
            case WithGuid of
                true -> Msg0#message.id;
                false -> fake_guid(Shard, DSKey)
            end
    }.

deserialize(
    #s{serialization_schema = SSchema},
    Blob
) ->
    emqx_ds_msg_serializer:deserialize(SSchema, Blob).

fake_guid(_Shard, DSKey) ->
    %% Both guid and MD5 are 16 bytes:
    crypto:hash(md5, DSKey).

%%%%%%%% Deletion %%%%%%%%%%

batch_delete(#s{hash_bytes = HashBytes, db = DB, data_cf = CF}, It, Selector, KVs) ->
    #it{static_index = Static, compressed_tf = CompressedTF} = It,
    {Indices, _} = lists:foldl(
        fun
            ('+', {Acc, WildcardIdx}) ->
                {Acc, WildcardIdx + 1};
            (LevelFilter, {Acc0, WildcardIdx}) ->
                Acc = [{WildcardIdx, hash(HashBytes, LevelFilter)} | Acc0],
                {Acc, WildcardIdx + 1}
        end,
        {[], 1},
        words(CompressedTF)
    ),
    KeyFamily = [{0, <<>>} | Indices],
    {ok, Batch} = rocksdb:batch(),
    try
        Ndeleted = lists:foldl(
            fun({MsgKey, Val}, Acc) ->
                case Selector(Val) of
                    true ->
                        do_delete(CF, Batch, Static, KeyFamily, MsgKey),
                        Acc + 1;
                    false ->
                        Acc
                end
            end,
            0,
            KVs
        ),
        case rocksdb:write_batch(DB, Batch, []) of
            ok ->
                {ok, It, Ndeleted, length(KVs)};
            {error, {error, Reason}} ->
                {error, unrecoverable, {rocksdb, Reason}}
        end
    after
        rocksdb:release_batch(Batch)
    end.

do_delete(CF, Batch, Static, KeyFamily, MsgKey) ->
    TS = match_ds_key(Static, MsgKey),
    lists:foreach(
        fun({WildcardIdx, Hash}) ->
            ok = rocksdb:batch_delete(Batch, CF, mk_key(Static, WildcardIdx, Hash, TS))
        end,
        KeyFamily
    ).

%%%%%%%% Iteration %%%%%%%%%%

init_iterators(S, #it{static_index = Static, compressed_tf = CompressedTF}) ->
    do_init_iterators(S, Static, words(CompressedTF), 1).

do_init_iterators(S, Static, ['+' | TopicFilter], WildcardLevel) ->
    %% Ignore wildcard levels in the topic filter:
    do_init_iterators(S, Static, TopicFilter, WildcardLevel + 1);
do_init_iterators(S, Static, [Constraint | TopicFilter], WildcardLevel) ->
    %% Create iterator for the index stream:
    #s{hash_bytes = HashBytes, db = DB, data_cf = DataCF} = S,
    Hash = hash(HashBytes, Constraint),
    {ok, ItHandle} = rocksdb:iterator(DB, DataCF, get_key_range(Static, WildcardLevel, Hash)),
    It = #l{
        n = WildcardLevel,
        handle = ItHandle,
        hash = Hash
    },
    [It | do_init_iterators(S, Static, TopicFilter, WildcardLevel + 1)];
do_init_iterators(S, Static, [], _WildcardLevel) ->
    %% Create an iterator for the data stream:
    #s{db = DB, data_cf = DataCF} = S,
    Hash = <<>>,
    {ok, ItHandle} = rocksdb:iterator(DB, DataCF, get_key_range(Static, 0, Hash)),
    [
        #l{
            n = 0,
            handle = ItHandle,
            hash = Hash
        }
    ].

next_loop(
    Shard,
    S = #s{trie = Trie},
    It = #it{static_index = StaticIdx, ts = LastTS, compressed_tf = CompressedTF},
    Iterators,
    BatchSize,
    TMax
) ->
    TopicStructure =
        case emqx_ds_lts:reverse_lookup(Trie, StaticIdx) of
            {ok, Rev} ->
                Rev;
            undefined ->
                throw(#{
                    msg => "LTS trie missing key",
                    key => StaticIdx
                })
        end,
    Ctx = #ctx{
        shard = Shard,
        s = S,
        iters = Iterators,
        topic_structure = TopicStructure,
        filter = words(CompressedTF),
        tmax = TMax
    },
    next_loop(Ctx, It, BatchSize, {seek, inc_ts(LastTS)}, []).

next_loop(_Ctx, It, 0, _Op, Acc) ->
    finalize_loop(It, Acc);
next_loop(Ctx, It0, BatchSize, Op, Acc) ->
    %% ?tp(notice, skipstream_loop, #{
    %%     ts => It0#it.ts, tf => It0#it.compressed_tf, bs => BatchSize, tmax => TMax, op => Op
    %% }),
    #ctx{s = S, tmax = TMax, iters = Iterators} = Ctx,
    #it{static_index = StaticIdx, compressed_tf = CompressedTF} = It0,
    case next_step(S, StaticIdx, CompressedTF, Iterators, undefined, Op) of
        none ->
            %% ?tp(notice, skipstream_loop_result, #{r => none}),
            inc_counter(?DS_SKIPSTREAM_LTS_EOS),
            finalize_loop(It0, Acc);
        {seek, TS} when TS > TMax ->
            %% ?tp(notice, skipstream_loop_result, #{r => seek_future, ts => TS}),
            inc_counter(?DS_SKIPSTREAM_LTS_FUTURE),
            finalize_loop(It0, Acc);
        {ok, TS, _Key, _Msg0} when TS > TMax ->
            %% ?tp(notice, skipstream_loop_result, #{r => ok_future, ts => TS, key => _Key}),
            inc_counter(?DS_SKIPSTREAM_LTS_FUTURE),
            finalize_loop(It0, Acc);
        {seek, TS} ->
            %% ?tp(notice, skipstream_loop_result, #{r => seek, ts => TS}),
            It = It0#it{ts = TS},
            next_loop(Ctx, It, BatchSize, {seek, TS}, Acc);
        {ok, TS, DSKey, Msg0} ->
            %% ?tp(notice, skipstream_loop_result, #{r => ok, ts => TS, key => Key}),
            Message = enrich(Ctx, DSKey, Msg0),
            It = It0#it{ts = TS},
            next_loop(Ctx, It, BatchSize - 1, next, [{DSKey, Message} | Acc])
    end.

finalize_loop(It, Acc) ->
    {ok, It, lists:reverse(Acc)}.

next_step(
    S, StaticIdx, CompressedTF, [#l{hash = Hash, handle = IH, n = N} | Iterators], ExpectedTS, Op
) ->
    Result =
        case Op of
            next ->
                inc_counter(?DS_SKIPSTREAM_LTS_NEXT),
                rocksdb:iterator_move(IH, next);
            {seek, TS} ->
                inc_counter(?DS_SKIPSTREAM_LTS_SEEK),
                rocksdb:iterator_move(IH, {seek, mk_key(StaticIdx, N, Hash, TS)})
        end,
    case Result of
        {error, invalid_iterator} ->
            none;
        {ok, Key, Blob} ->
            case match_key(StaticIdx, N, Hash, Key) of
                false ->
                    %% This should not happen, since we set boundaries
                    %% to the iterators, and overflow to a different
                    %% key prefix should be caught by the previous
                    %% clause:
                    none;
                NextTS when ExpectedTS =:= undefined; NextTS =:= ExpectedTS ->
                    %% We found a key that corresponds to the
                    %% timestamp we expect.
                    %% ?tp(notice, ?MODULE_STRING "_step_hit", #{
                    %%     next_ts => NextTS, expected => ExpectedTS, n => N
                    %% }),
                    case Iterators of
                        [] ->
                            %% This is data stream as well. Check
                            %% message for hash collisions and return
                            %% value:
                            Msg0 = deserialize(S, Blob),
                            case emqx_topic:match(Msg0#message.topic, CompressedTF) of
                                true ->
                                    inc_counter(?DS_SKIPSTREAM_LTS_HIT),
                                    {ok, NextTS, Key, Msg0};
                                false ->
                                    %% Hash collision. Advance to the
                                    %% next timestamp:
                                    inc_counter(?DS_SKIPSTREAM_LTS_HASH_COLLISION),
                                    {seek, NextTS + 1}
                            end;
                        _ ->
                            %% This is index stream. Keep going:
                            next_step(S, StaticIdx, CompressedTF, Iterators, NextTS, {seek, NextTS})
                    end;
                NextTS when NextTS > ExpectedTS, N > 0 ->
                    %% Next index level is not what we expect. Reset
                    %% search to the first wilcard index, but continue
                    %% from `NextTS'.
                    %%
                    %% Note: if `NextTS > ExpectedTS' and `N =:= 0',
                    %% it means the upper (replication) level is
                    %% broken and supplied us NextTS that advenced
                    %% past the point of time that can be safely read.
                    %% We don't handle it here.
                    inc_counter(?DS_SKIPSTREAM_LTS_MISS),
                    {seek, NextTS}
            end
    end.

free_iterators(Its) ->
    lists:foreach(
        fun(#l{handle = IH}) ->
            ok = rocksdb:iterator_close(IH)
        end,
        Its
    ).

%%%%%%%% Indexes %%%%%%%%%%

mk_index(Batch, CF, HashBytes, Static, Varying, Timestamp) ->
    mk_index(Batch, CF, HashBytes, Static, Timestamp, 1, Varying).

mk_index(Batch, CF, HashBytes, Static, Timestamp, N, [TopicLevel | Varying]) ->
    Key = mk_key(Static, N, hash(HashBytes, TopicLevel), Timestamp),
    ok = rocksdb:batch_put(Batch, CF, Key, <<>>),
    mk_index(Batch, CF, HashBytes, Static, Timestamp, N + 1, Varying);
mk_index(_Batch, _CF, _HashBytes, _Static, _Timestamp, _N, []) ->
    ok.

delete_index(Batch, CF, HashBytes, Static, Varying, Timestamp) ->
    delete_index(Batch, CF, HashBytes, Static, Timestamp, 1, Varying).

delete_index(Batch, CF, HashBytes, Static, Timestamp, N, [TopicLevel | Varying]) ->
    Key = mk_key(Static, N, hash(HashBytes, TopicLevel), Timestamp),
    ok = rocksdb:batch_delete(Batch, CF, Key),
    delete_index(Batch, CF, HashBytes, Static, Timestamp, N + 1, Varying);
delete_index(_Batch, _CF, _HashBytes, _Static, _Timestamp, _N, []) ->
    ok.

%%%%%%%% Keys %%%%%%%%%%

get_key_range(StaticIdx, WildcardIdx, Hash) ->
    [
        {iterate_lower_bound, mk_key(StaticIdx, WildcardIdx, Hash, 0)},
        {iterate_upper_bound, mk_key(StaticIdx, WildcardIdx, Hash, ?max_ts)}
    ].

-spec match_ds_key(emqx_ds_lts:static_key(), binary()) -> ts() | false.
match_ds_key(StaticIdx, Key) ->
    match_key(StaticIdx, 0, <<>>, Key).

-spec match_key(emqx_ds_lts:static_key(), wildcard_idx(), wildcard_hash(), binary()) ->
    ts() | false.
match_key(StaticIdx, 0, <<>>, Key) ->
    TSz = size(StaticIdx),
    case Key of
        <<StaticIdx:TSz/binary, 0:?wcb, Timestamp:?tsb>> ->
            Timestamp;
        _ ->
            false
    end;
match_key(StaticIdx, Idx, Hash, Key) when Idx > 0 ->
    Tsz = size(StaticIdx),
    Hsz = size(Hash),
    case Key of
        <<StaticIdx:Tsz/binary, Idx:?wcb, Hash:Hsz/binary, Timestamp:?tsb>> ->
            Timestamp;
        _ ->
            false
    end.

-spec mk_key(emqx_ds_lts:static_key(), wildcard_idx(), wildcard_hash(), ts()) -> binary().
mk_key(StaticIdx, 0, <<>>, Timestamp) ->
    %% Data stream is identified by wildcard level = 0
    <<StaticIdx/binary, 0:?wcb, Timestamp:?tsb>>;
mk_key(StaticIdx, N, Hash, Timestamp) when N > 0 ->
    %% Index stream:
    <<StaticIdx/binary, N:?wcb, Hash/binary, Timestamp:?tsb>>.

hash(HashBytes, '') ->
    hash(HashBytes, <<>>);
hash(HashBytes, TopicLevel) ->
    {Hash, _} = split_binary(erlang:md5(TopicLevel), HashBytes),
    Hash.

%%%%%%%% LTS %%%%%%%%%%

%% TODO: don't hardcode the thresholds
threshold_fun(0) ->
    100;
threshold_fun(_) ->
    10.

-spec restore_trie(pos_integer(), rocksdb:db_handle(), rocksdb:cf_handle()) -> emqx_ds_lts:trie().
restore_trie(StaticIdxBytes, DB, CF) ->
    PersistCallback = fun(Key, Val) ->
        push_lts_persist_op(Key, Val),
        ok
    end,
    {ok, IT} = rocksdb:iterator(DB, CF, []),
    try
        Dump = read_persisted_trie(IT, rocksdb:iterator_move(IT, first)),
        TrieOpts = #{
            persist_callback => PersistCallback,
            static_key_bytes => StaticIdxBytes,
            reverse_lookups => true
        },
        emqx_ds_lts:trie_restore(TrieOpts, Dump)
    after
        rocksdb:iterator_close(IT)
    end.

-spec copy_previous_trie(rocksdb:db_handle(), rocksdb:cf_handle(), emqx_ds_lts:trie()) ->
    ok.
copy_previous_trie(DB, TrieCF, TriePrev) ->
    {ok, Batch} = rocksdb:batch(),
    lists:foreach(
        fun({Key, Val}) ->
            ok = rocksdb:batch_put(Batch, TrieCF, term_to_binary(Key), term_to_binary(Val))
        end,
        emqx_ds_lts:trie_dump(TriePrev, wildcard)
    ),
    Result = rocksdb:write_batch(DB, Batch, []),
    rocksdb:release_batch(Batch),
    Result.

push_lts_persist_op(Key, Val) ->
    case erlang:get(?lts_persist_ops) of
        undefined ->
            erlang:put(?lts_persist_ops, [{Key, Val}]);
        L when is_list(L) ->
            erlang:put(?lts_persist_ops, [{Key, Val} | L])
    end.

pop_lts_persist_ops() ->
    case erlang:erase(?lts_persist_ops) of
        undefined ->
            [];
        L when is_list(L) ->
            L
    end.

read_persisted_trie(IT, {ok, KeyB, ValB}) ->
    [
        {binary_to_term(KeyB), binary_to_term(ValB)}
        | read_persisted_trie(IT, rocksdb:iterator_move(IT, next))
    ];
read_persisted_trie(_IT, {error, invalid_iterator}) ->
    [].

%%%%%%%% Column families %%%%%%%%%%

%% @doc Generate a column family ID for the MQTT messages
-spec data_cf(emqx_ds_storage_layer:gen_id()) -> [char()].
data_cf(GenId) ->
    "emqx_ds_storage_skipstream_lts_data" ++ integer_to_list(GenId).

%% @doc Generate a column family ID for the trie
-spec trie_cf(emqx_ds_storage_layer:gen_id()) -> [char()].
trie_cf(GenId) ->
    "emqx_ds_storage_skipstream_lts_trie" ++ integer_to_list(GenId).

%%%%%%%% Topic encoding %%%%%%%%%%

words(<<>>) ->
    [];
words(Bin) ->
    emqx_topic:words(Bin).

%%%%%%%% Counters %%%%%%%%%%

-define(COUNTERS, [
    ?DS_SKIPSTREAM_LTS_SEEK,
    ?DS_SKIPSTREAM_LTS_NEXT,
    ?DS_SKIPSTREAM_LTS_HASH_COLLISION,
    ?DS_SKIPSTREAM_LTS_HIT,
    ?DS_SKIPSTREAM_LTS_MISS,
    ?DS_SKIPSTREAM_LTS_FUTURE,
    ?DS_SKIPSTREAM_LTS_EOS
]).

inc_counter(Counter) ->
    N = get(Counter),
    put(Counter, N + 1).

init_counters() ->
    _ = [put(I, 0) || I <- ?COUNTERS],
    ok.

collect_counters(Shard) ->
    lists:foreach(
        fun(Key) ->
            emqx_ds_builtin_metrics:collect_shard_counter(Shard, Key, get(Key))
        end,
        ?COUNTERS
    ).

inc_ts(?max_ts) -> 0;
inc_ts(TS) when TS >= 0, TS < ?max_ts -> TS + 1.

dec_ts(0) -> ?max_ts;
dec_ts(TS) when TS > 0, TS =< ?max_ts -> TS - 1.

%%================================================================================
%% Tests
%%================================================================================

-ifdef(TEST).

inc_dec_test_() ->
    Numbers = [0, 1, 100, ?max_ts - 1, ?max_ts],
    [
        ?_assertEqual(N, dec_ts(inc_ts(N)))
     || N <- Numbers
    ].

dec_inc_test_() ->
    Numbers = [0, 1, 100, ?max_ts - 1, ?max_ts],
    [
        ?_assertEqual(N, inc_ts(dec_ts(N)))
     || N <- Numbers
    ].

-endif.
