:- module(json_ld, [
              expand/2,
              expand/3,
              compress/3,
              term_jsonld/2
          ]).

/** <module> JSON_LD
 * 
 * Definitions for translating and manipulating JSON_LD
 * 
 * * * * * * * * * * * * * COPYRIGHT NOTICE  * * * * * * * * * * * * * * *
 *                                                                       *
 *  This file is part of TerminusDB.                                      *
 *                                                                       *
 *  TerminusDB is free software: you can redistribute it and/or modify    *
 *  it under the terms of the GNU General Public License as published by *
 *  the Free Software Foundation, either version 3 of the License, or    *
 *  (at your option) any later version.                                  *
 *                                                                       *
 *  TerminusDB is distributed in the hope that it will be useful,         *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of       *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the        *
 *  GNU General Public License for more details.                         *
 *                                                                       *
 *  You should have received a copy of the GNU General Public License    *
 *  along with TerminusDB.  If not, see <https://www.gnu.org/licenses/>.  *
 *                                                                       *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

:- use_module(library(pairs)).
:- use_module(library(utils)).
:- use_module(library(http/json)).
:- use_module(library(mavis)).

/** 
 * expand(+JSON_LD, -JSON) is det.
 * 
 * Expands from JSON_LD prefixed format to fully expanded form.
 */ 
expand(JSON_LD, JSON) :-
    get_dict_default('@context', JSON_LD, Context, _{}),
    expand_context(Context,Context_Expanded),
    expand(JSON_LD, Context_Expanded, JSON).

/** 
 * expand(+JSON_LD, +Context:dict, -JSON) is det.
 * 
 * Expands from JSON_LD prefixed format to fully expanded form.
 */ 
expand(JSON_LD, Context, JSON) :-
    is_dict(JSON_LD),
    !,
    get_dict_default('@context', JSON_LD, New_Context, _{}),
    
    merge_dictionaries(Context,New_Context,Local_Context),
    
    dict_keys(JSON_LD,Keys),
    findall(Key-Value,
            (
                member(K,Keys),
                get_dict(K,JSON_LD,V),

                (   member(K,['@id','@type'])
                ->  prefix_expand(V,Local_Context,Value),
                    Key = K
                ;   K='@context'
                ->  Key = K,
                    Value = V
                ;   expand_key(K,Local_Context,Key_Candidate,Key_Context),
                    expand(V,Local_Context,Expanded),
                    (   is_dict(Expanded)
                    ->  merge_dictionaries(Key_Context,Expanded,Value),
                        Key = Key_Candidate
                    ;   _{'@type' : "@id"} = Key_Context
                    ->  Key = Key_Candidate,
                        Value = _{'@id' : Expanded}
                    ;   _{'@type' : "@id", '@id' : ID} = Key_Context,
                        prefix_expand(ID,Local_Context,Key),
                        Value = _{'@id' : Expanded}
                    ;   _{'@type' : Type} = Key_Context
                    ->  prefix_expand(Type,Local_Context,EType),
                        Key = Key_Candidate,
                        Value = _{'@value' : Expanded,
                                  '@type' : EType}
                    ;   _{'@language' : Lang} = Key_Context
                    ->  prefix_expand(Lang,Local_Context,EType),
                        Key = Key_Candidate,
                        Value = _{'@value' : Expanded,
                                  '@language' : EType}
                    ;   _{} = Key_Context
                    ->  Key = Key_Candidate,
                        Value = Expanded
                    ;   format(atom(M),'Unknown key context ~q', [Key_Context]),
                        throw(error(M))
                    )
                )                
            ),
            Data),
    dict_create(JSON,_,Data).
expand(JSON_LD, Context, JSON) :-
    is_list(JSON_LD),
    !,
    maplist({Context}/[JL,J]>>(expand(JL,Context,J)),JSON_LD,JSON).
expand(JSON, _, JSON) :-
    atom(JSON),
    !.
expand(JSON, _, JSON) :-
    string(JSON).

prefix_expand(K,Context,Key) :-
    (   split_atom(K,':',[Prefix,Suffix]),
        get_dict(Prefix,Context,Expanded)
    ->  atom_concat(Expanded,Suffix,Key)
    ;   K = Key).

