%%--------------------------------------------------------------------
%% Copyright (c) 2021-2024 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_psk_schema).

-behaviour(hocon_schema).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").
-include("emqx_psk.hrl").

-export([
    namespace/0,
    roots/0,
    fields/1
]).

namespace() -> "psk".

roots() -> ["psk_authentication"].

fields("psk_authentication") ->
    #{
        fields => fields(),
        desc => ?DESC(psk_authentication)
    }.

fields() ->
    [
        {enable,
            ?HOCON(boolean(), #{
                %% importance => ?IMPORTANCE_NO_DOC,
                default => false,
                require => true,
                desc => ?DESC(enable)
            })},
        {init_file,
            ?HOCON(binary(), #{
                required => false,
                desc => ?DESC(init_file)
            })},
        {separator,
            ?HOCON(binary(), #{
                default => ?DEFAULT_DELIMITER,
                desc => ?DESC(separator)
            })},
        {chunk_size,
            ?HOCON(integer(), #{
                default => 50,
                desc => ?DESC(chunk_size)
            })}
    ].
