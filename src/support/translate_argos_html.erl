%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc HTML segmentation and recombination for Argos Translate.
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

-module(translate_argos_html).

-export([
    translate/4
]).

%% @doc Translate HTML while preserving block structure and inline tags.
translate(SourceCode, TargetCode, Texts, Context) when is_list(Texts) ->
    Prepared = [ prepare_html(Text) || Text <- Texts ],
    SegmentItems = lists:append([ maps:get(segments, Item) || Item <- Prepared ]),
    SegmentTexts = lists:append([ segment_texts(Segment) || Segment <- SegmentItems ]),
    case translate_html_segments(SourceCode, TargetCode, SegmentTexts, Context) of
        {ok, TranslatedTexts} ->
            {ok, recombine_html_texts(Prepared, bind_segment_translations(SegmentItems, TranslatedTexts))};
        {error, _} = Error ->
            Error
    end.

%% @doc Return all translatable strings for one HTML segment.
segment_texts(Segment) ->
    [
        maps:get(text, Segment)
        | [ maps:get(value, Attr) || Attr <- maps:get(attrs, Segment, []) ]
    ].

%% @doc Attach translated text and attribute values back to segment maps.
bind_segment_translations([], []) ->
    [];
bind_segment_translations([Segment | Segments], [Text | TranslatedTexts]) ->
    AttrCount = length(maps:get(attrs, Segment, [])),
    {TranslatedAttrs, TranslatedTexts1} = lists:split(AttrCount, TranslatedTexts),
    [
        Segment#{
            translated_text => Text,
            translated_attrs => TranslatedAttrs
        }
        | bind_segment_translations(Segments, TranslatedTexts1)
    ].

%% @doc Translate the collected HTML segment strings, preserving temporary tags.
translate_html_segments(_SourceCode, _TargetCode, [], _Context) ->
    {ok, []};
translate_html_segments(SourceCode, TargetCode, Segments, Context) ->
    m_translate_argos:translate_tags(SourceCode, TargetCode, Segments, Context).

%% @doc Parse an HTML fragment under a synthetic root and collect segments.
prepare_html(Html) ->
    case z_html_parse:parse([<<"<translate>">>, Html, <<"</translate>">>]) of
        {ok, {<<"translate">>, _Attrs, Elts}} ->
            {Elts1, Segments} = extract_html_segments(Elts, []),
            #{
                tree => Elts1,
                segments => lists:reverse(Segments)
            };
        {error, _Reason} ->
            #{
                tree => [ {argos_segment} ],
                segments => [
                    #{
                        text => Html,
                        replacements => #{}
                    }
                ]
            }
    end.

%% @doc Replace inline-only element lists with translatable segment placeholders.
extract_html_segments(Elts, Segments) when is_list(Elts) ->
    case is_translatable_inline_list(Elts) of
        true ->
            {TempElts, Replacements, Attrs} = temporary_inline_tags(Elts),
            Segment = #{
                text => iolist_to_binary(flatten_html(TempElts)),
                attrs => Attrs,
                replacements => Replacements
            },
            { [ {argos_segment} ], [ Segment | Segments ] };
        false ->
            {Elts1, Segments1} = lists:foldl(
                fun(Elt, {AccElts, AccSegments}) ->
                    {Elt1, AccSegments1} = extract_html_element(Elt, AccSegments),
                    { [ Elt1 | AccElts ], AccSegments1 }
                end,
                {[], Segments},
                Elts),
            {lists:reverse(Elts1), Segments1}
    end.

%% @doc Descend into one parsed HTML element to extract nested segments.
extract_html_element({comment, Comment}, Segments) ->
    case z_media_caption(Comment) of
        {ok, Caption} ->
            Segment = #{
                text => Caption,
                attrs => [],
                replacements => #{},
                z_media => Comment
            },
            {{argos_z_media}, [ Segment | Segments ]};
        false ->
            {{comment, Comment}, Segments}
    end;
extract_html_element({Tag, Attrs, Elts}, Segments) when is_list(Elts) ->
    case is_preserved_content_tag(Tag) of
        true ->
            {{Tag, Attrs, Elts}, Segments};
        false ->
            {Elts1, Segments1} = extract_html_segments(Elts, Segments),
            {{Tag, Attrs, Elts1}, Segments1}
    end;
extract_html_element(Elt, Segments) ->
    {Elt, Segments}.

