:- module(api_init, [
              bootstrap_files/0,
              initialize_config/4,
              initialize_registry/0,
              initialize_database/2,
              initialize_database_with_store/2
          ]).

:- use_module(core(triple)).
:- use_module(core(util)).
:- use_module(core(document)).
:- use_module(core(query), [expand/2, default_prefixes/1]).
:- use_module(core(transaction), [open_descriptor/2]).

:- use_module(library(semweb/turtle)).
:- use_module(library(terminus_store)).
:- use_module(library(http/json)).

/**
 * create_graph_from_turtle(DB:database, Graph_ID:graph_identifier, Turtle:string) is det.
 *
 * Reads in Turtle String and writes initial database.
 */
create_graph_from_turtle(Store, Graph_ID, TTL_Path) :-
    safe_create_named_graph(Store,Graph_ID,Graph_Obj),
    open_write(Store, Builder),

    % write to a temporary builder.
    rdf_process_turtle(
        TTL_Path,
        {Builder}/
        [Triples,_Resource]>>(
            forall(member(T, Triples),
                   (   normalise_triple(T, rdf(X,P,Y)),
                       object_storage(Y,S),
                       nb_add_triple(Builder, X, P, S)))),
        []),
    % commit this builder to a temporary layer to perform a diff.
    nb_commit(Builder,Layer),
    nb_set_head(Graph_Obj, Layer).

json_read_dict_stream(Stream,Term) :-
    repeat,
    json_read_dict(Stream, Term, [default_tag(json),end_of_file(eof)]),
    (   Term = eof
    ->  !,
        fail
    ;   true).

%%
% create_graph_from_json(+Store,+Graph_ID,+JSON_Stream,+Type:graph_type,-Layer) is det.
%
% Type := instance | schema(Database)
%
create_graph_from_json(Store, Graph_ID, JSON_Stream, Type, Layer) :-
    safe_create_named_graph(Store,Graph_ID,Graph_Obj),
    open_write(Store, Builder),

    write_json_stream_to_builder(JSON_Stream, Builder, Type),
    % commit this builder to a temporary layer to perform a diff.
    nb_commit(Builder,Layer),
    nb_set_head(Graph_Obj, Layer),
    test_utils:print_all_triples(Layer).

write_json_stream_to_builder(JSON_Stream, Builder, schema) :-
    !,
    json_read_dict(JSON_Stream, Context, [default_tag(json),end_of_file(eof)]),

    (   Context = eof
    ;   is_dict(Context),
        \+ get_dict('@type', Context, "@context")
    ->  throw(error(no_context_found_in_schema))
    ;   true
    ),

    forall(
        context_triple(Context,t(S,P,O)),
        (
            object_storage(O,OS),
            nb_add_triple(Builder, S, P, OS)
        )
    ),

    default_prefixes(Prefixes),
    put_dict(Context,Prefixes,Expanded_Context),

    forall(
        json_read_dict_stream(JSON_Stream, Dict),
        (
            forall(
                json_schema_triple(Dict,Expanded_Context,t(S,P,O)),
                (
                    object_storage(O,OS),
                    nb_add_triple(Builder, S, P, OS)
                )
            )
        )
    ).
write_json_stream_to_builder(JSON_Stream, Builder, instance(DB)) :-
    database_context(DB,Context),
    default_prefixes(Prefixes),

    put_dict(Context,Prefixes,Expanded_Context),

    forall(
        json_read_dict_stream(JSON_Stream, Dict),
        (
            forall(
                json_triple(DB,Dict,Expanded_Context,t(S,P,O)),
                (
                    object_storage(O,OS),
                    nb_add_triple(Builder, S, P, OS)
                )
            )
        )
    ).

:- dynamic template_system_instance/1.
:- dynamic system_schema/1.
:- dynamic repo_schema/1.
:- dynamic layer_schema/1.
:- dynamic ref_schema/1.
bootstrap_files :-
    template_system_instance_json(InstancePath),
    file_to_predicate(InstancePath, template_system_instance),
    system_schema_json(SchemaPath),
    file_to_predicate(SchemaPath, system_schema),
    repository_schema_json(RepoPath),
    file_to_predicate(RepoPath, repo_schema),
    ref_schema_json(RefSchemaPath),
    file_to_predicate(RefSchemaPath, ref_schema).

