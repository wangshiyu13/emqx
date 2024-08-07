%%--------------------------------------------------------------------
%% Copyright (c) 2020-2024 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_auth_http_app).

-include("emqx_auth_http.hrl").

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = emqx_authz:register_source(?AUTHZ_TYPE, emqx_authz_http),
    ok = emqx_authn:register_provider(?AUTHN_TYPE, emqx_authn_http),
    ok = emqx_authn:register_provider(?AUTHN_TYPE_SCRAM, emqx_authn_scram_restapi),
    {ok, Sup} = emqx_auth_http_sup:start_link(),
    {ok, Sup}.

stop(_State) ->
    ok = emqx_authn:deregister_provider(?AUTHN_TYPE),
    ok = emqx_authn:deregister_provider(?AUTHN_TYPE_SCRAM),
    ok = emqx_authz:unregister_source(?AUTHZ_TYPE),
    ok.