%% @doc Replace original inline tags with simple temporary tags.
temporary_inline_tags(Elts) ->
    {TempElts, _Nr, Replacements, Attrs} = temporary_inline_tags(Elts, 1, #{}, []),
    {TempElts, Replacements, lists:reverse(Attrs)}.

%% @doc Walk inline elements while collecting replacements and attributes.
temporary_inline_tags([], Nr, Replacements, Attrs) ->
    {[], Nr, Replacements, Attrs};
temporary_inline_tags([Elt | Elts], Nr, Replacements, Attrs) ->
    {Elt1, Nr1, Replacements1, Attrs1} = temporary_inline_tag(Elt, Nr, Replacements, Attrs),
    {Elts1, Nr2, Replacements2, Attrs2} = temporary_inline_tags(Elts, Nr1, Replacements1, Attrs1),
    {[ Elt1 | Elts1 ], Nr2, Replacements2, Attrs2}.

%% @doc Convert one inline element to a temporary tag when needed.
temporary_inline_tag(B, Nr, Replacements, Attrs) when is_binary(B) ->
    {B, Nr, Replacements, Attrs};
temporary_inline_tag({comment, Comment}, Nr, Replacements, Attrs) ->
    TempTag = temporary_tag(Nr),
    {Replacement, Attrs1} = temporary_comment_replacement(TempTag, Comment, Attrs),
    {{TempTag, [], []}, Nr + 1, Replacements#{ TempTag => Replacement }, Attrs1};
temporary_inline_tag({Tag}, Nr, Replacements, Attrs) ->
    temporary_inline_tag({Tag, [], []}, Nr, Replacements, Attrs);
temporary_inline_tag({Tag, Elts}, Nr, Replacements, Attrs) when is_list(Elts) ->
    temporary_inline_tag({Tag, [], Elts}, Nr, Replacements, Attrs);
temporary_inline_tag({Tag, AttrList, Elts}, Nr, Replacements, Attrs) when is_list(Elts) ->
    TempTag = temporary_tag(Nr),
    Attrs1 = translatable_attrs(TempTag, AttrList, Attrs),
    {Elts1, Nr1, Replacements1, Attrs2, ReplacementElts} = temporary_inline_tag_elts(Tag, Elts, Nr, Replacements, Attrs1),
    Replacement = preserved_replacement(Tag, #{
        tag => Tag,
        attrs => AttrList,
        self_closing => is_self_closing(Tag)
    }, ReplacementElts),
    TempElts = {TempTag, [], Elts1},
    {TempElts, Nr1, Replacements1#{ TempTag => Replacement }, Attrs2};
temporary_inline_tag(Elt, Nr, Replacements, Attrs) ->
    {Elt, Nr, Replacements, Attrs}.

%% @doc Build a replacement for a preserved HTML comment.
temporary_comment_replacement(TempTag, Comment, Attrs) ->
    Replacement = #{
        type => comment,
        comment => Comment
    },
    case z_media_caption(Comment) of
        {ok, Caption} ->
            {
                Replacement#{
                    type => z_media_comment
                },
                [
                    #{
                        tag => TempTag,
                        name => <<"caption">>,
                        value => Caption
                    }
                    | Attrs
                ]
            };
        false ->
            {Replacement, Attrs}
    end.

%% @doc Return translated placeholder children or preserve original children.
temporary_inline_tag_elts(Tag, Elts, Nr, Replacements, Attrs) ->
    case is_preserved_content_tag(Tag) of
        true ->
            {[], Nr + 1, Replacements, Attrs, Elts};
        false ->
            {Elts1, Nr1, Replacements1, Attrs1} = temporary_inline_tags(Elts, Nr + 1, Replacements, Attrs),
            {Elts1, Nr1, Replacements1, Attrs1, undefined}
    end.

%% @doc Store original element children when a tag's content must not translate.
preserved_replacement(_Tag, Replacement, undefined) ->
    Replacement;
preserved_replacement(_Tag, Replacement, Elts) ->
    Replacement#{ preserved_elts => Elts }.

%% @doc Collect translatable attributes for one temporary tag.
translatable_attrs(TempTag, Attrs, Acc) ->
    lists:foldl(
        fun
            ({Name, Value}, Acc1) ->
                case is_translatable_attr(Name) andalso has_attr_text(Value) of
                    true ->
                        [
                            #{
                                tag => TempTag,
                                name => Name,
                                value => attr_value_to_binary(Value)
                            }
                            | Acc1
                        ];
                    false ->
                        Acc1
                end;
            (_Attr, Acc1) ->
                Acc1
        end,
        Acc,
        Attrs).

%% @doc Check if an attribute name should be translated.
is_translatable_attr(<<"title">>) -> true;
is_translatable_attr(<<"alt">>) -> true;
is_translatable_attr(<<"aria-label">>) -> true;
is_translatable_attr("title") -> true;
is_translatable_attr("alt") -> true;
is_translatable_attr("aria-label") -> true;
is_translatable_attr(_) -> false.

