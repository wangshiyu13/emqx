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
-module(emqx_mgmt_api_relup).

-behaviour(minirest_api).

-include_lib("typerefl/include/types.hrl").
-include_lib("emqx/include/logger.hrl").

-export([get_upgrade_status/0, emqx_relup_upgrade/1]).

-export([
    api_spec/0,
    fields/1,
    paths/0,
    schema/1,
    namespace/0,
    validate_name/1
]).

-export([
    '/relup/package/upload'/2,
    '/relup/package'/2,
    '/relup/status'/2,
    '/relup/status/:node'/2,
    '/relup/upgrade'/2,
    '/relup/upgrade/:node'/2
]).

-ignore_xref(emqx_relup_main).

-define(TAGS, [<<"Relup">>]).
-define(NAME_RE, "^[A-Za-z]+[A-Za-z0-9-_.]*$").
-define(CONTENT_PACKAGE, plugin).
-define(PLUGIN_NAME, <<"emqx_relup">>).

-define(EXAM_VSN1, <<"5.8.0">>).
-define(EXAM_VSN2, <<"5.8.1">>).
-define(EXAM_VSN3, <<"5.8.2">>).
-define(EXAM_PACKAGE_NAME_2, <<"emqx_relup-5.8.1.tar.gz">>).
-define(EXAM_PACKAGE_NAME_3, <<"emqx_relup-5.8.2.tar.gz">>).

-define(ASSERT_PKG_READY(EXPR),
    case code:is_loaded(emqx_relup_main) of
        false -> return_package_not_installed();
        {file, _} -> EXPR
    end
).

%%==============================================================================
%% API Spec
namespace() ->
    "relup".

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

paths() ->
    [
        "/relup/package",
        "/relup/package/upload",
        "/relup/status",
        "/relup/status/:node",
        "/relup/upgrade",
        "/relup/upgrade/:node"
    ].

schema("/relup/package/upload") ->
    #{
        'operationId' => '/relup/package/upload',
        post => #{
            summary => <<"Upload a hot upgrade package">>,
            description => <<
                "Upload a hot upgrade package (emqx_relup-vsn.tar.gz).<br/>"
                "Note that only one package is alllowed to be installed at a time."
            >>,
            tags => ?TAGS,
            'requestBody' => #{
                content => #{
                    'multipart/form-data' => #{
                        schema => #{
                            type => object,
                            properties => #{
                                ?CONTENT_PACKAGE => #{type => string, format => binary}
                            }
                        },
                        encoding => #{?CONTENT_PACKAGE => #{'contentType' => 'application/gzip'}}
                    }
                }
            },
            responses => #{
                204 => <<"Package is uploaded successfully">>,
                400 => emqx_dashboard_swagger:error_codes(
                    ['UNEXPECTED_ERROR', 'ALREADY_INSTALLED', 'BAD_PLUGIN_INFO']
                )
            }
        }
    };
schema("/relup/package") ->
    #{
        'operationId' => '/relup/package',
        get => #{
            summary => <<"Get the installed hot upgrade package">>,
            description =>
                <<"Get information of the installed hot upgrade package.<br/>">>,
            tags => ?TAGS,
            responses => #{
                200 => hoconsc:ref(package),
                404 => emqx_dashboard_swagger:error_codes(
                    ['NOT_FOUND'],
                    <<"No relup package is installed">>
                )
            }
        },
        delete => #{
            summary => <<"Delete the installed hot upgrade package">>,
            description =>
                <<"Delete the installed hot upgrade package.<br/>">>,
            tags => ?TAGS,
            responses => #{
                204 => <<"Packages are deleted successfully">>
            }
        }
    };
schema("/relup/status") ->
    #{
        'operationId' => '/relup/status',
        get => #{
            summary => <<"Get the hot upgrade status of all nodes">>,
            description => <<"Get the hot upgrade status of all nodes">>,
            tags => ?TAGS,
            responses => #{
                200 => hoconsc:array(hoconsc:ref(running_status))
            }
        }
    };