template_system_instance_json(Path) :-
    once(expand_file_search_path(ontology('system_instance_template.json'), Path)).

system_schema_json(Path) :-
    once(expand_file_search_path(ontology('system_schema.json'), Path)).

repository_schema_json(Path) :-
    once(expand_file_search_path(ontology('repository.json'), Path)).

ref_schema_json(Path) :-
    once(expand_file_search_path(ontology('ref.json'), Path)).

config_path(Path) :-
    once(expand_file_search_path(config('terminus_config.pl'), Path)).

config_template_path(Path) :-
    once(expand_file_search_path(template('config-template.tpl'), Path)).

index_url(PublicUrl, PublicUrl, Opts) :-
    memberchk(autoattach(AutoAttach), Opts),
    AutoAttach,
    !.
index_url(_, "", _).

index_key(Key, Key, Opts) :-
    memberchk(autologin(AutoLogin), Opts),
    AutoLogin,
    !.
index_key(_, "", _).

replace_in_file(Path, Pattern, With) :-
    read_file_to_string(Path, FileString, []),
    atomic_list_concat(Split, Pattern, FileString),
    atomic_list_concat(Split, With, NewFileString),
    open(Path, write, FileStream),
    write(FileStream, NewFileString),
    close(FileStream).

write_config_file(Public_URL, Config_Tpl_Path, Config_Path, Server_Name, Port, Workers) :-
    open(Config_Tpl_Path, read, Tpl_Stream),
    read_string(Tpl_Stream, _, Tpl_String),
    close(Tpl_Stream),
    open(Config_Path, write, Stream),
    format(Stream, Tpl_String, [Server_Name, Port, Public_URL, Workers]),
    close(Stream).

write_index_file(Index_Tpl_Path, Index_Path, Password) :-
    open(Index_Tpl_Path, read, Tpl_Stream),
    read_string(Tpl_Stream, _, Tpl_String),
    close(Tpl_Stream),
    open(Index_Path, write, Stream),
    config:console_base_url(BaseURL),
    format(Stream, Tpl_String, [BaseURL, Password, BaseURL]),
    close(Stream).

initialize_config(PUBLIC_URL, Server, Port, Workers) :-
    config_template_path( Config_Tpl_Path),
    config_path(Config_Path),
    write_config_file(PUBLIC_URL, Config_Tpl_Path, Config_Path, Server,
                      Port, Workers).

initialize_registry :-
    config:registry_path(Registry_Path),
    (   exists_file(Registry_Path)
    ->  true
    ;   example_registry_path(Example_Registry_Path),
        copy_file(Example_Registry_Path, Registry_Path)
    ).

initialize_database(Key,Force) :-
    db_path(DB_Path),
    initialize_database_with_path(Key, DB_Path, Force).

storage_version_path(DB_Path,Path) :-
    atomic_list_concat([DB_Path,'/STORAGE_VERSION'],Path).

/*
 * initialize_database_with_path(Key,DB_Path,Force) is det+error.
 *
 * initialize the database unless it already exists or Force is false.
 */
initialize_database_with_path(_, DB_Path, false) :-
    storage_version_path(DB_Path, Version),
    exists_file(Version),
    throw(error(storage_already_exists(DB_Path),_)).
initialize_database_with_path(Key, DB_Path, _) :-
    make_directory_path(DB_Path),
    delete_directory_contents(DB_Path),
    initialize_storage_version(DB_Path),
    open_directory_store(DB_Path, Store),
    initialize_database_with_store(Key, Store).

initialize_storage_version(DB_Path) :-
    storage_version_path(DB_Path,Path),
    open(Path, write, FileStream),
    writeq(FileStream, 1),
    close(FileStream).

