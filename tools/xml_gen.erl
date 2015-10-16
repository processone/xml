%%%----------------------------------------------------------------------
%%% File    : xml_gen.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Purpose : XML code generator
%%% Created : 22 Jun 2009 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% Copyright (C) 2002-2015 ProcessOne, SARL. All Rights Reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%%----------------------------------------------------------------------

-module(xml_gen).

-compile(debug_info).
%% Generator API
-export([compile/1, compile/2]).
%% Runtime API
-export([format_error/1, get_attr/2]).
%% Runtime built-in decoders/encoders
-export([dec_int/1, dec_int/3, dec_enum/2,
         enc_int/1, enc_enum/1, not_empty/1]).

-include("xml_gen.hrl").
-include("xml.hrl").

-define(err(F, Args),
	begin
	    io:format("** xml_gen error: " ++ F ++ "~n", Args),
	    erlang:error(badarg)
	end).

-define(info(F, Args), io:format("xml_gen: " ++ F ++ "~n", Args)).
-define(warn(F, Args), io:format("* xml_gen warning: " ++ F ++ "~n", Args)).

%%====================================================================
%% Compiler API
%%====================================================================
compile(Path) ->
    compile(Path, []).

compile(Path, Opts) ->
    case catch do_compile(Path, Opts) of
        ok ->
            ok;
        Err ->
            io:format("compile failed: ~p~n", [Err]),
            Err
    end.

do_compile(Path, Opts) ->
    case consult(Path) of
        {ok, Terms, Forms} ->
            Elems = lists:flatmap(
                      fun({Tag, Elem}) when is_atom(Tag),
                                            is_record(Elem, elem) ->
                              [{Tag, Elem}];
                         (_) ->
                              []
                      end, Terms),
            compile(Elems, Forms, Path, Opts);
        Err ->
            Err
    end.

%%====================================================================
%% Runtime decoders/encoders
%%====================================================================
-spec dec_int(binary()) -> integer().

dec_int(Val) ->
    dec_int(Val, infinity, infinity).

dec_int(Val, Min, Max) ->
    case list_to_integer(binary_to_list(Val)) of
        Int when Int =< Max, Min == infinity ->
            Int;
        Int when Int =< Max, Int >= Min ->
            Int
    end.

-spec enc_int(integer()) -> binary().

enc_int(Int) ->
    list_to_binary(integer_to_list(Int)).

-spec dec_enum(binary(), [atom()]) -> atom().

dec_enum(Val, Enums) ->
    AtomVal = erlang:binary_to_existing_atom(Val, utf8),
    case lists:member(AtomVal, Enums) of
        true ->
            AtomVal
    end.

-spec enc_enum(atom()) -> binary().

enc_enum(Atom) ->
    erlang:atom_to_binary(Atom, utf8).

-spec not_empty(binary()) -> binary().

not_empty(<<_, _/binary>> = Val) ->
    Val.

format_error({bad_attr_value, Attr, Tag, XMLNS}) ->
    <<"Bad value of attribute '", Attr/binary,
      "' in tag <", Tag/binary, "/> qualified by namespace '",
      XMLNS/binary, "'">>;
format_error({bad_cdata_value, <<>>, Tag, XMLNS}) ->
    <<"Bad value of cdata in tag <", Tag/binary,
      "/> qualified by namespace '", XMLNS/binary, "'">>;
format_error({missing_tag, Tag, XMLNS}) ->
    <<"Missing tag <", Tag/binary,
      "/> qualified by namespace '", XMLNS/binary, "'">>;
format_error({missing_attr, Attr, Tag, XMLNS}) ->
    <<"Missing attribute '", Attr/binary,
      "' in tag <", Tag/binary,
      "/> qualified by namespace '", XMLNS/binary, "'">>;
format_error({missing_cdata, <<>>, Tag, XMLNS}) ->
    <<"Missing cdata in tag <", Tag/binary,
      "/> qualified by namespace '", XMLNS/binary, "'">>;
format_error({unknown_tag, Tag, XMLNS}) ->
    <<"Unknown tag <", Tag/binary,
      "/> qualified by namespace '", XMLNS/binary, "'">>.

get_attr(Attr, Attrs) ->
    case lists:keyfind(Attr, 1, Attrs) of
        {_, Val} -> Val;
        false -> <<>>
    end.