schema("/relup/status/:node") ->
    #{
        'operationId' => '/relup/status/:node',
        get => #{
            summary => <<"Get the hot upgrade status of a specified node">>,
            description => <<"Get the hot upgrade status of a specified node">>,
            tags => ?TAGS,
            parameters => [hoconsc:ref(node_name)],
            responses => #{
                200 => hoconsc:ref(running_status)
            }
        }
    };
schema("/relup/upgrade") ->
    #{
        'operationId' => '/relup/upgrade',
        post => #{
            summary => <<"Upgrade all nodes">>,
            description => <<
                "Upgrade all nodes to the target version with the installed package."
            >>,
            tags => ?TAGS,
            responses => #{
                204 => <<"Upgrade is started successfully">>,
                400 => emqx_dashboard_swagger:error_codes(
                    ['UNEXPECTED_ERROR'],
                    <<"Upgrade failed because of invalid input or environment">>
                ),
                500 => emqx_dashboard_swagger:error_codes(
                    ['INTERNAL_ERROR'], <<"Upgrade failed because of internal errors">>
                )
            }
        }
    };
schema("/relup/upgrade/:node") ->
    #{
        'operationId' => '/relup/upgrade/:node',
        post => #{
            summary => <<"Upgrade a specified node">>,
            description => <<
                "Upgrade a specified node to the target version with the installed package."
            >>,
            tags => ?TAGS,
            parameters => [hoconsc:ref(node_name)],
            responses => #{
                204 => <<"Upgrade is started successfully">>,
                400 => emqx_dashboard_swagger:error_codes(
                    ['UNEXPECTED_ERROR'],
                    <<"Upgrade failed because of invalid input or environment">>
                ),
                404 => emqx_dashboard_swagger:error_codes(
                    ['NOT_FOUND'],
                    <<"Node not found">>
                ),
                500 => emqx_dashboard_swagger:error_codes(
                    ['INTERNAL_ERROR'], <<"Upgrade failed because of internal errors">>
                )
            }
        }
    }.

%%==============================================================================
%% Field definitions
fields(package) ->
    [
        {name,
            hoconsc:mk(
                binary(),
                #{
                    desc => <<"File name of the package">>,
                    validator => fun ?MODULE:validate_name/1,
                    example => ?EXAM_PACKAGE_NAME_3
                }
            )},
        {target_vsn,
            hoconsc:mk(
                binary(),
                #{
                    desc => <<"Target emqx version for this package">>,
                    example => ?EXAM_VSN3
                }
            )},
        {built_on_otp_release, hoconsc:mk(binary(), #{example => <<"24">>})},
        {applicable_vsns,
            hoconsc:mk(hoconsc:array(binary()), #{
                example => [?EXAM_VSN1, ?EXAM_VSN2],
                desc => <<"The emqx versions that this package can be applied to.">>
            })},
        {build_date,
            hoconsc:mk(binary(), #{
                example => <<"2021-12-25">>,
                desc => <<"The date when the package was built.">>
            })},
        {change_logs,
            hoconsc:mk(
                hoconsc:array(binary()),
                #{
                    desc => <<"Changes that this package brings">>,
                    example => [
                        <<
                            "1. Fix a bug foo in the plugin."
                            "2. Add a new bar feature."
                        >>
                    ]
                }
            )},
        {md5_sum, hoconsc:mk(binary(), #{example => <<"d41d8cd98f00b204e9800998ecf8427e">>})}
    ];
fields(upgrade_history) ->
    [
        {started_at,
            hoconsc:mk(
                binary(),
                #{
                    desc => <<"The timestamp (in format of RFC3339) when the upgrade started">>,
                    example => <<"2024-07-15T13:48:02.648559+08:00">>
                }
            )},
        {finished_at,
            hoconsc:mk(
                binary(),
                #{
                    desc => <<"The timestamp (in format of RFC3339) when the upgrade finished">>,
                    example => <<"2024-07-16T11:00:01.875627+08:00">>
                }
            )},
        {from_vsn,
            hoconsc:mk(
                binary(),
                #{
                    desc => <<"The version before the upgrade">>,
                    example => ?EXAM_VSN1
                }
            )},
        {target_vsn,
            hoconsc:mk(
                binary(),
                #{
                    desc => <<"The target version of the upgrade">>,
                    example => ?EXAM_VSN3
                }
            )},
        {upgrade_opts,
            hoconsc:mk(
                map(),
                #{
                    desc => <<"The options used for the upgrade">>,
                    example => #{deploy_inplace => false}
                }
            )},
        {status,
            hoconsc:mk(
                hoconsc:enum(['in-progress', finished]),
                #{
                    desc => <<"The upgrade status of the node">>,
                    example => 'in-progress'
                }
            )},
        {result,
            hoconsc:mk(
                hoconsc:union([success, hoconsc:ref(?MODULE, upgrade_error)]),
                #{
                    desc => <<"The upgrade result">>,
                    example => success
                }
            )}
    ];