initialize_database_with_store(Key, Store) :-
    crypto_password_hash(Key,Hash, [cost(15)]),

    system_schema(System_Schema_String),
    open_string(System_Schema_String, System_Schema_Stream),
    system_schema_name(Schema_Name),
    create_graph_from_json(Store,Schema_Name,System_Schema_Stream,schema,Schema),

    layer_to_id(Schema,ID),
    Descriptor = id_descriptor{ id: ID, type: schema},
    open_descriptor(Descriptor, Transaction_Object),
    template_system_instance(Template_Instance_String),
    format(string(Instance_String), Template_Instance_String, [Hash]),
    open_string(Instance_String, Instance_Stream),
    system_instance_name(Instance_Name),
    create_graph_from_json(Store,Instance_Name,Instance_Stream,
                           instance(Transaction_Object),_),

    ref_schema(Ref_Schema_String),
    open_string(Ref_Schema_String, Ref_Schema_Stream),
    ref_ontology(Ref_Name),
    create_graph_from_json(Store,Ref_Name,Ref_Schema_Stream,schema,_),

    repo_schema(Repo_Schema_String),
    open_string(Repo_Schema_String, Repo_Schema_Stream),
    repository_ontology(Repository_Name),
    create_graph_from_json(Store,Repository_Name,Repo_Schema_Stream,schema,_).

:- begin_tests(api_init).
:- use_module(core(util)).
:- use_module(library(terminus_store)).
:- use_module(core(query), [ask/2]).

test(write_json_stream_to_builder, [
         setup(
             (   open_memory_store(Store),
                 open_write(Store,Builder)
             )
         )
     ]) :-

    open_string(
    '{ "@type" : "@context",
       "@base" : "http://terminusdb.com/system/schema#",
        "type" : "http://terminusdb.com/type#" }

     { "@id" : "User",
       "@type" : "Class",
       "key_hash" : "type:string",
       "capability" : { "@type" : "Set",
                        "@class" : "Capability" } }',Stream),

    write_json_stream_to_builder(Stream, Builder,schema),
    nb_commit(Builder,Layer),

    findall(
        t(X,Y,Z),
        triple(Layer,X,Y,Z),
        Triples),

    Triples = [
        t("http://terminusdb.com/system/schema#User","http://terminusdb.com/system/schema#capability",node("http://terminusdb.com/system/schema#User_capability_Set_Capability")),
        t("http://terminusdb.com/system/schema#User","http://terminusdb.com/system/schema#key_hash",node("http://terminusdb.com/type#string")),
        t("http://terminusdb.com/system/schema#User","http://www.w3.org/1999/02/22-rdf-syntax-ns#type",node("http://terminusdb.com/schema/sys#Class")),
        t("http://terminusdb.com/system/schema#User_capability_Set_Capability","http://terminusdb.com/schema/sys#class",node("http://terminusdb.com/system/schema#Capability")),
        t("http://terminusdb.com/system/schema#User_capability_Set_Capability","http://www.w3.org/1999/02/22-rdf-syntax-ns#type",node("http://terminusdb.com/schema/sys#Set")),

        t("terminusdb://Prefix_Pair_5450b0648f2f15c2864f8853747d484b","http://terminusdb.com/schema/sys#prefix",value("\"type\"^^'http://www.w3.org/2001/XMLSchema#string'")),
        t("terminusdb://Prefix_Pair_5450b0648f2f15c2864f8853747d484b","http://terminusdb.com/schema/sys#url",value("\"http://terminusdb.com/type#\"^^'http://www.w3.org/2001/XMLSchema#string'")),
        t("terminusdb://Prefix_Pair_5450b0648f2f15c2864f8853747d484b","http://www.w3.org/1999/02/22-rdf-syntax-ns#type",node("http://terminusdb.com/schema/sys#Prefix")),
        t("terminusdb://context","http://terminusdb.com/schema/sys#base",value("\"http://terminusdb.com/system/schema#\"^^'http://www.w3.org/2001/XMLSchema#string'")),
        t("terminusdb://context","http://terminusdb.com/schema/sys#prefix_pair",node("terminusdb://Prefix_Pair_5450b0648f2f15c2864f8853747d484b")),
        t("terminusdb://context","http://www.w3.org/1999/02/22-rdf-syntax-ns#type",node("http://terminusdb.com/schema/sys#Context"))
    ].

:- end_tests(api_init).