%% @doc Check if an attribute value has non-whitespace text.
has_attr_text(Value) ->
    z_string:trim(z_html:unescape(attr_value_to_binary(Value))) =/= <<>>.

%% @doc Return the caption HTML from a z-media comment.
z_media_caption(<<" z-media ", ZMedia/binary>>) ->
    try
        [_Id, Opts] = binary:split(ZMedia, <<" {">>),
        case z_json:decode(<<${, Opts/binary>>) of
            #{ <<"caption">> := Caption } when is_binary(Caption) ->
                {ok, Caption};
            _ ->
                false
        end
    catch
        _:_ ->
            false
    end;
z_media_caption(_Comment) ->
    false.

%% @doc Replace the caption HTML in a z-media comment.
set_z_media_caption(<<" z-media ", ZMedia/binary>> = Comment, Caption) ->
    try
        [Id, Opts] = binary:split(ZMedia, <<" {">>),
        case z_json:decode(<<${, Opts/binary>>) of
            OptsMap when is_map(OptsMap) ->
                Opts1 = OptsMap#{ <<"caption">> => Caption },
                <<" z-media ", (z_string:trim(Id))/binary, " ", (z_json:encode(Opts1))/binary, " ">>;
            _ ->
                Comment
        end
    catch
        _:_ ->
            Comment
    end.

%% @doc Convert an attribute value to unicode binary text.
attr_value_to_binary(Value) when is_binary(Value) ->
    Value;
attr_value_to_binary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
attr_value_to_binary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [ Value ])).

%% @doc Generate a simple temporary tag name such as xa or xb.
temporary_tag(Nr) ->
    iolist_to_binary([<<"x">>, temporary_tag_suffix(Nr)]).

%% @doc Convert a positive sequence number to a tag suffix.
temporary_tag_suffix(Nr) when Nr > 0 ->
    temporary_tag_suffix(Nr, []).

temporary_tag_suffix(Nr, Acc) when Nr > 0 ->
    N = Nr - 1,
    C = $a + (N rem 26),
    N1 = N div 26,
    case N1 of
        0 -> [ C | Acc ];
        _ -> temporary_tag_suffix(N1, [ C | Acc ])
    end.

%% @doc Check if a parsed element list can be translated as one inline segment.
is_translatable_inline_list(Elts) ->
    has_text(Elts) andalso lists:all(fun is_inline_html/1, Elts).

%% @doc Check if a parsed HTML node is text, comment, or an inline tag tree.
is_inline_html(B) when is_binary(B) ->
    true;
is_inline_html({comment, _Comment}) ->
    true;
is_inline_html({Tag}) ->
    is_inline_tag(Tag);
is_inline_html({Tag, Elts}) when is_list(Elts) ->
    is_inline_tag(Tag) andalso lists:all(fun is_inline_html/1, Elts);
is_inline_html({Tag, _Attrs, Elts}) when is_list(Elts) ->
    is_inline_tag(Tag) andalso lists:all(fun is_inline_html/1, Elts);
is_inline_html(_) ->
    false.

%% @doc Check if a parsed HTML tree contains visible text.
has_text(Elts) when is_list(Elts) ->
    lists:any(fun has_text/1, Elts);
has_text(B) when is_binary(B) ->
    z_string:trim(z_html:unescape(B)) =/= <<>>;
has_text({_Tag, Elts}) when is_list(Elts) ->
    has_text(Elts);
has_text({_Tag, _Attrs, Elts}) when is_list(Elts) ->
    has_text(Elts);
has_text(_) ->
    false.

%% @doc Check if the text content of an inline tag must not be translated.
is_preserved_content_tag(<<"code">>) -> true;
is_preserved_content_tag(<<"script">>) -> true;
is_preserved_content_tag(<<"style">>) -> true;
is_preserved_content_tag("code") -> true;
is_preserved_content_tag("script") -> true;
is_preserved_content_tag("style") -> true;
is_preserved_content_tag(_) -> false.

%% @doc Replace segment placeholders in all prepared trees with translated HTML.
recombine_html_texts([], []) ->
    [];
recombine_html_texts([Prepared | Rest], Segments) ->
    {Tree, Segments1} = replace_html_segments(maps:get(tree, Prepared), Segments),
    [ iolist_to_binary(flatten_html(Tree)) | recombine_html_texts(Rest, Segments1) ].

%% @doc Walk a parsed tree and replace segment placeholders with translated nodes.
replace_html_segments([], Segments) ->
    {[], Segments};