%%====================================================================
%% Internal functions
%%====================================================================
compile(TaggedElems, Forms, Path, Opts) ->
    KnownFuns = lists:flatmap(
                  fun(F) ->
                          case erl_syntax:type(F) of
                              function ->
                                  [erl_syntax_lib:analyze_function(F)];
                              _ ->
                                  []
                          end
                  end, Forms),
    Dups = get_dups([Tag || {Tag, _} <- TaggedElems]),
    if Dups /= [] ->
            bad_spec({duplicated_elem_specs, Dups});
       true ->
            ok
    end,
    Dups1 = get_dups([{Elem#elem.name, Elem#elem.xmlns}
                      || {_, Elem} <- TaggedElems]),
    if Dups1 /= [] ->
            bad_spec({duplicated_elem_names, Dups1});
       true ->
            ok
    end,
    FileName = filename:basename(Path),
    ModName = filename:rootname(FileName),
    DirName = filename:dirname(Path),
    Types = get_types(TaggedElems),
    AST = lists:flatmap(
            fun({Tag, Elem}) ->
                    Elem1 = prepare_elem(Elem, KnownFuns, TaggedElems, Opts),
                    elem_to_AST(Elem1, Tag, TaggedElems, Types, ModName, Opts)
            end, TaggedElems),
    Module = erl_syntax:attribute(
               erl_syntax:atom("module"),
               [erl_syntax:atom(list_to_atom(ModName))]),
    Decoders = make_top_decoders(TaggedElems, ModName, Opts),
    Encoders = make_top_encoders(TaggedElems, Opts),
    AuxFuns = make_aux_funs(),
    {AttrForms, FunForms} = lists:partition(
			      fun(Form) ->
				      erl_syntax:type(Form) == attribute
			      end, Forms),
    RawAttributes = lists:flatmap(
		      fun(Form) ->
			      erl_syntax:get_ann(Form)
		      end, lists:reverse(AttrForms)),
    PredefRecords = get_predefined_records(AttrForms),
    Printer = make_printer(TaggedElems, PredefRecords),
    NewAST = Decoders ++ Encoders ++ AuxFuns ++
        Printer ++ FunForms ++ AST,
    Records = make_records(Types, TaggedElems, PredefRecords, Opts),
    TypeSpecs = make_typespecs(ModName, Types, Opts),
    Exports = erl_syntax:attribute(
                erl_syntax:atom("export"),
                [erl_syntax:list(
                   lists:map(
                     fun({FN, Arity}) ->
                             erl_syntax:arity_qualifier(
                               erl_syntax:atom(FN),
                               erl_syntax:integer(Arity));
                        (F) ->
                             {FN, Arity} = erl_syntax_lib:analyze_function(F),
                             erl_syntax:arity_qualifier(
                               erl_syntax:atom(FN),
                               erl_syntax:integer(Arity))
                     end, [hd(Printer), {format_error, 1}
                           |Decoders ++ Encoders]))]),
    Compile = erl_syntax:attribute(
                erl_syntax:atom("compile"),
                [erl_syntax:abstract(
                   {nowarn_unused_function,
                    [{dec_int, 3},
                     {dec_int, 1},
                     {dec_enum, 2},
                     {enc_int, 1},
                     {get_attr, 2},
                     {enc_enum, 1}]})]),
    Hdr = header(FileName),
    ResultAST = erl_syntax:form_list([Hdr, Module, Compile, Exports|NewAST]),
    case file:write_file(
           filename:join([DirName, ModName ++ ".erl"]),
           [erl_prettypr:format(ResultAST), io_lib:nl()]) of
        ok ->
            file:write_file(
              filename:join([DirName, ModName ++ ".hrl"]),
              [erl_prettypr:format(Hdr),
	       RawAttributes,
	       io_lib:nl(),
               string:join(Records, io_lib:nl() ++ io_lib:nl()),
	       io_lib:nl(),
	       io_lib:nl(),
	       TypeSpecs,
               io_lib:nl()]);
        Err ->
            Err
    end.

get_predefined_records(AttrForms) ->
    lists:foldl(
      fun(F, Acc) ->
	      case erl_syntax_lib:analyze_attribute(F) of
		  {record, {RecName, RecAttrs}} ->
		      Fields = [Field || {Field, _} <- RecAttrs],
		      dict:store(RecName, Fields, Acc);
		  _ ->
		      Acc
	      end
      end, dict:new(), AttrForms).

make_aux_funs() ->
    case get_abstract_code_from_myself() of
        {ok, AbsCode} ->
            lists:filter(
              fun(T) ->
                      case catch erl_syntax_lib:analyze_function(T) of
                          {format_error, 1} -> true;
                          {dec_int, 3} -> true;
                          {dec_int, 1} -> true;
                          {dec_enum, 2} -> true;
                          {enc_int, 1} -> true;
                          {enc_enum, 1} -> true;
                          {get_attr, 2} -> true;
                          _ -> false
                      end
              end, AbsCode);
        error ->
            erlang:error({no_abstract_code_found, ?MODULE})
    end.

make_records({Tags, TypesDict, RecDict}, TaggedElems, PredefRecords, Opts) ->
    {Strings, _} =
        lists:foldl(
          fun(Tag, {Res, Seen}) ->
                  RefElem = get_elem_by_ref(Tag, TaggedElems),
                  Result = RefElem#elem.result,
                  case term_is_record(Result) of
                      true ->
                          RecName = element(1, Result),
			  case dict:is_key(RecName, PredefRecords) of
			      true ->
				  {Res, Seen};
			      false ->
				  case lists:member(RecName, Seen) of
				      false ->
					  {[record_to_string(
					      RefElem, RecDict,
					      TypesDict, Opts)|Res],
					   [RecName|Seen]};
				      true ->
					  {Res, Seen}
				  end
			  end;
                      false ->
                          {Res, Seen}
                  end
          end, {[], []}, Tags),
    lists:reverse(Strings).

make_typespecs(_ModName, {_Tags, _TypesDict, RecDict}, Opts) ->
    case proplists:get_value(add_type_specs, Opts) of
	TypeName when is_atom(TypeName), TypeName /= undefined ->
	    case [[atom_to_string(R), "()"]
		  || {record, R} <- dict:fetch_keys(RecDict)] of
		[] ->
		    [];
		Records ->
		    Prefix = "-type " ++ atom_to_string(TypeName) ++ "() :: ",
		    Sep = " |" ++ io_lib:nl()
			++ lists:duplicate(length(Prefix), $ ),
		    [Prefix, string:join(Records, Sep), $.]
	    end;
	_ ->
	    []
    end.

atom_to_string(Atom) ->
    erl_syntax:atom_literal(abstract(Atom)).

record_to_string(#elem{result = Result} = Elem, RecDict, RecTypes, Opts) ->
    [RecName|RecLabels] = tuple_to_list(Result),
    Prefix = "-record(" ++ atom_to_string(RecName) ++ ", {",
    Sep = "," ++ io_lib:nl() ++ lists:duplicate(length(Prefix), $ ),
    Fs = lists:map(
           fun(Label) ->
                   FName = label_to_record_field(Label),
                   case get_label_type(Label, Elem, RecTypes) of
                       {FType, undefined, _} ->
                           FType1 = erl_types:t_subtract(
                                      FType, erl_types:t_atom(undefined)),
                           [atom_to_string(FName), " :: ",
                            erl_types:t_to_string(FType1, RecDict)];
                       {FType, Default, _} ->
                           Type = erl_types:t_sup(
                                    [erl_types:t_from_term(Default),
                                     FType]),
                           [atom_to_string(FName), " = ",
                            io_lib:fwrite("~w", [Default]),
                            " :: ",
                            erl_types:t_to_string(Type, RecDict)]
                   end
           end, RecLabels),
    RecordStr = [Prefix, string:join(Fs, Sep), "})."],
    case proplists:get_value(add_type_specs, Opts) of
	TypeName when is_atom(TypeName), TypeName /= undefined ->
	    [RecordStr, io_lib:nl(),
	     "-type ", atom_to_string(RecName), "() :: ",
	     "#", atom_to_string(RecName), "{}."];
	_ ->
	    RecordStr
    end.

header(FileName) ->
    erl_syntax:comment(
      0,
      ["% Created automatically by XML generator (xml_gen.erl)",
       "% Source: " ++ FileName]).

make_top_decoders(TaggedSpecs, ModName, Opts) when is_list(Opts) ->
    IgnoreXMLNS = proplists:get_bool(ignore_xmlns, Opts),
    make_top_decoders(TaggedSpecs, ModName, IgnoreXMLNS);
make_top_decoders(TaggedSpecs, ModName, true) ->
    C0 = erl_syntax:match_expr(
	   erl_syntax:variable("IgnoreEls"),
	   make_function_call(
	     proplists, get_bool,
	     [erl_syntax:atom("ignore_els"),
	      erl_syntax:variable("Opts")])),
    C1 = lists:map(
           fun({Tag, #elem{name = Name}}) ->
                   erl_syntax:clause(
                     [erl_syntax:tuple([erl_syntax:atom("xmlel"),
					abstract(Name),
					erl_syntax:underscore(),
					erl_syntax:underscore()])],
                     none,
                     [make_function_call(
                        make_dec_fun_name([Tag]),
                        [abstract(<<>>),
			 erl_syntax:variable("IgnoreEls"),
			 erl_syntax:variable("_el")])])
           end, TaggedSpecs),
    C2 = lists:map(
           fun({_Tag, #elem{name = Name}}) ->
                   erl_syntax:clause(
                     [erl_syntax:tuple([erl_syntax:atom("xmlel"),
                                        abstract(Name),
                                        erl_syntax:underscore(),
                                        erl_syntax:underscore()])],
                     none,
                     [erl_syntax:atom(true)])
           end, TaggedSpecs),
    NilClause1 = erl_syntax:clause(
                   [erl_syntax:tuple([erl_syntax:atom("xmlel"),
                                      erl_syntax:variable("_name"),
                                      erl_syntax:underscore(),
                                      erl_syntax:underscore()])],
                   none,
                   [make_erlang_error(
                      ModName,
                      erl_syntax:tuple(
                        [erl_syntax:atom("unknown_tag"),
                         erl_syntax:variable("_name"),
                         abstract(<<>>)]))]),
    NilClause2 = erl_syntax:clause(
                   [erl_syntax:underscore()], none, [abstract(true)]),
    [make_function(
       "decode",
       [erl_syntax:variable("_el")],
       [make_function_call(
	  "decode", [erl_syntax:variable("_el"), erl_syntax:list([])])]),
     make_function("decode",
		   [erl_syntax:variable("_el"), erl_syntax:variable("Opts")],
		   [C0,
		    erl_syntax:case_expr(
		      erl_syntax:variable("_el"),
		      C1 ++ [NilClause1])]),
     erl_syntax:function(erl_syntax:atom("is_known_tag"), C2 ++ [NilClause2])];
make_top_decoders(TaggedSpecs1, ModName, false) ->
    TaggedSpecs = lists:flatmap(
		    fun({Tag, #elem{xmlns = XMLNSs} = E}) when is_list(XMLNSs) ->
			    [{Tag, E#elem{xmlns = XMLNS}} || XMLNS <- XMLNSs];
		       (TE) ->
			    [TE]
		    end, TaggedSpecs1),
    C0 = erl_syntax:match_expr(
	   erl_syntax:variable("IgnoreEls"),
	   make_function_call(
	     proplists, get_bool,
	     [erl_syntax:atom("ignore_els"),
	      erl_syntax:variable("Opts")])),
    C1 = lists:map(
           fun({Tag, #elem{xmlns = XMLNS, name = Name}}) ->
                   erl_syntax:clause(
                     [erl_syntax:tuple(
                        [abstract(Name),
                         abstract(XMLNS)])],
                     none,
                     [make_function_call(
                        make_dec_fun_name([Tag]),
                        [abstract(XMLNS),
			 erl_syntax:variable("IgnoreEls"),
			 erl_syntax:variable("_el")])])
           end, TaggedSpecs),
    C2 = lists:map(
           fun({_Tag, #elem{xmlns = XMLNS, name = Name}}) ->
                   erl_syntax:clause(
                     [erl_syntax:tuple(
                        [abstract(Name),
                         abstract(XMLNS)])],
                     none,
                     [erl_syntax:atom("true")])
           end, TaggedSpecs),
    NilClause = erl_syntax:clause(
                  [erl_syntax:tuple(
                     [erl_syntax:variable("_name"),
                      erl_syntax:variable("_xmlns")])],
                  none,
                  [make_erlang_error(
                     ModName,
                     erl_syntax:tuple(
                       [erl_syntax:atom("unknown_tag"),
                        erl_syntax:variable("_name"),
                        erl_syntax:variable("_xmlns")]))]),
    [make_function(
       "decode",
       [erl_syntax:variable("_el")],
       [make_function_call(
	  "decode", [erl_syntax:variable("_el"), erl_syntax:list([])])]),
     make_function(
       "decode",
       [erl_syntax:match_expr(
          erl_syntax:tuple([erl_syntax:atom("xmlel"),
                            erl_syntax:variable("_name"),
                            erl_syntax:variable("_attrs"),
                            erl_syntax:underscore()]),
          erl_syntax:variable("_el")),
	erl_syntax:variable("Opts")],
       [C0,
	erl_syntax:case_expr(
          erl_syntax:tuple(
            [erl_syntax:variable("_name"),
             make_function_call(
               get_attr,
               [abstract(<<"xmlns">>),
                erl_syntax:variable("_attrs")])]),
          C1 ++ [NilClause])]),
     make_function(
       "is_known_tag",
       [erl_syntax:match_expr(
          erl_syntax:tuple([erl_syntax:atom("xmlel"),
                            erl_syntax:variable("_name"),
                            erl_syntax:variable("_attrs"),
                            erl_syntax:underscore()]),
          erl_syntax:variable("_el"))],
       [erl_syntax:case_expr(
          erl_syntax:tuple(
            [erl_syntax:variable("_name"),
             make_function_call(
               get_attr,
               [abstract(<<"xmlns">>),
                erl_syntax:variable("_attrs")])]),
          C2 ++ [erl_syntax:clause(
                   [erl_syntax:underscore()], none, [abstract(false)])])])].

make_top_encoders(TaggedSpecs, Opts) ->
    IgnoreXMLNS = proplists:get_bool(ignore_xmlns, Opts),
    {RecNames, ResNames} =
	lists:foldl(
	  fun({Tag, #elem{result = Result}}, {RecAcc, ResAcc}) ->
		  try
		      [H|_]= tuple_to_list(Result),
		      true = is_atom(H),
		      false = is_label(H),
		      {dict:append(H, Tag, RecAcc),
		       dict:append(H, Result, ResAcc)}
		  catch _:_ ->
			  {RecAcc, ResAcc}
		  end
	  end, {dict:new(), dict:new()}, TaggedSpecs),
    NilNSClause = erl_syntax:clause(
		    [erl_syntax:underscore()], none, [abstract(<<"">>)]),
    {EncClauses, NSClauses, _} =
        lists:foldl(
          fun({Tag, #elem{name = Name, xmlns = XMLNS,
			  result = Result, attrs = Attrs}},
	      {EncAcc, NSAcc, Seen}) ->
                  NewResult = labels_to_underscores(Result),
                  Var = label_to_var(prepare_label(undefined, Name)),
		  HasXMLNSAttr = lists:any(
				   fun(#attr{name= <<"xmlns">>}) -> true;
				      (_) -> false
				   end, Attrs),
                  try
                      [H|_]= tuple_to_list(Result),
                      true = is_atom(H),
                      false = is_label(H),
                      Tags = dict:fetch(H, RecNames),
		      OtherResults = dict:fetch(H, ResNames) -- [Result],
		      true = lists:member(Tag, Tags),
		      IsDuplicated = lists:member(Result, OtherResults),
		      AlreadySeen = lists:member(Result, Seen),
                      XMLNSAttrs = if IgnoreXMLNS or HasXMLNSAttr
				      or is_list(XMLNS) or IsDuplicated ->
                                           erl_syntax:list([]);
                                      true ->
                                           erl_syntax:list(
                                             [erl_syntax:tuple(
                                                [abstract(<<"xmlns">>),
                                                 abstract(XMLNS)])])
                                   end,
                      {if AlreadySeen ->
			       EncAcc;
			  true ->
			       [erl_syntax:clause(
				  [erl_syntax:match_expr(NewResult, Var)],
				  none,
				  [make_function_call(
				     make_enc_fun_name([Tag]),
				     [Var, XMLNSAttrs])])|EncAcc]
		       end,
		       if IgnoreXMLNS or is_list(XMLNS) or IsDuplicated ->
			       NSAcc;
			  true ->
			       [erl_syntax:clause(
				  [NewResult], none,
				  [abstract(XMLNS)])|NSAcc]
		       end,
		       [Result|Seen]}
                  catch _:_ ->
                          {EncAcc, NSAcc, Seen}
                  end
          end, {[], [NilNSClause], []}, TaggedSpecs),
    XmlElClause = erl_syntax:clause(
		    [erl_syntax:match_expr(
		       erl_syntax:tuple(
			 [erl_syntax:atom("xmlel"),
			  erl_syntax:underscore(),
			  erl_syntax:underscore(),
			  erl_syntax:underscore()]),
		       erl_syntax:variable("El"))],
		    none,
		    [erl_syntax:variable("El")]),
    [erl_syntax:function(erl_syntax:atom("encode"), [XmlElClause|EncClauses]),
     erl_syntax:function(erl_syntax:atom("get_ns"), NSClauses)].

make_printer(TaggedSpecs, PredefRecords) ->
    PassClause = erl_syntax:clause(
                   [erl_syntax:underscore(),
                    erl_syntax:underscore()],
                   none,
                   [erl_syntax:atom("no")]),
    %% Exclude tags with duplicated results
    RecNames = lists:foldl(
                 fun({Tag, #elem{result = Result}}, Acc) ->
                         try
                             [H|_]= tuple_to_list(Result),
                             true = is_atom(H),
                             false = is_label(H),
                             dict:append(H, Tag, Acc)
                         catch _:_ ->
                                 Acc
                         end
                 end, dict:new(), TaggedSpecs),
    Clauses =
        lists:foldl(
          fun({Tag, #elem{result = Result}}, Acc) ->
                  try
                      [H|T]= tuple_to_list(Result),
                      true = is_atom(H),
                      false = is_label(H),
                      [Tag|_] = dict:fetch(H, RecNames),
		      Fields = case dict:find(H, PredefRecords) of
				   {ok, Fs} ->
				       Fs;
				   error ->
				       [label_to_record_field(F) || F <- T]
			       end,
                      [erl_syntax:clause(
                         [erl_syntax:atom(H), abstract(length(T))],
                         none,
                         [erl_syntax:list(
                            [erl_syntax:atom(F) || F <- Fields])])
                       |Acc]
                  catch _:_ ->
                          Acc
                  end
          end, [PassClause], TaggedSpecs),
    [make_function(
       "pp",
       [erl_syntax:variable("Term")],
       [make_function_call(
          io_lib_pretty, print,
          [erl_syntax:variable("Term"),
           erl_syntax:implicit_fun(
             erl_syntax:atom("pp"),
             abstract(2))])]),
     erl_syntax:function(erl_syntax:atom("pp"), Clauses)].

elem_to_AST(#elem{name = Name, xmlns = XMLNS, cdata = CData,
                  result = Result, attrs = Attrs, refs = _Refs} = Elem,
            Tag, AllElems, Types, ModName, Opts) ->
    AttrAST = lists:flatmap(
                fun(#attr{name = AttrName,
                          required = Required,
                          dec = AttrDecF,
                          enc = AttrEncF,
                          default = AttrDefault}) ->
                        make_decoding_MFA([AttrName,attr,Tag],
                                          Name, XMLNS, AttrName,
                                          Required, AttrDefault,
                                          AttrDecF, Types, ModName) ++
                            make_encoding_MFA([AttrName,attr,Tag],
                                              AttrName, Required, AttrDefault,
                                              AttrEncF)
                end, Attrs),
    #cdata{label = CDataLabl,
           required = CDataRequired,
           dec = CDataDecF,
           enc = CDataEncF,
           default = CDataDefault} = CData,
    CDataAST =
        case have_label(Result, CDataLabl) of
            true ->
                make_decoding_MFA([cdata,Tag], Name, XMLNS, <<>>,
                                  CDataRequired, CDataDefault,
                                  CDataDecF, Types, ModName) ++
                    make_encoding_MFA([cdata,Tag], <<>>,
                                      CDataRequired, CDataDefault,
                                      CDataEncF);
            false ->
                []
        end,
    DecAST = make_elem_dec_fun(Elem, Tag, AllElems, Types, ModName, Opts),
    EncAST = make_elem_enc_fun(Elem, Tag, AllElems),
    DecAST ++ EncAST ++ AttrAST ++ CDataAST.

%% Replace in `Term' every label found in `Labels'
%% with the corresponding value.
subst_labels(Term) ->
    erl_syntax_lib:map(
      fun(T) ->
              try
                  Label = erl_syntax:atom_value(T),
                  true = is_label(Label),
                  label_to_var(Label)
              catch _:_ ->
                      T
              end
      end, abstract(Term)).

get_elem_by_ref(RefName, TaggedElems) ->
    {_, Elem} = lists:keyfind(RefName, 1, TaggedElems),
    Elem.

get_spec_by_label('$_els', _Elem) ->
    sub_els;
get_spec_by_label('$_xmls', _Elem) ->
    xml_els;
get_spec_by_label(Label, Elem) ->
    [Spec|T] = lists:flatmap(
                 fun(#cdata{label = L} = CData) when Label == L ->
                         [CData];
                    (#attr{label = L, name = N} = Attr) ->
                         case prepare_label(L, N) of
                             Label ->
                                 [Attr];
                             _ ->
                                 []
                         end;
                    (#ref{label = L, name = N} = Ref) ->
                         case prepare_label(L, N) of
                             Label ->
                                 [Ref];
                             _ ->
                                 []
                         end;
                    (_) ->
                         []
                 end, [Elem#elem.cdata|Elem#elem.attrs ++ Elem#elem.refs]),
    if is_record(Spec, ref) ->
            [Spec|T];
       true ->
            Spec
    end.

group_refs(Refs) ->
    dict:to_list(
      lists:foldl(
        fun(#ref{name = Name, label = Label} = Ref, G) ->
                L = prepare_label(Label, Name),
                dict:append_list(L, [Ref], G)
        end, dict:new(), Refs)).

make_elem_dec_fun(#elem{name = Name, result = Result, refs = Refs,
                        cdata = CData, attrs = Attrs, xmlns = XMLNS},
                  Tag, AllElems, Types, ModName, Opts) ->
    FunName = make_dec_fun_name([Tag]),
    ResultWithVars = subst_labels(Result),
    AttrVars = lists:map(
                 fun(#attr{name = AttrName, label = AttrLabel}) ->
                         label_to_var(prepare_label(AttrLabel, AttrName))
                 end, Attrs),
    HaveCData = have_label(Result, CData#cdata.label),
    CDataVars = if HaveCData ->
                        [label_to_var(CData#cdata.label)];
                   true ->
                        []
                end,
    SubElVars = case have_label(Result, '$_els') of
                    true ->
                        [label_to_var('$_els')];
                    false ->
                        []
                end,
    XmlElVars = case have_label(Result, '$_xmls') of
                    true ->
                        [label_to_var('$_xmls')];
                    false ->
                        []
                end,
    ElemVars = lists:map(
                 fun({Label, _}) ->
                         label_to_var(Label)
                 end, group_refs(Refs)),
    AttrMatch =
        if AttrVars /= [] ->
                AttrPattern = tuple_or_single_var(AttrVars),
                AttrCall = make_function_call(
                             FunName ++ "_attrs",
                             [erl_syntax:variable("__TopXMLNS"),
			      erl_syntax:variable("_attrs")|
                              lists:map(
                                fun(_) ->
                                        erl_syntax:atom(undefined)
                                end, Attrs)]),
                [erl_syntax:match_expr(AttrPattern, AttrCall)];
           true ->
                []
        end,
    ElCDataMatch =
        case CDataVars ++ ElemVars ++ SubElVars ++ XmlElVars of
            [] ->
                [];
            _ ->
                [erl_syntax:match_expr(
                   tuple_or_single_var(CDataVars ++ ElemVars ++ SubElVars ++ XmlElVars),
                   make_function_call(
                     FunName ++ "_els",
                     [erl_syntax:variable("__TopXMLNS"),
		      erl_syntax:variable("__IgnoreEls"),
		      erl_syntax:variable("_els")|
                      lists:flatmap(
                        fun({_, [#ref{min = 0, max = 1, default = Def}|_]}) ->
                                [abstract(Def)];
                           ({_, [#ref{min = 1, max = 1}|_]}) ->
                                [erl_syntax:atom("error")];
                           (#cdata{}) when HaveCData ->
                                [abstract(<<>>)];
                           (#cdata{}) ->
                                [];
                           (_) ->
                                [erl_syntax:list([])]
                        end, [CData|group_refs(Refs)] ++ SubElVars ++ XmlElVars)]))]
        end,
    [make_function(
       FunName,
       [erl_syntax:variable("__TopXMLNS"),
	erl_syntax:variable("__IgnoreEls"),
	erl_syntax:tuple([erl_syntax:atom("xmlel"),
                          abstract(Name),
                          erl_syntax:variable("_attrs"),
                          erl_syntax:variable("_els")])],
       ElCDataMatch ++ AttrMatch ++ [ResultWithVars])]
        ++ make_els_dec_fun(FunName ++ "_els", CData, HaveCData, SubElVars,
                            XmlElVars, Refs, Tag, XMLNS, AllElems,
                            Result, Types, ModName, Opts)
        ++ make_attrs_dec_fun(FunName ++ "_attrs", Attrs, Tag).

make_els_dec_clause(FunName, CDataVars, Refs, TopXMLNS, AllElems,
                    Result, {_SortedTags, Types, _RecDict}, Opts) ->
    SubElVars = case have_label(Result, '$_els') of
                    true ->
                        [label_to_var('$_els')];
                    false ->
                        []
                end,
    XmlElVars = case have_label(Result, '$_xmls') of
                    true ->
                        [label_to_var('$_xmls')];
                    false ->
                        []
                end,
    _ElsVar = erl_syntax:variable("_els"),
    lists:map(
      fun(#ref{name = RefName, label = RefLabel}) ->
              Label = prepare_label(RefLabel, RefName),
              Var = label_to_var(Label),
              RefElem = get_elem_by_ref(RefName, AllElems),
	      IgnoreXMLNS = proplists:get_bool(ignore_xmlns, Opts),
              XMLNSs = lists:flatten([RefElem#elem.xmlns]),
	      TopXMLNSs = lists:flatten([TopXMLNS]),
	      HasCommonXMLNSs = not sets:is_disjoint(
				      sets:from_list(XMLNSs),
				      sets:from_list(TopXMLNSs)),
              XMLNSMatch = erl_syntax:match_expr(
                             erl_syntax:variable("_xmlns"),
                             make_function_call(
                               get_attr,
                               [abstract(<<"xmlns">>),
                                erl_syntax:variable("_attrs")])),
              IfGuard = case HasCommonXMLNSs of
			    false ->
                                erl_syntax:disjunction(
				  [erl_syntax:infix_expr(
				     erl_syntax:variable("_xmlns"),
				     erl_syntax:operator("=="),
				     abstract(NS)) || NS <- XMLNSs]);
			    true ->
				erl_syntax:disjunction(
				  [erl_syntax:infix_expr(
				     erl_syntax:variable("_xmlns"),
				     erl_syntax:operator("=="),
				     abstract(<<"">>)),
				   erl_syntax:infix_expr(
				     erl_syntax:variable("_xmlns"),
				     erl_syntax:operator("=="),
				     erl_syntax:variable("__TopXMLNS"))])
			end,
	      ElemVars = lists:map(
			   fun({Labl, [#ref{max = 1}|_]})
				 when Labl == Label, IgnoreXMLNS ->
				   erl_syntax:underscore();
			      ({Labl, _}) ->
				   label_to_var(Labl)
			   end, group_refs(Refs)),
              NewElemVars =
		  fun(NS) ->
			  lists:map(
			    fun({L, [#ref{min = Min, max = 1}|_]})
				  when L == Label ->
				    Call = make_function_call(
					     make_dec_fun_name([RefName]),
					     [erl_syntax:variable(NS),
					      erl_syntax:variable("__IgnoreEls"),
					      erl_syntax:variable("_el")]),
				    if Min == 0 ->
					    Call;
				       Min == 1 ->
					    erl_syntax:tuple(
					      [erl_syntax:atom("value"),
					       Call])
				    end;
			       ({L, [#ref{default = Def}]}) when L == Label ->
				    RefType = dict:fetch(RefName, Types),
				    case is_subtype(Def, RefType) of
					true ->
					    erl_syntax:case_expr(
					      make_function_call(
						make_dec_fun_name([RefName]),
						[erl_syntax:variable(NS),
						 erl_syntax:variable("__IgnoreEls"),
						 erl_syntax:variable("_el")]),
					      [erl_syntax:clause(
						 [abstract(Def)], none, [Var]),
					       erl_syntax:clause(
						 [erl_syntax:variable("_new_el")],
						 none,
						 [erl_syntax:list(
						    [erl_syntax:variable("_new_el")],
						    Var)])]);
					false ->
					    erl_syntax:list(
					      [make_function_call(
						 make_dec_fun_name([RefName]),
						 [erl_syntax:variable(NS),
						  erl_syntax:variable("__IgnoreEls"),
						  erl_syntax:variable("_el")])],
					      Var)
				    end;
			       ({L, _}) ->
				    label_to_var(L)
			    end, group_refs(Refs))
		  end,
              erl_syntax:clause(
                [erl_syntax:variable("__TopXMLNS"),
		 erl_syntax:variable("__IgnoreEls"),
		 erl_syntax:list(
                   [erl_syntax:match_expr(
                      erl_syntax:tuple(
                        [erl_syntax:atom("xmlel"),
                         abstract(RefElem#elem.name),
                         erl_syntax:variable("_attrs"),
                         erl_syntax:underscore()]),
                      erl_syntax:variable("_el"))],
                   erl_syntax:variable("_els"))|
                 CDataVars ++ ElemVars ++ SubElVars ++ XmlElVars],
                none,
                case IgnoreXMLNS of
                    true ->
                        [make_function_call(
                           FunName,
                           [erl_syntax:variable("__TopXMLNS"),
			    erl_syntax:variable("__IgnoreEls"),
			    _ElsVar|CDataVars ++ NewElemVars("__TopXMLNS")
                            ++ SubElVars ++ XmlElVars])];
                    false ->
                        [XMLNSMatch,
                         erl_syntax:if_expr(
			   case HasCommonXMLNSs of
			       true ->
				   [erl_syntax:clause(
				      [], IfGuard,
				      [make_function_call(
					 FunName,
					 [erl_syntax:variable("__TopXMLNS"),
					  erl_syntax:variable("__IgnoreEls"),
					  _ElsVar|CDataVars ++ NewElemVars("__TopXMLNS")
					  ++ SubElVars ++ XmlElVars])])];
			       false ->
				   [erl_syntax:clause(
				      [], IfGuard,
				      [make_function_call(
					 FunName,
					 [erl_syntax:variable("__TopXMLNS"),
					  erl_syntax:variable("__IgnoreEls"),
					  _ElsVar|CDataVars ++ NewElemVars("_xmlns")
					  ++ SubElVars ++ XmlElVars])])]
			   end ++
			       [erl_syntax:clause(
				  [], none,
				  [make_function_call(
				     FunName,
				     [erl_syntax:variable("__TopXMLNS"),
				      erl_syntax:variable("__IgnoreEls"),
				      _ElsVar|CDataVars ++ ElemVars
				      ++ SubElVars ++ XmlElVars])])])]
		end)
      end, Refs).

make_els_dec_fun(_FunName, _CData, false, [], [], [], _Tag,
                 _TopXMLNS, _AllElems, _Result, _Types, _ModName, _Opts) ->
    [];
make_els_dec_fun(FunName, CData, HaveCData, SubElVars, XmlElVars, Refs, Tag,
                 TopXMLNS, AllElems, Result, Types, ModName, Opts) ->
    CDataVars = if HaveCData ->
                        [label_to_var(CData#cdata.label)];
                   true ->
                        []
                end,
    ElemVars = lists:map(
                 fun({Label, _}) ->
                         label_to_var(Label)
                 end, group_refs(Refs)),
    _ElsVar = erl_syntax:variable("_els"),
    ResultCData = if HaveCData ->
                          [erl_syntax:binary(
                             [erl_syntax:binary_field(
                                hd(CDataVars),
                                [erl_syntax:atom("binary")]),
                              erl_syntax:binary_field(
                                erl_syntax:variable("_data"),
                                [erl_syntax:atom("binary")])])];
                     true ->
                          []
                  end,
    CDataClause = if HaveCData ->
                          [erl_syntax:clause(
                             [erl_syntax:variable("__TopXMLNS"),
			      erl_syntax:variable("__IgnoreEls"),
			      erl_syntax:list(
                                [erl_syntax:tuple(
                                   [erl_syntax:atom("xmlcdata"),
                                    erl_syntax:variable("_data")])],
                                _ElsVar)
                              |CDataVars ++ ElemVars ++ SubElVars ++ XmlElVars],
                             none,
                             [make_function_call(
                                FunName,
                                [erl_syntax:variable("__TopXMLNS"),
				 erl_syntax:variable("__IgnoreEls"),
				 erl_syntax:variable("_els")|
                                 ResultCData ++ ElemVars ++ SubElVars ++ XmlElVars])])];
                     true ->
                          []
                  end,
    ElemClauses = make_els_dec_clause(FunName, CDataVars,
                                      Refs, TopXMLNS, AllElems, Result,
                                      Types, Opts),
    ResultElems = lists:map(
                    fun({L, [#ref{min = 0, max = 1}|_]}) ->
                            label_to_var(L);
                       ({L, [#ref{min = 1, max = 1, name = RefName}]}) ->
                            RefElem = get_elem_by_ref(RefName, AllElems),
                            L1 = list_to_atom(atom_to_list(L) ++ "1"),
                            erl_syntax:case_expr(
                              label_to_var(L),
                              [erl_syntax:clause(
                                 [erl_syntax:atom(error)],
                                 none,
                                 [make_erlang_error(
                                    ModName,
                                    erl_syntax:tuple(
                                      [erl_syntax:atom("missing_tag"),
                                       abstract(RefElem#elem.name),
                                       erl_syntax:variable("__TopXMLNS")]))]),
                               erl_syntax:clause(
                                 [erl_syntax:tuple(
                                    [erl_syntax:atom("value"),
                                     label_to_var(L1)])],
                                 none,
                                 [label_to_var(L1)])]);
                       ({L, [#ref{min = 0, max = infinity}|_]}) ->
                            make_function_call(
                              lists, reverse, [label_to_var(L)])
                    end, group_refs(Refs)),
    CDataCall = if HaveCData ->
                        [make_function_call(
                           make_dec_fun_name([cdata,Tag]),
			   [erl_syntax:variable("__TopXMLNS")|CDataVars])];
                   true ->
                        []
                end,
    SubElResult = case have_label(Result, '$_els') of
                      true ->
                          [make_function_call(
                             lists, reverse,
                             [label_to_var('$_els')])];
                      false ->
                          []
                  end,
    XmlElResult = case have_label(Result, '$_xmls') of
                      true ->
                          [make_function_call(
                             lists, reverse,
                             [label_to_var('$_xmls')])];
                      false ->
                          []
                  end,
    NilClause = erl_syntax:clause(
                  [erl_syntax:variable("__TopXMLNS"),
		   erl_syntax:variable("__IgnoreEls"),
		   erl_syntax:list([])|
                   CDataVars ++
                       lists:map(
                         fun({L, _}) ->
                                 label_to_var(L)
                         end, group_refs(Refs)) ++ SubElVars ++ XmlElVars],
                  none,
                  [tuple_or_single_var(
                     CDataCall ++ ResultElems ++ SubElResult ++ XmlElResult)]),
    SubElPattern = [erl_syntax:variable("__TopXMLNS"),
		    erl_syntax:variable("__IgnoreEls"),
		    erl_syntax:list(
                      [erl_syntax:match_expr(
                         erl_syntax:tuple(
                           [erl_syntax:atom("xmlel"),
                            erl_syntax:underscore(),
                            erl_syntax:underscore(),
                            erl_syntax:underscore()]),
                         erl_syntax:variable("_el"))],
                      _ElsVar)
                    |CDataVars ++ ElemVars ++ SubElVars ++ XmlElVars],
    SubElClause =
        case {have_label(Result, '$_els'),
              have_label(Result, '$_xmls')} of
            {true, false} ->
                SubElBody = erl_syntax:if_expr(
			      [erl_syntax:clause(
				 [],
				 [erl_syntax:variable("__IgnoreEls")],
				 [make_function_call(
                                    FunName,
                                    [erl_syntax:variable("__TopXMLNS"),
				     erl_syntax:variable("__IgnoreEls"),
				     _ElsVar|CDataVars ++ ElemVars] ++
                                        [erl_syntax:list(
					   [erl_syntax:variable("_el")],
                                           label_to_var('$_els'))])]),
			       erl_syntax:clause(
				 [], none,
				 [erl_syntax:case_expr(
				    make_function_call(
				     is_known_tag,
				     [erl_syntax:variable("_el")]),
				   [erl_syntax:clause(
				      [erl_syntax:atom("true")],
				      none,
				      [make_function_call(
					 FunName,
					 [erl_syntax:variable("__TopXMLNS"),
					  erl_syntax:variable("__IgnoreEls"),
					  _ElsVar|CDataVars ++ ElemVars] ++
					     [erl_syntax:list(
						[make_function_call(
						   "decode",
						   [erl_syntax:variable("_el")])],
						label_to_var('$_els'))])]),
				    erl_syntax:clause(
				      [erl_syntax:atom("false")],
				      none,
				      [make_function_call(
					 FunName,
					 [erl_syntax:variable("__TopXMLNS"),
					  erl_syntax:variable("__IgnoreEls"),
					  _ElsVar|CDataVars ++ ElemVars] ++
					     [label_to_var('$_els')])])])])]),
                [erl_syntax:clause(SubElPattern, none, [SubElBody])];
            {false, true} ->
                SubElBody = make_function_call(
                              FunName,
                              [erl_syntax:variable("__TopXMLNS"),
			       erl_syntax:variable("__IgnoreEls"),
			       _ElsVar|CDataVars ++ ElemVars] ++
                                  [erl_syntax:list(
                                     [erl_syntax:variable("_el")],
                                     label_to_var('$_xmls'))]),
                [erl_syntax:clause(SubElPattern, none, [SubElBody])];
            {true, true} ->
                SubElBody = erl_syntax:if_expr(
			      [erl_syntax:clause(
				 [],
				 [erl_syntax:variable("__IgnoreEls")],
				 [make_function_call(
                                    FunName,
                                    [erl_syntax:variable("__TopXMLNS"),
				     erl_syntax:variable("__IgnoreEls"),
				     _ElsVar|CDataVars ++ ElemVars] ++
                                        [label_to_var('$_els')] ++
                                        [erl_syntax:list(
                                           [erl_syntax:variable("_el")],
                                           label_to_var('$_xmls'))])]),
			       erl_syntax:clause(
				 [], none,
				 [erl_syntax:case_expr(
				    make_function_call(
				      is_known_tag,
				      [erl_syntax:variable("_el")]),
				    [erl_syntax:clause(
				       [erl_syntax:atom("true")],
				       none,
				       [make_function_call(
					  FunName,
					  [erl_syntax:variable("__TopXMLNS"),
					   erl_syntax:variable("__IgnoreEls"),
					   _ElsVar|CDataVars ++ ElemVars] ++
					      [erl_syntax:list(
						 [make_function_call(
						    "decode",
						    [erl_syntax:variable("_el")])],
						 label_to_var('$_els'))]
					  ++ [label_to_var('$_xmls')])]),
				     erl_syntax:clause(
				       [erl_syntax:atom("false")],
				       none,
				       [make_function_call(
					  FunName,
					  [erl_syntax:variable("__TopXMLNS"),
					   erl_syntax:variable("__IgnoreEls"),
					   _ElsVar|CDataVars ++ ElemVars] ++
					      [label_to_var('$_els')] ++
					      [erl_syntax:list(
						 [erl_syntax:variable("_el")],
						 label_to_var('$_xmls'))])])])])]),
                [erl_syntax:clause(SubElPattern, none, [SubElBody])];
            {false, false} ->
                []
        end,
    PassClause = if SubElVars == []; CDataVars == [] ->
                         [erl_syntax:clause(
                            [erl_syntax:variable("__TopXMLNS"),
			     erl_syntax:variable("__IgnoreEls"),
			     erl_syntax:list(
                               [erl_syntax:underscore()],
                               _ElsVar)|CDataVars ++ ElemVars ++ SubElVars ++ XmlElVars],
                            none,
                            [make_function_call(
                               FunName,
                               [erl_syntax:variable("__TopXMLNS"),
				erl_syntax:variable("__IgnoreEls"), _ElsVar
				|CDataVars ++ ElemVars ++ SubElVars ++ XmlElVars])])];
                    true ->
                         []
                 end,
    [erl_syntax:function(
       erl_syntax:atom(FunName),
       [NilClause|CDataClause ++ ElemClauses ++ SubElClause ++ PassClause])].

make_attrs_dec_fun(FunName, Attrs, Tag) ->
    AttrVars = lists:map(
                 fun(#attr{name = AttrName, label = AttrLabel}) ->
                         label_to_var(prepare_label(AttrLabel, AttrName))
                 end, Attrs),
    Clauses =
        lists:map(
          fun(#attr{name = Name, label = Label}) ->
                  Var = label_to_var(prepare_label(Label, Name)),
                  Pattern = [erl_syntax:variable("__TopXMLNS"),
			     erl_syntax:list(
                               [erl_syntax:tuple(
                                  [abstract(Name),
                                   erl_syntax:variable("_val")])],
                               erl_syntax:variable("_attrs")) |
                             lists:map(
                               fun(V) when V == Var ->
                                       VName = erl_syntax:variable_literal(V),
                                       erl_syntax:variable("_" ++ VName);
                                  (V) ->
                                       V
                               end, AttrVars)],
                  Body = [make_function_call(
                            FunName,
                            [erl_syntax:variable("__TopXMLNS"),
			     erl_syntax:variable("_attrs") |
                             lists:map(
                               fun(V) when V == Var ->
                                       erl_syntax:variable("_val");
                                  (V) ->
                                       V
                               end, AttrVars)])],
                  erl_syntax:clause(Pattern, none, Body)
          end, Attrs),
    if Clauses /= [] ->
            PassClause = erl_syntax:clause(
                           [erl_syntax:variable("__TopXMLNS"),
			    erl_syntax:list(
                              [erl_syntax:underscore()],
                              erl_syntax:variable("_attrs"))
                            |AttrVars],
                           none,
                           [make_function_call(
                              FunName,
                              [erl_syntax:variable("__TopXMLNS"),
			       erl_syntax:variable("_attrs")|AttrVars])]),
            Result = lists:map(
                       fun(#attr{name = Name, label = Label}) ->
                               Var = label_to_var(prepare_label(Label, Name)),
                               make_function_call(
                                 make_dec_fun_name([Name,attr,Tag]),
				 [erl_syntax:variable("__TopXMLNS"), Var])
                       end, Attrs),
            NilClause = erl_syntax:clause(
                          [erl_syntax:variable("__TopXMLNS"),
			   erl_syntax:list([])|AttrVars],
                          none,
                          [tuple_or_single_var(Result)]),
            [erl_syntax:function(
               erl_syntax:atom(FunName),
               Clauses ++ [PassClause, NilClause])];
       true ->
            []
    end.

make_ref_enc_funs(#elem{xmlns = TopXMLNS} = Elem, Tag, AllElems) ->
    _AccVar = erl_syntax:variable("_acc"),
    _ElsVar = erl_syntax:variable("_els"),
    lists:map(
      fun({L, [#ref{min = Min, max = Max, default = Default}|_] = Refs}) ->
              DefaultClause = if Min == 0, Max == 1 ->
                                      [erl_syntax:clause(
                                         [abstract(Default), _AccVar],
                                         none, [_AccVar])];
                                 Min == 1, Max == 1 ->
                                      [];
                                 true ->
                                      [erl_syntax:clause(
                                         [erl_syntax:list([]), _AccVar],
                                         none, [_AccVar])]
                              end,
              Var = label_to_var(L),
              Clauses =
                  lists:map(
                    fun(#ref{name = RefName, max = 1}) ->
                            RefElem = get_elem_by_ref(RefName, AllElems),
                            XMLNS = RefElem#elem.xmlns,
                            XMLNSAttrs = if TopXMLNS == XMLNS ->
                                                 erl_syntax:list([]);
                                            true ->
                                                 erl_syntax:list(
                                                   [erl_syntax:tuple(
                                                      [abstract(<<"xmlns">>),
                                                       abstract(XMLNS)])])
                                         end,
                            Pattern =
                                if length(Refs) > 1 ->
                                        MatchVar = erl_syntax:match_expr(
                                                     labels_to_underscores(
                                                       RefElem#elem.result),
                                                     Var),
                                        [MatchVar, _AccVar];
                                   true ->
                                        [Var, _AccVar]
                                end,
                            erl_syntax:clause(
                              Pattern,
                              none,
                              [erl_syntax:list(
                                 [make_function_call(
                                    make_enc_fun_name([RefName]),
                                    [Var, XMLNSAttrs])],
                                 _AccVar)]);
                       (#ref{name = RefName}) ->
                            RefElem = get_elem_by_ref(RefName, AllElems),
                            XMLNS = RefElem#elem.xmlns,
                            XMLNSAttrs = if TopXMLNS == XMLNS ->
                                                 erl_syntax:list([]);
                                            true ->
                                                 erl_syntax:list(
                                                   [erl_syntax:tuple(
                                                      [abstract(<<"xmlns">>),
                                                       abstract(XMLNS)])])
                                         end,
                            Pattern =
                                if length(Refs) > 1 ->
                                        erl_syntax:match_expr(
                                          labels_to_underscores(
                                            RefElem#elem.result),
                                          Var);
                                   true ->
                                        Var
                                end,
                            erl_syntax:clause(
                              [erl_syntax:list([Pattern], _ElsVar), _AccVar],
                              none,
                              [make_function_call(
                                 make_enc_fun_name([L,Tag]),
                                 [_ElsVar,
                                  erl_syntax:list(
                                    [make_function_call(
                                       make_enc_fun_name([RefName]),
                                       [Var, XMLNSAttrs])],
                                    _AccVar)])])
                    end, Refs),
              erl_syntax:function(
                erl_syntax:atom(make_enc_fun_name([L,Tag])),
                DefaultClause ++ Clauses)
      end, group_refs(Elem#elem.refs)).

make_elem_enc_fun(#elem{result = Result, attrs = Attrs,
                        name = ElemName,
                        cdata = CData, refs = Refs} = Elem,
                  Tag, AllElems) ->
    CDataLabel = CData#cdata.label,
    HaveCData = have_label(Result, CDataLabel),
    HaveRefs = Refs /= [],
    HaveXMLs = have_label(Result, '$_xmls'),
    HaveEls = have_label(Result, '$_els'),
    SubElGenerator = case have_label(Result, '$_els') of
                         true ->
                             erl_syntax:list_comp(
                               make_function_call(
                                 "encode",
                                 [erl_syntax:variable("_el")]),
                               [erl_syntax:generator(
                                  erl_syntax:variable("_el"),
                                  label_to_var('$_els'))]);
                         false ->
                             erl_syntax:list([])
                     end,
    XmlElGenerator = case {have_label(Result, '$_xmls'),
                           have_label(Result, '$_els')} of
                         {true, true} ->
                             erl_syntax:infix_expr(
                               label_to_var('$_xmls'),
                               erl_syntax:operator("++"),
                               SubElGenerator);
                         {true, false} ->
                             label_to_var('$_xmls');
                         {false, true} ->
                             SubElGenerator;
                         {false, false} ->
                             erl_syntax:list([])
                     end,
    RefsFun = lists:foldr(
		fun({Label, _}, Acc) ->
			Var = label_to_var(Label),
			make_function_call(
			  make_enc_fun_name([Label,Tag]),
			  [Var, Acc])
		end, erl_syntax:list([]), group_refs(Refs)),
    CDataFun = if HaveRefs and HaveCData ->
		       make_function_call(
			 lists, reverse,
			 [make_function_call(make_enc_fun_name([cdata,Tag]),
					     [label_to_var(CDataLabel),
					      RefsFun])]);
		  HaveRefs and not HaveCData ->
		       make_function_call(lists, reverse, [RefsFun]);
		  HaveCData and not HaveRefs ->
		       make_function_call(make_enc_fun_name([cdata,Tag]),
					     [label_to_var(CDataLabel),
					      erl_syntax:list([])]);
                  true ->
		       erl_syntax:list([])
               end,
    ResFun = if (HaveCData or HaveRefs) and (HaveXMLs or HaveEls) ->
		     erl_syntax:infix_expr(
		       XmlElGenerator, erl_syntax:operator("++"), CDataFun);
		HaveCData or HaveRefs ->
		     CDataFun;
		HaveXMLs or HaveEls ->
		     XmlElGenerator;
		true ->
		     erl_syntax:list([])
	     end,
    AttrFun = lists:foldl(
                fun(#attr{name = AttrName, label = AttrLabel}, Acc) ->
                        Var = label_to_var(prepare_label(AttrLabel, AttrName)),
                        make_function_call(
                          make_enc_fun_name([AttrName,attr,Tag]),
                          [Var, Acc])
                end, erl_syntax:variable("_xmlns_attrs"), Attrs),
    [erl_syntax:function(
       erl_syntax:atom(make_enc_fun_name([Tag])),
       [erl_syntax:clause(
          [subst_labels(Result), erl_syntax:variable("_xmlns_attrs")],
          none,
          [erl_syntax:match_expr(erl_syntax:variable("_els"), ResFun),
           erl_syntax:match_expr(erl_syntax:variable("_attrs"),AttrFun),
           erl_syntax:tuple(
             [erl_syntax:atom("xmlel"),
              abstract(ElemName),
              erl_syntax:variable("_attrs"),
              erl_syntax:variable("_els")])
          ])])] ++ make_ref_enc_funs(Elem, Tag, AllElems).

make_decoding_MFA(Parents, TagName, _TagNS, AttrName,
                  IsRequired, Default, DecMFA, _Types, ModName) ->
    FunName = make_dec_fun_name(Parents),
    Type = case AttrName of
               <<>> -> "cdata";
               _ -> "attr"
           end,
    Clause1 = erl_syntax:clause(
                [erl_syntax:variable("__TopXMLNS"),
		 if Type == "attr" -> erl_syntax:atom(undefined);
                    true -> abstract(<<>>) end],
                none,
                [if IsRequired ->
                         make_erlang_error(
                           ModName,
                           erl_syntax:tuple(
                             [erl_syntax:atom("missing_" ++ Type),
                              abstract(AttrName),
                              abstract(TagName),
                              erl_syntax:variable("__TopXMLNS")]));
                    true ->
                         abstract(Default)
                 end]),
    Body = case DecMFA of
               {M, F, Args} ->
                   make_function_call(
                     M, F,
                     [erl_syntax:variable("_val")|
                      [abstract(Arg) || Arg <- Args]]);
               {F, Args} ->
                   make_function_call(
                     F,
                     [erl_syntax:variable("_val")|
                      [abstract(Arg) || Arg <- Args]]);
               undefined ->
                   erl_syntax:variable("_val")
           end,
    Catch = case DecMFA of
                undefined ->
                    Body;
                _ ->
                    erl_syntax:case_expr(
                      erl_syntax:catch_expr(Body),
                      [erl_syntax:clause(
                         [erl_syntax:tuple([erl_syntax:atom("EXIT"),
                                            erl_syntax:underscore()])],
                         none,
                         [make_erlang_error(
                            ModName,
                            erl_syntax:tuple(
                              [erl_syntax:atom("bad_" ++ Type ++ "_value"),
                               abstract(AttrName),
                               abstract(TagName),
                               erl_syntax:variable("__TopXMLNS")]))]),
                       erl_syntax:clause(
                         [erl_syntax:variable("_res")],
                         none,
                         [erl_syntax:variable("_res")])])
            end,
    Clause2 = erl_syntax:clause(
		[erl_syntax:variable("__TopXMLNS"),
		 erl_syntax:variable("_val")], none, [Catch]),
    [erl_syntax:function(erl_syntax:atom(FunName), [Clause1, Clause2])].

make_encoding_MFA(Parents, AttrName, Required, AttrDefault, EncMFA) ->
    Clause1 = if Required ->
                      [];
                 true ->
                      [erl_syntax:clause(
                         [abstract(AttrDefault),
                          erl_syntax:variable("_acc")],
                         none,
                         [erl_syntax:variable("_acc")])]
              end,
    Body = case EncMFA of
               {M, F, Args} ->
                   make_function_call(
                     M, F,
                     [erl_syntax:variable("_val")|
                      [abstract(Arg) || Arg <- Args]]);
               {F, Args} ->
                   make_function_call(
                     F,
                     [erl_syntax:variable("_val")|
                      [abstract(Arg) || Arg <- Args]]);
               undefined ->
                   erl_syntax:variable("_val")
           end,
    Clause2 = [erl_syntax:clause(
                 [erl_syntax:variable("_val"),
                  erl_syntax:variable("_acc")],
                 none,
                 [erl_syntax:list(
                    [erl_syntax:tuple(
                       [if AttrName /= <<>> -> abstract(AttrName);
                           true -> erl_syntax:atom("xmlcdata")
                        end, Body])],
                    erl_syntax:variable("_acc"))])],
    [erl_syntax:function(
       erl_syntax:atom(make_enc_fun_name(Parents)),
       Clause1 ++ Clause2)].

make_dec_fun_name(Vars) ->
    NewVars = lists:foldl(
                fun(Var, Acc) when is_binary(Var) ->
                        [binary_to_list(Var)|Acc];
                   (Var, Acc) when is_atom(Var) ->
                        [atom_to_list(Var)|Acc];
                   (Var, Acc) ->
                        [Var|Acc]
                end, [], Vars),
    "decode_" ++ string:join(NewVars, "_").

make_enc_fun_name(Vars) ->
    NewVars = lists:foldl(
                fun(Var, Acc) when is_binary(Var) ->
                        [binary_to_list(Var)|Acc];
                   (Var, Acc) when is_atom(Var) ->
                        [atom_to_list(Var)|Acc];
                   (Var, Acc) ->
                        [Var|Acc]
                end, [], Vars),
    "encode_" ++ string:join(NewVars, "_").

%% Fun(Args) -> Body.
make_function(Fun, Args, Body) ->
    erl_syntax:function(
      erl_syntax:atom(Fun),
      [erl_syntax:clause(Args, none, Body)]).

%% Fun(Args).
make_function_call(Fun, Args) ->
    erl_syntax:application(
      none,
      erl_syntax:atom(Fun),
      Args).

%% Mod:Fun(Args).
make_function_call(Mod, Fun, Args) ->
    erl_syntax:application(
      erl_syntax:atom(Mod),
      erl_syntax:atom(Fun),
      Args).

make_erlang_error(Mod, Tuple) ->
    make_function_call(
      erlang, error,
      [erl_syntax:tuple([erl_syntax:atom(Mod), Tuple])]).

abstract(<<>>) ->
    erl_syntax:abstract(<<>>);
abstract(Bin) when is_binary(Bin) ->
    erl_syntax:binary(
      [erl_syntax:abstract(
         binary_to_list(Bin))]);
abstract(Term) ->
    erl_syntax:abstract(Term).

label_to_var(Label) ->
    case atom_to_list(Label) of
        [$$,$_|[H|T]] ->
            erl_syntax:variable(
              replace_invalid_chars(
                [$_, $_, string:to_upper(H)|T]));
        [$$|[H|T]] when H /= $- ->
            erl_syntax:variable(
              replace_invalid_chars(
                [string:to_upper(H)|T]))
    end.

replace_invalid_chars([$-|T]) ->
    [$_|replace_invalid_chars(T)];
replace_invalid_chars([$:|T]) ->
    [$_|replace_invalid_chars(T)];
replace_invalid_chars([$.|T]) ->
    [$_|replace_invalid_chars(T)];
replace_invalid_chars([H|T]) ->
    [H|replace_invalid_chars(T)];
replace_invalid_chars([]) ->
    [].

label_to_record_field(Label) ->
    case atom_to_list(Label) of
        "$_els" ->
            sub_els;
        "$_xmls" ->
            xml_els;
        [$$|T] ->
            list_to_atom(T)
    end.

prepare_label(Label, Name) when is_atom(Name) ->
    prepare_label(Label, erlang:atom_to_binary(Name, utf8));
prepare_label(Label, Name) ->
    if Label == undefined ->
	    list_to_atom(string:to_lower([$$|binary_to_list(Name)]));
       is_atom(Label) ->
	    case atom_to_list(Label) of
		[$$|_] ->
		    Label;
		_ ->
		    ?err("bad 'label': ~p", [Label])
	    end;
       true ->
	    ?err("bad 'label': ~p", [Label])
    end.

tuple_or_single_var([Var]) ->
    Var;
tuple_or_single_var([_|_] = Vars) ->
    erl_syntax:tuple(Vars).

labels_to_underscores(Term) ->
    erl_syntax_lib:map(
      fun(T) ->
              try
                  Label = erl_syntax:atom_value(T),
                  true = is_label(Label),
                  erl_syntax:underscore()
              catch _:_ ->
                      T
              end
      end, abstract(Term)).

have_label(Term, Label) ->
    erl_syntax_lib:fold(
      fun(_, true) ->
              true;
         (T, false) ->
              try
                  L = erl_syntax:atom_value(T),
                  true = is_label(L),
                  Label == L
              catch _:_ ->
                      false
              end
      end, false, abstract(Term)).

get_fun_return_type({dec_enum, [Atoms]}) ->
    erl_types:t_atoms(Atoms);
get_fun_return_type({dec_int, [Min, _]}) ->
    if Min > 0 ->
            erl_types:t_pos_integer();
       Min == 0 ->
            erl_types:t_non_neg_integer();
       Min < 0 ->
            erl_types:t_integer()
    end;
get_fun_return_type({dec_int, []}) ->
    erl_types:t_integer();
get_fun_return_type(undefined) ->
    erl_types:t_binary();
get_fun_return_type(_) ->
    erl_types:t_var('any()').

term_is_record(Term) ->
    try
        [H|_T]= tuple_to_list(Term),
        true = is_atom(H),
        false == is_label(H)
    catch _:_ ->
            false
    end.

term_to_t([H|T], LabelTypes) ->
    erl_types:t_cons(term_to_t(H, LabelTypes), term_to_t(T, LabelTypes));
term_to_t([], _LabelTypes) ->
    erl_types:t_nil();
term_to_t(T, LabelTypes) when is_atom(T) ->
    case is_label(T) of
        true ->
            {_, {Type, Default, IsRequired}} = lists:keyfind(T, 1, LabelTypes),
            if IsRequired ->
                    Type;
               true ->
                    erl_types:t_sup(Type, erl_types:t_from_term(Default))
            end;
        false ->
            erl_types:t_atom(T)
    end;
term_to_t(T, _LabelTypes) when is_bitstring(T) ->
    erl_types:t_bitstr(0, erlang:bit_size(T));
term_to_t(T, _LabelTypes) when is_float(T) ->
    erl_types:t_float();
term_to_t(T, _LabelTypes) when is_function(T) ->
    {arity, Arity} = erlang:fun_info(T, arity),
    erl_types:t_fun(Arity, erl_types:t_any());
term_to_t(T, _LabelTypes) when is_integer(T) ->
    erl_types:t_integer(T);
term_to_t(T, _LabelTypes) when is_pid(T) ->
    erl_types:t_pid();
term_to_t(T, _LabelTypes) when is_port(T) ->
    erl_types:t_port();
term_to_t(T, _LabelTypes) when is_reference(T) ->
    erl_types:t_reference();
term_to_t(T, LabelTypes) when is_tuple(T) ->
    case term_is_record(T) of
        true ->
            RecName = element(1, T),
            erl_types:t_tuple([term_to_t(RecName, LabelTypes)]);
        false ->
            erl_types:t_tuple(
              [term_to_t(E, LabelTypes) || E <- tuple_to_list(T)])
    end.

is_subtype(Term, Type) ->
    erl_types:t_is_subtype(erl_types:t_from_term(Term), Type).

get_types(TaggedElems) ->
    G = build_ref_deps(TaggedElems),
    SortedTags = digraph_utils:topsort(G),
    TypesDict = lists:foldl(
                  fun(RefName, Dict) ->
                          RefElem = get_elem_by_ref(RefName, TaggedElems),
                          Result = RefElem#elem.result,
                          Labels = extract_labels_from_term(Result),
                          LabelTypes =
                              lists:map(
                                fun(Label) ->
                                        {Label, get_label_type(Label, RefElem, Dict)}
                                end, Labels),
                          Type = term_to_t(Result, LabelTypes),
                          dict:store(RefName, Type, Dict)
                  end, dict:new(), SortedTags),
    RecDict = dict:from_list(
                lists:flatmap(
                  fun({Tag, _T}) ->
                          RefElem = get_elem_by_ref(Tag, TaggedElems),
                          case term_is_record(RefElem#elem.result) of
                              true ->
                                  RecName = element(1, RefElem#elem.result),
                                  [{{record, RecName}, [{0, []}]}];
                              false ->
                                  []
                          end
                  end, dict:to_list(TypesDict))),
    {digraph_utils:topsort(G), TypesDict, RecDict}.

extract_labels_from_term(Term) ->
    erl_syntax_lib:fold(
      fun(T, Acc) ->
              try
                  Label = erl_syntax:atom_value(T),
                  true = is_label(Label),
                  [Label|Acc]
              catch _:_ ->
                      Acc
              end
      end, [], abstract(Term)).

get_label_type(Label, Elem, Dict) ->
    case get_spec_by_label(Label, Elem) of
        sub_els ->
            {erl_types:t_list(), [], false};
        xml_els ->
            {erl_types:t_list(), [], false};
        #attr{dec = DecFun, default = Default, required = IsRequired} ->
            {get_fun_return_type(DecFun), Default, IsRequired};
        #cdata{dec = DecFun, default = Default, required = IsRequired} ->
            {get_fun_return_type(DecFun), Default, IsRequired};
        [#ref{min = Min, max = Max, default = Default}|_] = Refs ->
            Types = lists:flatmap(
                      fun(#ref{name = RefTag}) ->
                              case dict:find(RefTag, Dict) of
				  {ok, T} -> [T];
				  error -> []
			      end
                      end, Refs),
            Type = erl_types:t_sup(Types),
            IsRequired = (Min == 1) and (Max == 1),
            if Max == 1 ->
                    {Type, Default, IsRequired};
               true ->
                    {erl_types:t_list(
                       erl_types:t_subtract(
                         Type, erl_types:t_from_term(Default))),
                     [], false}
            end
    end.

build_ref_deps(TaggedElems) ->
    G = digraph:new([acyclic]),
    lists:foreach(
      fun({Tag, Elem}) ->
              digraph:add_vertex(G, Tag),
              lists:foreach(
                fun(#ref{name = RefTag}) ->
                        digraph:add_vertex(G, RefTag),
                        digraph:add_edge(G, RefTag, Tag)
                end, Elem#elem.refs)
      end, TaggedElems),
    G.

get_abstract_code_from_myself() ->
    {file, File} = code:is_loaded(?MODULE),
    case beam_lib:chunks(File, [abstract_code]) of
        {ok, {_, List}} ->
            case lists:keyfind(abstract_code, 1, List) of
                {abstract_code, {raw_abstract_v1, Abstr}} ->
                    {ok, Abstr};
                _ ->
                    error
            end;
        _ ->
            error
    end.

%% make_type_spec(RefTag, {_, TypesDict, RecDict}) ->
%%     ResType = dict:fetch(RefTag, TypesDict),
%%     FunName = make_dec_fun_name([RefTag]),
%%     erl_syntax:text("-spec " ++ FunName ++ "(#xmlel{}) -> "
%%                     ++ erl_types:t_to_string(ResType, RecDict) ++ ".").

%% make_decoding_MFA_type_spec(FunName, Default, DecMFA, IsRequired,
%%                             {_, _, RecTypes}) ->
%%     DefType = erl_types:t_to_string(erl_types:t_from_term(Default), RecTypes),
%%     OutDefType = if IsRequired ->
%%                          erl_types:t_to_string(erl_types:t_none());
%%                     true ->
%%                          DefType
%%                  end,
%%     Indent = lists:duplicate(length(FunName) + 6, $ ),
%%     C1 = "(" ++ DefType ++ ") -> " ++ OutDefType ++ ";" ++ io_lib:nl(),
%%     C2 = "(binary()) -> " ++ erl_types:t_to_string(
%%                                get_fun_return_type(DecMFA),
%%                                RecTypes) ++ ".",
%%     FunName1 = atom_to_string(list_to_atom(FunName)),
%%     erl_syntax:text("-spec " ++ FunName1 ++ C1 ++ Indent ++ C2).

%%====================================================================
%% Auxiliary functions
%%====================================================================
%% Checks
prepare_elem(#elem{name = Name}, _, _, _)
  when not is_binary(Name) ->
    bad_spec({wrong_name, Name});
prepare_elem(#elem{name = Name, xmlns = XMLNS}, _, _, _)
  when not is_binary(XMLNS), not is_list(XMLNS) ->
    bad_spec({wrong_xmlns, XMLNS, Name});
prepare_elem(#elem{name = Name, refs = Refs}, _, _, _) when not is_list(Refs) ->
    bad_spec({wrong_refs, Refs, Name});
prepare_elem(#elem{name = Name, attrs = Attrs}, _, _, _) when not is_list(Attrs) ->
    bad_spec({wrong_attrs, Attrs, Name});
prepare_elem(#elem{name = Name, attrs = Attrs, xmlns = XMLNS,
                   cdata = CData, refs = Refs} = Elem,
             KnownFunctions, AllElems, Opts) ->
    case proplists:get_bool(ignore_xmlns, Opts) of
        false when XMLNS == <<>> ->
            bad_spec({empty_xmlns, Name});
        _ ->
            ok
    end,
    NewAttrs = lists:map(
                 fun(Attr) -> prepare_attr(Name, Attr, KnownFunctions) end,
                 Attrs),
    NewCData = prepare_cdata(Name, CData, KnownFunctions),
    NewRefs = lists:map(
                fun(Ref) -> prepare_ref(Name, Ref, AllElems) end,
                Refs),
    check_labels(Elem),
    Elem#elem{attrs = NewAttrs, cdata = NewCData, refs = NewRefs}.

prepare_ref(Name, #ref{name = RefName}, _)
  when not is_atom(RefName) ->
    bad_spec({wrong_ref_name, RefName, Name});
prepare_ref(Name, #ref{name = RefName, min = Min}, _)
  when not (Min == 0 orelse Min == 1) ->
    bad_spec({wrong_ref_min, Min, RefName, Name});
prepare_ref(Name, #ref{name = RefName, max = Max}, _)
  when not (Max == 1 orelse Max == infinity) ->
    bad_spec({wrong_ref_max, Max, RefName, Name});
prepare_ref(Name, #ref{name = RefName, label = Label}, _)
  when not is_atom(Label) ->
    bad_spec({wrong_ref_label, Label, RefName, Name});
prepare_ref(Name, #ref{name = RefName, label = Label} = Ref, AllElems) ->
    case (is_label(Label) or (Label == undefined)) of
        false ->
            bad_spec({wrong_ref_label_format, Label, RefName, Name});
        true ->
            case lists:keyfind(RefName, 1, AllElems) of
                false ->
                    bad_spec({unresolved_ref, RefName, Name});
                _ ->
                    Ref
            end
    end;
prepare_ref(Name, Junk, _) ->
    bad_spec({not_ref_spec, Junk, Name}).

prepare_attr(Name, #attr{name = AName}, _)
  when not is_binary(AName) ->
    bad_spec({wrong_attr_name, AName, Name});
prepare_attr(Name, #attr{name = AName, label = Label}, _)
  when not is_atom(Label) ->
    bad_spec({wrong_attr_label, Label, AName, Name});
prepare_attr(Name, #attr{name = AName, required = Req}, _)
  when not (Req == false orelse Req == true) ->
    bad_spec({wrong_attr_required, Req, AName, Name});
prepare_attr(Name, #attr{name = AName, label = Label,
                         dec = DecF, enc = EncF} = Attr, KnownFunctions) ->
    NewDecFun = prep_dec_fun(DecF, KnownFunctions),
    NewEncFun = prep_enc_fun(EncF, KnownFunctions),
    case (is_label(Label) or (Label == undefined)) of
        false ->
            bad_spec({wrong_attr_label_format, Label, AName, Name});
        true ->
            Attr#attr{dec = NewDecFun, enc = NewEncFun}
    end;
prepare_attr(Name, Junk, _) ->
    bad_spec({not_attr_spec, Junk, Name}).

prepare_cdata(Name, #cdata{label = Label}, _)
  when not is_atom(Label) ->
    bad_spec({wrong_cdata_label, Label, Name});
prepare_cdata(Name, #cdata{required = Req}, _)
  when not (Req == false orelse Req == true) ->
    bad_spec({wrong_cdata_required, Req, Name});
prepare_cdata(Name, #cdata{label = Label, dec = DecF, enc = EncF} = CData,
                 KnownFunctions) ->
    NewDecFun = prep_dec_fun(DecF, KnownFunctions),
    NewEncFun = prep_enc_fun(EncF, KnownFunctions),
    case (is_label(Label) or (Label == undefined)) of
        false ->
            bad_spec({wrong_cdata_label_format, Label, Name});
        true ->
            CData#cdata{enc = NewEncFun, dec = NewDecFun}
    end;
prepare_cdata(Name, Junk, _) ->
    bad_spec({not_cdata_spec, Junk, Name}).

get_dups(L) ->
    get_dups(L, []).

get_dups([H|T], Acc) ->
    case lists:member(H, T) of
        true ->
            get_dups(T, [H|Acc]);
        false ->
            get_dups(T, Acc)
    end;
get_dups([], Acc) ->
    lists:usort(Acc).

check_labels(#elem{result = Result, attrs = Attrs,
                   refs = Refs, cdata = CData}) ->
    ResultLabels = erl_syntax_lib:fold(
                     fun(T, Acc) ->
                             try
                                 Label = erl_syntax:atom_value(T),
                                 true = is_label(Label),
                                 [Label|Acc]
                             catch _:_ ->
                                     Acc
                             end
                     end, [], abstract(Result)),
    AttrLabels = lists:map(
                   fun(#attr{name = Name, label = Label}) ->
                           prepare_label(Label, Name)
                   end, Attrs),
    CDataLabel = CData#cdata.label,
    RefLabels = lists:map(
                  fun({L, Rs}) ->
                          check_group(L, Rs),
                          L
                  end, group_refs(Refs)),
    AllLabels = AttrLabels ++ [CDataLabel] ++ RefLabels,
    case get_dups(ResultLabels) of
        Dups1 when Dups1 /= [] ->
            bad_spec({duplicated_labels, Dups1});
        _ ->
            ok
    end,
    case get_dups(AllLabels) of
        Dups2 when Dups2 /= [] ->
            bad_spec({duplicated_labels, Dups2});
        _ ->
            ok
    end,
    ResultSet = sets:from_list(ResultLabels),
    AllSet = sets:from_list(AllLabels),
    UnresolvedLabels = sets:to_list(
                         sets:subtract(ResultSet, AllSet)) -- ['$_els', '$_xmls'],
    UnusedLabels = sets:to_list(sets:subtract(AllSet, ResultSet)) -- ['$cdata'],
    if UnresolvedLabels /= [] ->
            bad_spec({unresolved_labels, UnresolvedLabels});
       UnusedLabels /= []->
            bad_spec({unused_labels, UnusedLabels});
       true ->
            ok
    end.

check_group(_Label, [_]) ->
    ok;
check_group(Label, Refs) ->
    #ref{default = Default} = hd(Refs),
    case lists:all(
           fun(#ref{default = D}) ->
                   D == Default
           end, Refs) of
        true ->
            case lists:all(
                   fun(#ref{min = 0, max = 1}) ->
                           true;
                      (_) ->
                           false
                   end, Refs) of
                true ->
                    ok;
                false ->
                    case lists:all(
                           fun(#ref{min = 0, max = infinity}) ->
                                   true;
                              (_) ->
                                   false
                           end, Refs) of
                        true ->
                            ok;
                        false ->
                            bad_spec({wrong_min_max_in_group, Label})
                    end
            end;
        false ->
            bad_spec({different_defaults_in_group, Label})
    end.

prep_dec_fun({Mod, Fun, Args}, _)
  when is_atom(Mod) andalso is_atom(Fun) andalso is_list(Args) ->
    {Mod, Fun, Args};
prep_dec_fun({Fun, Args}, KnownFunctions)
  when is_atom(Fun) andalso is_list(Args) ->
    Arity = length(Args) + 1,
    case erlang:function_exported(?MODULE, Fun, Arity) of
        true ->
            {Fun, Args};
        false ->
            case lists:member({Fun, Arity}, KnownFunctions) of
                true ->
                    {Fun, Args};
                false ->
                    bad_spec({unknown_dec_fun, {Fun, Args}})
            end
    end;
prep_dec_fun(undefined, _) ->
    undefined;
prep_dec_fun(Junk, _) ->
    bad_spec({invalid_dec_fun, Junk}).

prep_enc_fun({Mod, Fun, Args}, _)
  when is_atom(Mod) andalso is_atom(Fun) andalso is_list(Args) ->
    {Mod, Fun, Args};
prep_enc_fun({Fun, Args}, KnownFunctions)
  when is_atom(Fun) andalso is_list(Args) ->
    Arity = length(Args) + 1,
    case erlang:function_exported(?MODULE, Fun, Arity) of
        true ->
            {Fun, Args};
        false ->
            case lists:member({Fun, Arity}, KnownFunctions) of
                true ->
                    {Fun, Args};
                false ->
                    bad_spec({unknown_enc_fun, {Fun, Args}})
            end
    end;
prep_enc_fun(undefined, _) ->
    undefined;
prep_enc_fun(Junk, _) ->
    bad_spec({invalid_enc_fun, Junk}).

is_label(Label) when not is_atom(Label) ->
    false;
is_label(Label) ->
    case atom_to_list(Label) of
        "$_els" ->
            true;
        "$_xmls" ->
            true;
        [$$,$_|_] ->
            false;
        [$$,$-|_] ->
            false;
        [$$,_|_] ->
            true;
        _ ->
            false
    end.

bad_spec(Err) ->
    erlang:error({bad_spec, Err}).

%% @hidden
%% @doc Same as file:consult, but expands known records.
consult(Path) ->
    case get_forms(Path) of
        {ok, Forms} ->
            {Terms, OtherForms} =
                lists:foldl(
                  fun([Form], {Trms, Other}) ->
                          Trm = 
                              erl_syntax_lib:map(
                                fun(T) ->
                                        case erl_syntax:type(T) of
                                            record_expr ->
                                                record_to_tuple(T);
                                            _ ->
                                                T
                                        end
                                end, erl_syntax:form_list([Form])),
                          {[Trm|Trms], Other};
                     (Form, {Trms, Other}) ->
                          {Trms, [Form|Other]}
                  end, {[], []}, Forms),
            TmpFile = filename:join([filename:dirname(Path),
                                     filename:basename(Path) ++ "~"]),
            Str = lists:map(
                    fun(Tree) ->
                            AbsForm = erl_syntax:revert_forms(Tree),
                            case catch erl_eval:exprs(AbsForm, []) of
                                {'EXIT', _} ->
                                    [];
                                {value, Term, _} ->
                                    [io_lib:print(Term), $., io_lib:nl()]
                            end
                    end, Terms),
            Res = case file:write_file(TmpFile, Str) of
                      ok ->
                          case file:consult(TmpFile) of
                              {ok, R} ->
                                  {ok, R, OtherForms};
                              Err ->
                                  Err
                          end;
                      Err ->
                          Err
                  end,
            catch file:delete(TmpFile),
            Res;
        Err ->
            Err
    end.

record_to_tuple(R) ->
    Name = erl_syntax:record_expr_type(R),
    AtomName = list_to_atom(erl_syntax:atom_name(Name)),
    case lists:member(AtomName, [attr, cdata, elem, ref]) of
        true ->
            record_to_tuple(R, tag_record(AtomName));
        false ->
            bad_spec({unknown_record, AtomName})
    end.

tag_record(attr) ->
    tag_record(#attr{}, record_info(fields, attr));
tag_record(cdata) ->
    tag_record(#cdata{}, record_info(fields, cdata));
tag_record(ref) ->
    tag_record(#ref{}, record_info(fields, ref));
tag_record(elem) ->
    tag_record(#elem{}, record_info(fields, elem)).

tag_record(R, Fs) ->
    [_|Vs] = tuple_to_list(R),
    lists:zip(Fs, Vs).

record_to_tuple(R, TaggedRecord) ->
    Name = erl_syntax:record_expr_type(R),
    Fs = erl_syntax:record_expr_fields(R),
    KeyVals = lists:map(
                fun(F) ->
                        Key = list_to_atom(
                                erl_syntax:atom_name(
                                  erl_syntax:record_field_name(F))),
                        Val = erl_syntax:record_field_value(F),
                        {Key, Val}
                end, Fs),
    case get_dups([K || {K, _} <- KeyVals]) of
        Dups when Dups /= [] ->
            bad_spec({duplicated_record_fields, Dups});
        _ ->
            ok
    end,
    case sets:to_list(sets:subtract(
                        sets:from_list([K || {K, _} <- KeyVals]),
                        sets:from_list([K || {K, _} <- TaggedRecord]))) of
        Undef when Undef /= [] ->
            bad_spec({undefined_record_fields, Undef});
        _ ->
            ok
    end,
    Vals = lists:map(
             fun({K, Default}) ->
                     case lists:keyfind(K, 1, KeyVals) of
                         {_, Val} ->
                             Val;
                         false ->
                             erl_syntax:abstract(Default)
                     end
             end, TaggedRecord),
    erl_syntax:tuple([Name|Vals]).

get_forms(Path) ->
    case file:open(Path, [read]) of
        {ok, Fd} ->
            parse(Fd, 1, []);
        Err ->
            Err
    end.

parse(Fd, Line, Acc) ->
    {ok, Pos} = file:position(Fd, cur),
    case epp_dodger:parse_form(Fd, Line) of
        {ok, Form, NewLine} ->
	    case erl_syntax:type(Form) of
		attribute ->
		    {ok, NewPos} = file:position(Fd, cur),
		    {ok, RawForm} = file:pread(Fd, Pos, NewPos - Pos),
		    file:position(Fd, {bof, NewPos}),
		    AnnForm = erl_syntax:set_ann(Form, RawForm),
		    parse(Fd, NewLine, [AnnForm|Acc]);
		_ ->
		    parse(Fd, NewLine, [Form|Acc])
	    end;
        {eof, _} ->
            {ok, lists:reverse(Acc)};
        _Err ->
            file:position(Fd, {bof, Pos}),
            case io:scan_erl_exprs(Fd, "", Line) of
                {ok, Toks, NewLine} ->
                    case transform_spec_to_form(Toks) of
                        {ok, Form} ->
                            parse(Fd, NewLine, [Form|Acc]);
                        not_spec ->
                            parse(Fd, NewLine, Acc);
                        Err ->
                            Err
                    end;
                {eof, _} ->
                    {ok, lists:reverse(Acc)};
                Err ->
                    Err
            end
    end.

transform_spec_to_form([{'-', L0}, {atom, _, 'xml'}, {'(', _}|T]) ->
    case lists:reverse(T) of
        [{dot, L3}, {')', L2}|T1] ->
            T2 = lists:reverse([{dot, L3}, {'}', L2}|T1]),
            case erl_parse:parse_exprs([{'{', L0}|T2]) of
                {ok, Form} ->
                    {ok, Form};
                Err ->
                    Err
            end;
        _ ->
            not_spec
    end;
transform_spec_to_form(_) ->
    not_spec.