fields(running_status) ->
    [
        {node, hoconsc:mk(binary(), #{example => <<"emqx@127.0.0.1">>})},
        {status,
            hoconsc:mk(hoconsc:enum(['in-progress', idle]), #{
                desc => <<
                    "The upgrade status of a node:<br/>"
                    "1. in-progress: hot upgrade is in progress.<br/>"
                    "2. idle: hot upgrade is not started.<br/>"
                >>
            })},
        {role,
            hoconsc:mk(hoconsc:enum([core, replicant]), #{
                desc => <<"The role of the node">>,
                example => core
            })},
        {live_connections,
            hoconsc:mk(integer(), #{
                desc => <<"The number of live connections">>,
                example => 100
            })},
        {current_vsn,
            hoconsc:mk(binary(), #{
                desc => <<"The current version of the node">>,
                example => ?EXAM_VSN1
            })},
        {upgrade_history,
            hoconsc:mk(
                hoconsc:array(hoconsc:ref(upgrade_history)),
                #{
                    desc => <<"The upgrade history of the node">>,
                    example => [
                        #{
                            started_at => <<"2024-07-15T13:48:02.648559+08:00">>,
                            finished_at => <<"2024-07-16T11:00:01.875627+08:00">>,
                            from_vsn => ?EXAM_VSN1,
                            target_vsn => ?EXAM_VSN2,
                            upgrade_opts => #{deploy_inplace => false},
                            status => finished,
                            result => success
                        }
                    ]
                }
            )}
    ];
fields(upgrade_error) ->
    [
        {err_type,
            hoconsc:mk(
                binary(),
                #{
                    desc => <<"The type of the error">>,
                    example => <<"no_write_permission">>
                }
            )},
        {details,
            hoconsc:mk(
                map(),
                #{
                    desc => <<"The details of the error">>,
                    example => #{
                        dir => <<"emqx/relup">>,
                        msg => <<"no write permission in dir 'emqx/relup'">>
                    }
                }
            )}
    ];
fields(node_name) ->
    [
        {node,
            hoconsc:mk(
                binary(),
                #{
                    default => all,
                    in => path,
                    desc => <<"The node to be upgraded">>,
                    example => <<"emqx@127.0.0.1">>
                }
            )}
    ].

validate_name(Name) ->
    NameLen = byte_size(Name),
    case NameLen > 0 andalso NameLen =< 256 of
        true ->
            case re:run(Name, ?NAME_RE) of
                nomatch -> {error, <<"Name should be " ?NAME_RE>>};
                _ -> ok
            end;
        false ->
            {error, <<"Name Length must =< 256">>}
    end.

%%==============================================================================
%% HTTP API CallBacks