/* 
 * expand_context(+Context,-Context_Expanded) is det. 
 *
 * Expand all prefixes in the context for other elements of the context
 */
expand_context(Context,Context_Expanded) :-
    dict_pairs(Context,_,Pairs),
    maplist({Context}/[K-V,Key-V]>>(prefix_expand(K,Context,Key)), Pairs, Expanded_Pairs),
    dict_create(Context_Expanded, _, Expanded_Pairs).

/* 
 * expand_key(+K,+Context,-Key,-Value) is det.
 */
expand_key(K,Context,Key,Value) :-
    prefix_expand(K,Context,Key_Candidate),
    (   get_dict(Key_Candidate,Context,R)
    ->  (   is_dict(R)
        ->  Key = Key_Candidate,
            Value = R
        ;   string_to_atom(R,Key),
            Value = _{})
    ;   Key = Key_Candidate,
        Value = _{}).

/* 
 * compress_uri(URI, Key, Prefix, Compressed) is det. 
 * 
 * Take a URI and a context and compress uris such that
 * Ctx = { foo : 'http://example.com/' }
 * URI = 'http://example.com/bar' 
 * compresses to => foo:bar
 */
compress_uri(URI, Key, Prefix, Comp) :-
    sub_atom(URI, _, Length, After, Prefix),
    sub_atom(URI, Length, After, _, Rest),
    atomic_list_concat([Key,':',Rest], Comp).

compress_pairs_uri(URI, Pairs, Folded_URI) :-
    (   member(Prefix-Expanded, Pairs),
        compress_uri(URI, Prefix, Expanded, Folded_URI)
    ->  true
    ;   URI = Folded_URI).

/* 
 * compress(JSON,Context,JSON_LD) is det.
 * 
 * Replace expanded URIs using Context.
 */
compress(JSON,Context,JSON_LD) :-
    dict_pairs(Context, _, Pairs),
    include([_A-B]>>(atom(B)), Pairs, Valid_Pairs),
    compress_aux(JSON,Valid_Pairs,JSON_Pre),
    merge_dictionaries(_{'@context' : Context}, JSON_Pre, JSON_LD).
    
compress_aux(JSON,Ctx_Pairs,JSON_LD) :-
    is_dict(JSON),
    !,
    dict_pairs(JSON, _, JSON_Pairs),
    maplist({Ctx_Pairs}/[Key-Value,Folded_Key-Folded_Value]>>(
                compress_pairs_uri(Key, Ctx_Pairs, Folded_Key),
                compress_aux(Value, Ctx_Pairs, Folded_Value)
            ),
            JSON_Pairs,
            Folded_JSON_Pairs),
    dict_create(JSON_LD, _,Folded_JSON_Pairs).
compress_aux(JSON,Ctx_Pairs,JSON_LD) :-
    is_list(JSON),
    !,
    maplist({Ctx_Pairs}/[Obj,Transformed]>>( compress_aux(Obj,Ctx_Pairs,Transformed)), JSON, JSON_LD).
compress_aux(JSON,_Ctx_Pairs,JSON) :-
    string(JSON),
    !.
compress_aux(JSON,_Ctx_Pairs,JSON) :-
    number(JSON),
    !.
compress_aux(URI,Ctx_Pairs,Folded_URI) :-
    atom(URI),
    compress_pairs_uri(URI,Ctx_Pairs,Folded_URI).

/* 
 * term_jsonld(Term,JSON) is det.
 * 
 * expand a prolog internal json representation to dicts. 
 */
term_jsonld(literal(type(T,D)),_{'@type' : T, '@value' : D}).
term_jsonld(literal(lang(L,D)),_{'@language' : L, '@value' : D}).
term_jsonld(Term,JSON) :-
    is_list(Term),
    maplist([A=B,A-JSON_B]>>(term_jsonld(B,JSON_B)), Term, JSON_List),
    % We are a dictionary not a list.
    !,
    dict_pairs(JSON, _, JSON_List).
term_jsonld(Term,JSON) :-
    is_list(Term),
    !,
    maplist([Obj,JSON]>>(term_jsonld(Obj,JSON)), Term, JSON).
term_jsonld(JSON,JSON).