replace_html_segments([ {argos_segment} | Rest ], [ Segment | Segments ]) ->
    Replacements = translated_replacements(Segment),
    Text1 = maps:get(translated_text, Segment),
    SegmentElts = restore_temporary_tags(
        parse_html_fragment(Text1),
        Replacements),
    {Rest1, Segments1} = replace_html_segments(Rest, Segments),
    {SegmentElts ++ Rest1, Segments1};
replace_html_segments([ {argos_z_media} | Rest ], [ Segment | Segments ]) ->
    Comment = set_z_media_caption(
        maps:get(z_media, Segment),
        maps:get(translated_text, Segment)),
    {Rest1, Segments1} = replace_html_segments(Rest, Segments),
    {[ {comment, Comment} | Rest1 ], Segments1};
replace_html_segments([ {Tag, Attrs, Elts} | Rest ], Segments) when is_list(Elts) ->
    {Elts1, Segments1} = replace_html_segments(Elts, Segments),
    {Rest1, Segments2} = replace_html_segments(Rest, Segments1),
    {[ {Tag, Attrs, Elts1} | Rest1 ], Segments2};
replace_html_segments([ Elt | Rest ], Segments) ->
    {Rest1, Segments1} = replace_html_segments(Rest, Segments),
    {[ Elt | Rest1 ], Segments1}.

%% @doc Parse translated HTML returned by the Python worker.
parse_html_fragment(Html) ->
    case z_html_parse:parse([<<"<translate>">>, Html, <<"</translate>">>]) of
        {ok, {<<"translate">>, _Attrs, Elts}} -> Elts;
        {error, _Reason} -> [ Html ]
    end.

%% @doc Restore a list or single parsed node from temporary tags.
restore_temporary_tags(Elts, Replacements) when is_list(Elts) ->
    [ restore_temporary_tag(Elt, Replacements) || Elt <- Elts ];
restore_temporary_tags(Elt, Replacements) ->
    restore_temporary_tag(Elt, Replacements).

%% @doc Restore one parsed temporary tag to the original HTML tag.
restore_temporary_tag({Tag, _Attrs, Elts}, Replacements) when is_map_key(Tag, Replacements) ->
    restore_temporary_replacement(maps:get(Tag, Replacements), Elts, Replacements);
restore_temporary_tag({Tag, Attrs, Elts}, Replacements) when is_list(Elts) ->
    {Tag, Attrs, restore_temporary_tags(Elts, Replacements)};
restore_temporary_tag({Tag, Elts}, Replacements) when is_list(Elts) ->
    {Tag, restore_temporary_tags(Elts, Replacements)};
restore_temporary_tag(Elt, _Replacements) ->
    Elt.