'/relup/package/upload'(post, #{body := #{<<"plugin">> := UploadBody}} = Params) ->
    case assert_relup_pkg_name(UploadBody) of
        {ok, NameVsn} ->
            case get_installed_packages() of
                [] ->
                    install_as_hidden_plugin(NameVsn, Params);
                _ ->
                    return_bad_request(
                        <<
                            "Only one relup package can be installed at a time."
                            "Please delete the existing package first."
                        >>
                    )
            end;
        {error, Reason} ->
            return_bad_request(Reason)
    end.

'/relup/package'(get, _) ->
    case get_installed_packages() of
        [PluginInfo] ->
            {200, format_package_info(PluginInfo)};
        [] ->
            return_not_found(<<"No relup package is installed">>)
    end;
'/relup/package'(delete, _) ->
    delete_installed_packages(),
    {204}.

'/relup/status'(get, _) ->
    {[_ | _] = Res, []} = emqx_mgmt_api_relup_proto_v1:get_upgrade_status_from_all_nodes(),
    case
        lists:filter(
            fun
                (R) when is_map(R) -> false;
                (_) -> true
            end,
            Res
        )
    of
        [] ->
            {200, Res};
        Filtered ->
            return_internal_error(
                case hd(Filtered) of
                    {badrpc, Reason} -> Reason;
                    Reason -> Reason
                end
            )
    end.

'/relup/status/:node'(get, #{bindings := #{node := NodeNameStr}}) ->
    emqx_utils_api:with_node(
        NodeNameStr,
        fun
            (Node) when node() =:= Node ->
                {200, get_upgrade_status()};
            (Node) when is_atom(Node) ->
                {200, emqx_mgmt_api_relup_proto_v1:get_upgrade_status(Node)}
        end
    ).

'/relup/upgrade'(post, _) ->
    ?ASSERT_PKG_READY(
        upgrade_with_targe_vsn(fun(TargetVsn) ->
            run_upgrade_on_nodes(emqx:running_nodes(), TargetVsn)
        end)
    ).

'/relup/upgrade/:node'(post, #{bindings := #{node := NodeNameStr}}) ->
    ?ASSERT_PKG_READY(
        upgrade_with_targe_vsn(
            fun(TargetVsn) ->
                emqx_utils_api:with_node(
                    NodeNameStr,
                    fun
                        (Node) when node() =:= Node ->
                            run_upgrade(TargetVsn);
                        (Node) when is_atom(Node) ->
                            run_upgrade_on_nodes([Node], TargetVsn)
                    end
                )
            end
        )
    ).
%%==============================================================================
%% Helper functions

install_as_hidden_plugin(NameVsn, Params) ->
    case emqx_mgmt_api_plugins:upload_install(post, Params) of
        {204} ->
            case emqx_mgmt_api_plugins_proto_v3:ensure_action(NameVsn, start) of
                ok ->
                    {204};
                {error, Reason} ->
                    %% try our best to clean up if start failed
                    _ = emqx_mgmt_api_plugins_proto_v3:delete_package(NameVsn),
                    return_internal_error(Reason)
            end;
        ErrResp ->
            ErrResp
    end.

assert_relup_pkg_name(UploadBody) ->
    [{FileName, _Bin}] = maps:to_list(maps:without([type], UploadBody)),
    case string:split(FileName, "-") of
        [?PLUGIN_NAME, _] ->
            {ok, string:trim(FileName, trailing, ".tar.gz")};
        _ ->
            {error, <<"Invalid relup package name: ", FileName/binary>>}
    end.

get_upgrade_status() ->
    #{
        node => node(),
        role => mria_rlog:role(),
        live_connections => emqx_cm:get_connected_client_count(),
        current_vsn => list_to_binary(emqx_release:version()),
        status => call_emqx_relup_main(get_latest_upgrade_status, [], idle),
        upgrade_history => call_emqx_relup_main(get_all_upgrade_logs, [], [])
    }.

call_emqx_relup_main(Fun, Args, Default) ->
    case erlang:function_exported(emqx_relup_main, Fun, length(Args)) of
        true ->
            erlang:apply(emqx_relup_main, Fun, Args);
        false ->
            %% relup package is not installed
            Default
    end.

upgrade_with_targe_vsn(Fun) ->
    case get_target_vsn() of
        {ok, TargetVsn} ->
            Fun(TargetVsn);
        {error, no_relup_package_installed} ->
            return_package_not_installed();
        {error, multiple_relup_packages_installed} ->
            return_internal_error(<<"Multiple relup package installed">>)
    end.

run_upgrade_on_nodes(Nodes, TargetVsn) ->
    {[_ | _] = Res, []} = emqx_mgmt_api_relup_proto_v1:run_upgrade(Nodes, TargetVsn),
    case lists:filter(fun(R) -> R =/= ok end, Res) of
        [] ->
            {204};
        Filtered ->
            case hd(Filtered) of
                no_pkg_installed -> return_package_not_installed();
                {badrpc, Reason} -> return_internal_error(Reason);
                {error, Reason} -> upgrade_return(Reason);
                Reason -> return_internal_error(Reason)
            end
    end.

run_upgrade(TargetVsn) ->
    case emqx_relup_upgrade(TargetVsn) of
        no_pkg_installed -> return_package_not_installed();
        ok -> {204};
        {error, Reason} -> upgrade_return(Reason)
    end.

emqx_relup_upgrade(TargetVsn) ->
    call_emqx_relup_main(upgrade, [TargetVsn], no_pkg_installed).

get_target_vsn() ->
    case get_installed_packages() of
        [PackageInfo] -> {ok, target_vsn_from_rel_vsn(maps_get(rel_vsn, PackageInfo))};
        [] -> {error, no_relup_package_installed};
        _ -> {error, multiple_relup_packages_installed}
    end.

get_installed_packages() ->
    lists:filtermap(
        fun(PackageInfo) ->
            case maps_get(name, PackageInfo) of
                ?PLUGIN_NAME -> true;
                _ -> false
            end
        end,
        emqx_plugins:list(hidden)
    ).

target_vsn_from_rel_vsn(Vsn) ->
    case string:split(binary_to_list(Vsn), "-") of
        [_] -> throw({invalid_vsn, Vsn});
        [VsnStr | _] -> VsnStr
    end.

delete_installed_packages() ->
    lists:foreach(
        fun(PackageInfo) ->
            ok = emqx_mgmt_api_plugins_proto_v3:delete_package(
                name_vsn(?PLUGIN_NAME, maps_get(rel_vsn, PackageInfo))
            )
        end,
        get_installed_packages()
    ).

format_package_info(PluginInfo) when is_map(PluginInfo) ->
    Vsn = maps_get(rel_vsn, PluginInfo),
    TargetVsn = target_vsn_from_rel_vsn(Vsn),
    case call_emqx_relup_main(get_package_info, [TargetVsn], no_pkg_installed) of
        no_pkg_installed ->
            throw({get_pkg_info_failed, <<"No relup package is installed">>});
        {error, Reason} ->
            throw({get_pkg_info_failed, Reason});
        {ok, #{base_vsns := BaseVsns, change_logs := ChangeLogs}} ->
            #{
                name => name_vsn(?PLUGIN_NAME, Vsn),
                target_vsn => Vsn,
                built_on_otp_release => maps_get(built_on_otp_release, PluginInfo),
                applicable_vsns => BaseVsns,
                build_date => maps_get(git_commit_or_build_date, PluginInfo),
                change_logs => ChangeLogs,
                md5_sum => maps_get(md5sum, PluginInfo)
            }
    end.

maps_get(Key, Map) when is_atom(Key) ->
    maps_get(Key, Map, unknown).

maps_get(Key, Map, Def) when is_atom(Key) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> maps:get(atom_to_binary(Key, utf8), Map, Def)
    end.

upgrade_return(#{stage := check_and_unpack} = Reason) ->
    return_bad_request(Reason);
upgrade_return(Reason) ->
    return_internal_error(Reason).

return_not_found(Reason) ->
    {404, #{
        code => 'NOT_FOUND',
        message => emqx_utils:readable_error_msg(Reason)
    }}.

return_package_not_installed() ->
    return_bad_request(<<"No relup package is installed">>).

return_bad_request(Reason) ->
    {400, #{
        code => 'BAD_REQUEST',
        message => emqx_utils:readable_error_msg(Reason)
    }}.

return_internal_error(Reason) ->
    {500, #{
        code => 'INTERNAL_ERROR',
        message => emqx_utils:readable_error_msg(Reason)
    }}.

name_vsn(Name, Vsn) ->
    iolist_to_binary([Name, "-", Vsn]).
