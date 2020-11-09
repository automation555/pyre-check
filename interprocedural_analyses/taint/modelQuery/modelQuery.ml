(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Ast
open Analysis
open Interprocedural
open Taint
open Model
open Pyre

let matches_pattern ~pattern name = Re2.matches (Re2.create_exn pattern) name

let rec matches_constraint query_constraint ~resolution ~callable =
  let get_callable_type =
    Memo.unit (fun () -> Callable.get_module_and_definition ~resolution callable >>| snd)
  in
  let matches_annotation_constraint ~annotation_constraint ~annotation =
    match annotation_constraint with
    | ModelQuery.IsAnnotatedTypeConstraint -> (
        match annotation with
        | Type.Annotated _ -> true
        | _ -> false )
  in
  match query_constraint with
  | ModelQuery.NameConstraint pattern ->
      matches_pattern ~pattern (Callable.external_target_name callable)
  | ModelQuery.ReturnConstraint annotation_constraint -> (
      let callable_type = get_callable_type () in
      match callable_type with
      | Some
          {
            Node.value =
              {
                Statement.Define.signature =
                  { Statement.Define.Signature.return_annotation = Some annotation; _ };
                _;
              };
            _;
          } ->
          matches_annotation_constraint
            ~annotation_constraint
            ~annotation:(GlobalResolution.parse_annotation resolution annotation)
      | _ -> false )
  | ModelQuery.AnyParameterConstraint (ModelQuery.AnnotationConstraint annotation_constraint) -> (
      let callable_type = get_callable_type () in
      match callable_type with
      | Some
          {
            Node.value =
              { Statement.Define.signature = { Statement.Define.Signature.parameters; _ }; _ };
            _;
          } ->
          List.exists
            parameters
            ~f:(fun { Node.value = { Expression.Parameter.annotation; _ }; _ } ->
              match annotation with
              | Some annotation ->
                  matches_annotation_constraint
                    ~annotation_constraint
                    ~annotation:(GlobalResolution.parse_annotation resolution annotation)
              | None -> false)
      | _ -> false )
  | ModelQuery.AnyOf constraints ->
      List.exists constraints ~f:(matches_constraint ~resolution ~callable)


let apply_productions ~resolution ~productions ~callable =
  let definition = Callable.get_module_and_definition ~resolution callable in
  match definition with
  | None -> []
  | Some
      ( _,
        {
          Node.value =
            {
              Statement.Define.signature =
                { Statement.Define.Signature.parameters; return_annotation; _ };
              _;
            };
          _;
        } ) ->
      let production_to_taint ~annotation ~production =
        let open Expression in
        let get_subkind_from_annotation ~pattern annotation =
          let get_annotation_of_type annotation =
            match annotation >>| Node.value with
            | Some (Expression.Call { Call.callee = { Node.value = callee; _ }; arguments }) -> (
                match callee with
                | Name
                    (Name.Attribute
                      {
                        base =
                          { Node.value = Name (Name.Attribute { attribute = "Annotated"; _ }); _ };
                        _;
                      }) -> (
                    match arguments with
                    | [
                     {
                       Call.Argument.value = { Node.value = Expression.Tuple [_; annotation]; _ };
                       _;
                     };
                    ] ->
                        Some annotation
                    | _ -> None )
                | _ -> None )
            | _ -> None
          in
          match get_annotation_of_type annotation with
          | Some
              {
                Node.value =
                  Expression.Call
                    {
                      Call.callee = { Node.value = Name (Name.Identifier callee_name); _ };
                      arguments =
                        [
                          {
                            Call.Argument.value = { Node.value = Name (Name.Identifier subkind); _ };
                            _;
                          };
                        ];
                    };
                _;
              } ->
              if String.equal callee_name pattern then
                Some subkind
              else
                None
          | _ -> None
        in
        match production with
        | ModelQuery.TaintAnnotation taint_annotation -> Some taint_annotation
        | ModelQuery.ParametricSourceFromAnnotation { source_pattern; kind } ->
            get_subkind_from_annotation ~pattern:source_pattern annotation
            >>| fun subkind ->
            Source
              {
                source = Sources.ParametricSource { source_name = kind; subkind };
                breadcrumbs = [];
                path = [];
                leaf_name_provided = false;
              }
        | ModelQuery.ParametricSinkFromAnnotation { sink_pattern; kind } ->
            get_subkind_from_annotation ~pattern:sink_pattern annotation
            >>| fun subkind ->
            Sink
              {
                sink = Sinks.ParametricSink { sink_name = kind; subkind };
                breadcrumbs = [];
                path = [];
                leaf_name_provided = false;
              }
      in
      let normalized_parameters = AccessPath.Root.normalize_parameters parameters in
      let apply_production = function
        | ModelQuery.ReturnTaint productions ->
            List.filter_map productions ~f:(fun production ->
                production_to_taint ~annotation:return_annotation ~production
                >>| fun taint -> ReturnAnnotation, taint)
        | ModelQuery.ParameterTaint { name; taint = productions } -> (
            let parameter =
              List.find_map
                normalized_parameters
                ~f:(fun ( root,
                          parameter_name,
                          { Node.value = { Expression.Parameter.annotation; _ }; _ } )
                        ->
                  if Identifier.equal_sanitized parameter_name name then
                    Some (root, annotation)
                  else
                    None)
            in
            match parameter with
            | Some (parameter, annotation) ->
                List.filter_map productions ~f:(fun production ->
                    production_to_taint ~annotation ~production
                    >>| fun taint -> ParameterAnnotation parameter, taint)
            | None -> [] )
        | ModelQuery.PositionalParameterTaint { index; taint = productions } -> (
            let parameter =
              List.find_map
                normalized_parameters
                ~f:(fun (root, _, { Node.value = { Expression.Parameter.annotation; _ }; _ }) ->
                  match root with
                  | AccessPath.Root.PositionalParameter { position; _ } when position = index ->
                      Some (root, annotation)
                  | _ -> None)
            in
            match parameter with
            | Some (parameter, annotation) ->
                List.filter_map productions ~f:(fun production ->
                    production_to_taint ~annotation ~production
                    >>| fun taint -> ParameterAnnotation parameter, taint)
            | None -> [] )
        | ModelQuery.AllParametersTaint taint ->
            let apply_parameter_production
                ((root, _, { Node.value = { Expression.Parameter.annotation; _ }; _ }), production)
              =
              production_to_taint ~annotation ~production
              >>| fun taint -> ParameterAnnotation root, taint
            in
            List.cartesian_product normalized_parameters taint
            |> List.filter_map ~f:apply_parameter_production
      in
      List.concat_map productions ~f:apply_production


let apply_query_rule
    ~verbose
    ~resolution
    ~rule:{ ModelQuery.rule_kind; query; productions; name }
    ~callable
  =
  let kind_matches =
    match callable, rule_kind with
    | `Function _, ModelQuery.FunctionModel
    | `Method _, ModelQuery.MethodModel ->
        true
    | _ -> false
  in

  if kind_matches && List.for_all ~f:(matches_constraint ~resolution ~callable) query then begin
    if verbose then
      Log.info
        "Callable `%a` matches all constraints for the model query rule%s."
        Callable.pretty_print
        (callable :> Callable.t)
        (name |> Option.map ~f:(Format.sprintf " `%s`") |> Option.value ~default:"");
    apply_productions ~resolution ~productions ~callable
  end
  else
    []


let apply_all_rules ~resolution ~scheduler ~configuration ~rule_filter ~rules ~callables ~models =
  let global_resolution = Resolution.global_resolution resolution in
  if List.length rules > 0 then
    let sources_to_keep, sinks_to_keep =
      ModelParser.compute_sources_and_sinks_to_keep ~configuration ~rule_filter
    in
    let apply_rules models callable =
      let taint_to_model =
        List.concat_map rules ~f:(fun rule ->
            apply_query_rule
              ~verbose:configuration.dump_model_query_results
              ~resolution:global_resolution
              ~rule
              ~callable)
      in
      if not (List.is_empty taint_to_model) then
        match
          ModelParser.create_model_from_annotations
            ~resolution
            ~callable
            ~sources_to_keep
            ~sinks_to_keep
            taint_to_model
        with
        | Some model ->
            let models =
              let model =
                match Callable.Map.find models (callable :> Callable.t) with
                | Some existing_model -> Taint.Result.join ~iteration:0 existing_model model
                | None -> model
              in
              Callable.Map.set models ~key:(callable :> Callable.t) ~data:model
            in
            models
        | _ -> models
      else
        models
    in
    let callables =
      List.filter_map callables ~f:(function
          | `Function _ as callable -> Some (callable :> Callable.real_target)
          | `Method _ as callable -> Some (callable :> Callable.real_target)
          | _ -> None)
    in
    let merge_models new_models models =
      Map.merge_skewed new_models models ~combine:(fun ~key:_ left right ->
          Taint.Result.join ~iteration:0 left right)
    in
    let new_models =
      Scheduler.map_reduce
        scheduler
        ~policy:
          (Scheduler.Policy.fixed_chunk_count
             ~minimum_chunk_size:500
             ~preferred_chunks_per_worker:1
             ())
        ~initial:Callable.Map.empty
        ~map:(fun models callables -> List.fold callables ~init:models ~f:apply_rules)
        ~reduce:(fun new_models models ->
          Map.merge_skewed new_models models ~combine:(fun ~key:_ left right ->
              Taint.Result.join ~iteration:0 left right))
        ~inputs:callables
        ()
    in
    merge_models new_models models
  else
    models