%% @doc Restore a temporary replacement to its original parsed node.
restore_temporary_replacement(#{ type := comment, comment := Comment }, _Elts, _Replacements) ->
    {comment, Comment};
restore_temporary_replacement(#{ type := z_media_comment, comment := Comment }, _Elts, _Replacements) ->
    {comment, Comment};
restore_temporary_replacement(Replacement, Elts, Replacements) ->
    #{
        tag := OriginalTag,
        attrs := OriginalAttrs,
        self_closing := IsSelfClosing
    } = Replacement,
    OriginalElts = maps:get(preserved_elts, Replacement, Elts),
    restore_temporary_tag_1(OriginalTag, OriginalAttrs, OriginalElts, IsSelfClosing, Replacements).

%% @doc Restore a temporary tag as self-closing or with restored children.
restore_temporary_tag_1(OriginalTag, OriginalAttrs, _Elts, true, _Replacements) ->
    {OriginalTag, OriginalAttrs, []};
restore_temporary_tag_1(OriginalTag, OriginalAttrs, Elts, false, Replacements) ->
    {OriginalTag, OriginalAttrs, restore_temporary_tags(Elts, Replacements)}.

%% @doc Merge translated attribute values into the temporary tag replacements.
translated_replacements(Segment) ->
    Attrs = maps:get(attrs, Segment, []),
    TranslatedAttrs = maps:get(translated_attrs, Segment, []),
    lists:foldl(
        fun({Attr, Value}, Replacements) ->
            TempTag = maps:get(tag, Attr),
            Name = maps:get(name, Attr),
            Replacement = maps:get(TempTag, Replacements),
            Replacement1 = translated_replacement_value(Name, Value, Replacement),
            Replacements#{ TempTag => Replacement1 }
        end,
        maps:get(replacements, Segment),
        lists:zip(Attrs, TranslatedAttrs)).

%% @doc Store a translated value in a replacement map.
translated_replacement_value(<<"caption">>, Value, #{ type := z_media_comment, comment := Comment } = Replacement) ->
    Replacement#{ comment => set_z_media_caption(Comment, Value) };
translated_replacement_value(Name, Value, Replacement) ->
    OriginalAttrs = maps:get(attrs, Replacement),
    Replacement#{ attrs => replace_attr(Name, Value, OriginalAttrs) }.

%% @doc Replace one attribute in an attribute list.
replace_attr(Name, Value, Attrs) ->
    [ replace_attr_1(Name, Value, Attr) || Attr <- Attrs ].

%% @doc Replace a matching attribute tuple, leaving others unchanged.
replace_attr_1(Name, Value, {Name, _OldValue}) ->
    {Name, Value};
replace_attr_1(_Name, _Value, Attr) ->
    Attr.

%% @doc Render a parsed HTML tree back to escaped HTML.
flatten_html(Text) when is_binary(Text) ->
    z_html:escape(Text);
flatten_html({comment, Text}) ->
    [ <<"<!--">>, Text, <<"-->">> ];
flatten_html({Tag, Args, Enclosed}) ->
    case Enclosed == [] andalso is_self_closing(Tag) of
        true ->
            [ $<, Tag, flatten_args(Args), $/, $> ];
        false ->
            [
                $<, Tag, flatten_args(Args), $>,
                [ flatten_html(Enc) || Enc <- Enclosed ],
                $<, $/, Tag, $>
            ]
    end;
flatten_html({Tag, Enclosed}) ->
    flatten_html({Tag, [], Enclosed});
flatten_html({Tag}) ->
    flatten_html({Tag, [], []});
flatten_html(L) when is_list(L) ->
    lists:map(fun flatten_html/1, L);
flatten_html(_) ->
    [].

%% @doc Render all HTML attributes for one tag.
flatten_args(Args) ->
    [ flatten_arg(Arg) || Arg <- Args ].

%% @doc Render and escape one HTML attribute.
flatten_arg({Name, Value}) ->
    [ 32, Name, $=, $", z_html:escape(z_convert:to_binary(Value)), $" ].

%% @doc Check if an HTML tag is self-closing.
is_self_closing(<<"area">>) -> true;
is_self_closing(<<"base">>) -> true;
is_self_closing(<<"br">>) -> true;
is_self_closing(<<"col">>) -> true;
is_self_closing(<<"embed">>) -> true;
is_self_closing(<<"hr">>) -> true;
is_self_closing(<<"img">>) -> true;
is_self_closing(<<"input">>) -> true;
is_self_closing(<<"link">>) -> true;
is_self_closing(<<"meta">>) -> true;
is_self_closing(<<"param">>) -> true;
is_self_closing(<<"source">>) -> true;
is_self_closing(<<"track">>) -> true;
is_self_closing(<<"wbr">>) -> true;
is_self_closing(_) -> false.

%% @doc Check if an HTML tag is treated as inline for segment extraction.
is_inline_tag(<<"a">>) -> true;
is_inline_tag(<<"abbr">>) -> true;
is_inline_tag(<<"b">>) -> true;
is_inline_tag(<<"bdi">>) -> true;
is_inline_tag(<<"bdo">>) -> true;
is_inline_tag(<<"br">>) -> true;
is_inline_tag(<<"cite">>) -> true;
is_inline_tag(<<"code">>) -> true;
is_inline_tag(<<"data">>) -> true;
is_inline_tag(<<"del">>) -> true;
is_inline_tag(<<"dfn">>) -> true;
is_inline_tag(<<"em">>) -> true;
is_inline_tag(<<"font">>) -> true;
is_inline_tag(<<"i">>) -> true;
is_inline_tag(<<"img">>) -> true;
is_inline_tag(<<"ins">>) -> true;
is_inline_tag(<<"kbd">>) -> true;
is_inline_tag(<<"mark">>) -> true;
is_inline_tag(<<"q">>) -> true;
is_inline_tag(<<"s">>) -> true;
is_inline_tag(<<"samp">>) -> true;
is_inline_tag(<<"small">>) -> true;
is_inline_tag(<<"span">>) -> true;
is_inline_tag(<<"strong">>) -> true;
is_inline_tag(<<"sub">>) -> true;
is_inline_tag(<<"sup">>) -> true;
is_inline_tag(<<"time">>) -> true;
is_inline_tag(<<"tt">>) -> true;
is_inline_tag(<<"u">>) -> true;
is_inline_tag(<<"var">>) -> true;
is_inline_tag(<<"wbr">>) -> true;
is_inline_tag(_) -> false.
