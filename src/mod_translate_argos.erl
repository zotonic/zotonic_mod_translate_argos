%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Translation service using Argos Translate.
%% @end

%% Copyright 2026 Marc Worrell
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

-module(mod_translate_argos).

-mod_title("Translate with Argos").
-mod_description("Translation service using Argos Translate.").
-mod_author("Marc Worrell <marc@worrell.nl>").
-mod_depends([ mod_translation ]).
-mod_schema(1).
-mod_config([
        #{
            key => timeout,
            type => integer,
            default => 120000,
            description => "Maximum translation runtime in milliseconds."
        }
    ]).

-author("Marc Worrell <marc@worrell.nl>").

-export([
    event/2,
    manage_data/2,
    manage_schema/2,
    observe_translate/2,
    observe_admin_menu/3
    ]).

-include_lib("zotonic_core/include/zotonic.hrl").
-include_lib("zotonic_mod_admin/include/admin_menu.hrl").

%% @doc No schema changes are needed for this module.
manage_schema(_Version, _Context) ->
    ok.

%% @doc Install the shared Python dependencies when the module is installed.
manage_data(_Version, _Context) ->
    case m_translate_argos:install_python() of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR(#{
                in => ?MODULE,
                text => <<"Could not install Argos Translate Python dependencies">>,
                result => error,
                reason => Reason
            }),
            ok
    end.

%% @doc Handle translation notifications from mod_translation.
observe_translate(#translate{
        type = Type,
        from = From,
        to = To,
        texts = Texts
    }, Context) ->
    case z_acl:is_allowed(use, ?MODULE, Context) of
        true ->
            case translate_texts(Type, From, To, Texts, Context) of
                {ok, _} = Ok ->
                    Ok;
                {error, _} ->
                    undefined
            end;
        false ->
            ?LOG_INFO(#{
                in => ?MODULE,
                text => <<"Not allowed to use Argos Translate for translations">>,
                result => error,
                reason => eacces
            }),
            undefined
    end.

%% @doc Dispatch text and HTML translation to the matching model function.
translate_texts(html, From, To, Texts, Context) ->
    m_translate_argos:translate_html(From, To, Texts, Context);
translate_texts(_Type, From, To, Texts, Context) ->
    m_translate_argos:translate(From, To, Texts, Context).

%% @doc Add the Argos Translate configuration page to the admin menu.
observe_admin_menu(#admin_menu{}, Acc, Context) ->
    [
        #menu_item{
            id = admin_translate_argos,
            parent = admin_system,
            label = ?__("Argos Translate", Context),
            url = {admin_translate_argos},
            visiblecheck = {acl, use, mod_admin_config}
        }
        | Acc
    ].

%% @doc Handle admin postbacks for loading, installing, and updating packages.
event(#postback{message = {argos_install_package, Args}}, Context) ->
    case z_acl:is_allowed(use, mod_admin_config, Context) of
        true ->
            PackageName = z_convert:to_binary(proplists:get_value(name, Args, <<>>)),
            Target = z_convert:to_binary(proplists:get_value(target, Args, <<>>)),
            case m_translate_argos:install_package(PackageName, Context) of
                {ok, _} ->
                    Context1 = z_render:growl(?__("Installed Argos Translate package.", Context), Context),
                    update_package_row(PackageName, Target, Context1);
                {error, Reason} ->
                    Context1 = z_render:growl_error(format_error(Reason, Context), Context),
                    z_render:wire({unmask, [{target, Target}]}, Context1)
            end;
        false ->
            z_render:growl_error(?__("You are not allowed to configure Argos Translate.", Context), Context)
    end;
event(#postback{message = {argos_load_packages, Args}}, Context) ->
    Target = z_convert:to_binary(proplists:get_value(target, Args, <<>>)),
    case z_acl:is_allowed(use, mod_admin_config, Context) of
        true ->
            update_packages_list(Target, Context);
        false ->
            z_render:growl_error(?__("You are not allowed to configure Argos Translate.", Context), Context)
    end;
event(#postback{message = {argos_update_packages, Args}}, Context) ->
    Target = z_convert:to_binary(proplists:get_value(target, Args, <<>>)),
    case z_acl:is_allowed(use, mod_admin_config, Context) of
        true ->
            case m_translate_argos:update_packages(Context) of
                {ok, _} ->
                    Context1 = z_render:growl(?__("Updated the Argos Translate package index.", Context), Context),
                    update_packages_list(Target, Context1);
                {error, Reason} ->
                    Context1 = z_render:growl_error(format_error(Reason, Context), Context),
                    z_render:wire({unmask, [{target, Target}]}, Context1)
            end;
        false ->
            z_render:growl_error(?__("You are not allowed to configure Argos Translate.", Context), Context)
    end.

%% @doc Re-render one package row after an install or update.
update_package_row(_PackageName, <<>>, Context) ->
    Context;
update_package_row(PackageName, Target, Context) ->
    case m_translate_argos:package(PackageName, Context) of
        undefined ->
            Context;
        Package ->
            z_render:update(
                Target,
                #render{
                    template = "_admin_translate_argos_package.tpl",
                    vars = [
                        {p, Package},
                        {row_id, Target}
                    ]
                },
                Context)
    end.

%% @doc Lazily render the package list into the admin page.
update_packages_list(<<>>, Context) ->
    Context;
update_packages_list(Target, Context) ->
    z_render:update(
        Target,
        #render{
            template = "_admin_translate_argos_packages.tpl"
        },
        Context).

%% @doc Format a worker error as escaped admin UI text.
format_error(Reason, Context) ->
    [
        ?__("Argos Translate returned an error:", Context),
        " ",
        z_html:escape(z_convert:to_binary(Reason))
    ].
