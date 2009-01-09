open Str
open Num
open List

open Utility
open Result
open Syntax

open Unix


exception RuntimeUndefVar of string

let lookup globals locals name = 
  try 
    (match Utility.lookup name locals with
      | Some v -> v
      | None -> match Utility.lookup name globals with
          | Some v -> v
          | None -> Library.primitive_stub name)
  with NotFound _ -> 
    raise (RuntimeUndefVar name)

(** [bind_rec env defs] extends [env] with bindings for the [defs],
    where each one defines a function and all the functions are
    mutually recursive. *)
let bind_rec locals defs =
  let new_defs = map (fun (name, _) -> 
                        (name, `RecFunction(defs, locals, name))) defs in
    trim_env (new_defs @ locals)

(** Given a label and a record, returns the value of that field in the record,
    together with the remaining fields of the record. *)
let rec crack_row : (string -> ((string * result) list) -> (result * (string * result) list)) = fun ref_label -> function
        | [] -> raise (Runtime_error("Internal error: no field '" ^ ref_label ^ "' in record"))
        | (label, result) :: fields when label = ref_label ->
            (result, fields)
        | field :: fields ->
            let selected, remaining = crack_row ref_label fields in
              (selected, field :: remaining)

(** Given a Links tuple, returns an Ocaml list of the Links values in that
    tuple. *)
let untuple : result -> result list = 
  let rec aux n output = function
    | [] -> List.rev output
    | fields ->
        match partition (fst ->- (=)(string_of_int n)) fields with
          | [_,r], rest -> aux (n+1) (r::output) rest
          | _ -> assert false
  in function
    | `Record fields -> aux 1 [] fields
    | _ -> assert false
        

(** Substitutes values for the variables in a query,
    and performs interpolation in LIKE expressions. *)
let rec normalise_query (globals:environment) (env:environment) (db:database) 
    (qry:SqlQuery.sqlQuery) : SqlQuery.sqlQuery =

  let normalise_like_expression (l : SqlQuery.like_expr): SqlQuery.like_expr = 
    let quote = Str.global_replace (Str.regexp_string "%") "\\%" in
    let env = env @ globals in
    let rec nle =
      function
        | `Var x -> `Str (quote (Result.unbox_string (List.assoc x env)))
        | (`Percent | `Str _) as l -> l
        | `Seq ls -> `Seq (List.map nle ls)
    in
      nle l
  in
  let rec normalise_expression : SqlQuery.sqlexpr -> SqlQuery.sqlexpr = function
    | `V name -> begin
        try
          match lookup globals env name with
            | `Bool true -> `True
            | `Bool false -> `False
            | `Int value -> `N value
            | `List (`Char _::_) as c  
              -> `Str (db # escape_string (charlist_as_string c))
            | `List ([]) -> `Str ""
            | `Char c -> `Str (String.make 1 c)
            | r -> failwith("Internal error: variable " ^ name ^ 
                              " in query "^ SqlQuery.string_of_query qry ^ 
                              " had unexpected type at runtime: " ^ 
                              string_of_result r)
        with NotFound _ -> failwith ("Internal error: undefined query variable '"^
                                       name^"'")
      end
    | `Op (symbol, left, right) ->
        `Op(symbol, normalise_expression left, normalise_expression right)
    | `Not expr ->
        `Not(normalise_expression expr)
    | `Like(lhs, regex) -> 
        `Like(normalise_expression lhs,
              normalise_like_expression regex)
    | expr -> expr
  in
  let normalise_tables =
    map (function 
           | `TableVar(var, alias) ->
               (match lookup globals env var with
                    `Table(_, tableName, _) -> `TableName(tableName, alias)
                  | _ -> failwith "Internal Error: table source was not a table!")
           | `TableName (name, alias) -> `TableName(name, alias)
           | `SubQuery _ ->
               failwith "Not implemented subqueries yet"
        ) 
  in {qry with
        SqlQuery.tabs = normalise_tables qry.SqlQuery.tabs;
        SqlQuery.cond = map normalise_expression qry.SqlQuery.cond;
        (* TBD: allow variables as the from/most values, normalise them here. *)
        SqlQuery.from = qry.SqlQuery.from;
        SqlQuery.most = qry.SqlQuery.most}

(** [row_field_type field row]: what type has [field] in [row]? 
    TBD: Factor this out.
*)

exception NoSuchField of string

let row_field_type field : Types.row -> Types.datatype = 
  fun (fields, _) ->
    match StringMap.find field fields with
      | `Present t -> t
      | `Absent -> raise (NoSuchField field)

let query_result_types (query : SqlQuery.sqlQuery)
    : (string * Types.datatype) list =
  try 
    concat_map
      (function
           (`F field, alias) -> 
             [alias, field.SqlQuery.ty]
         | (expr, _alias) -> failwith("Internal error: no type info for sql expression " 
                                      ^ SqlQuery.string_of_expression expr))
      query.SqlQuery.cols
  with NoSuchField field ->
    failwith ("Field " ^ field ^ " from " ^ 
                SqlQuery.string_of_query query)

let do_query globals locals (query : SqlQuery.sqlQuery) = 
  let get_database : SqlQuery.sqlQuery -> database = fun query ->
    let vars = concat_map (function
                            | `TableVar (var, _) -> [var]
                            | _ -> []) query.SqlQuery.tabs in
    let dbs = 
      map (fun var -> 
             match lookup globals locals var with
               | `Table((db, params), _table_name, _row) -> db
               | _ -> assert false) vars in
      
      assert (dbs <> []);
      
      if(not (all_equiv (=) dbs)) then
        failwith ("Cannot join across different databases");
      
      hd(dbs) in

  let db = get_database query in
      (* TBD: factor this stuff out into a module that processes
         queries *)
  let result_types = query_result_types query in
  let query_string = SqlQuery.string_of_query (normalise_query globals locals db query) in
    
    prerr_endline("RUNNING QUERY:\n" ^ query_string);
    let t = Unix.gettimeofday() in
    let result = Olddatabase.execute_select result_types query_string db in
      Debug.print("Query took : " ^ 
                    string_of_float((Unix.gettimeofday() -. t)) ^ "s");
      result

(** 0 Web-related stuff *)
let has_client_context = ref false

let serialize_call_to_client (continuation, name, arg) = 
  Oldjson.jsonize_call continuation name arg

let program_source = ref(Program([], Syntax.unit_expression no_expr_data))

let client_call_impl globals name cont (args:Result.result list) =
  let callPkg = Utility.base64encode(serialize_call_to_client(cont, name, args)) 
  in
    if (not !has_client_context) then 
      begin
        let start_script = "LINKS.invokeClientCall(_start, JSON.parseB64Safe(\"" ^ callPkg ^ "\"))" in
        let Program (defs, _) = !program_source in
          Library.print_http_response ["Content-type", "text/html"]
            (Oldirtojs.make_boiler_page ~onload:start_script
               (Oldirtojs.generate_program_defs globals defs (StringSet.singleton name)))
          ; exit 0
      end
    else begin
      Library.print_http_response ["Content-type", "text/plain"] callPkg;
      exit 0
    end

exception TopLevel of (Result.environment * Result.result)

(** {0 Scheduling} *)

(* could bundle these together with [globals] to get a global
   'interpreter state' that we'd then thread through the whole
   interpreter, making it re-entrant. *)
let process_steps = ref 0
let switch_granularity = 5

let rec switch_context globals = 
  if not (Queue.is_empty Library.suspended_processes) then 
    let (cont, value), pid = Queue.pop Library.suspended_processes in
      Library.current_pid := pid;
      apply_cont globals cont value
  else exit 0

and scheduler globals state stepf = 
  incr process_steps;
  if (!process_steps mod switch_granularity == 0) then 
    begin
      process_steps := 0;
      Queue.push (state, !Library.current_pid) Library.suspended_processes;
      switch_context globals
    end
  else
    stepf()

(** Apply a continuation to a result; half of the evaluator. *)
and apply_cont (globals : environment) : continuation -> result -> result = 
  fun cont value ->
    let stepf() = 
      match cont with
        | [] -> (if !Library.current_pid == Library.main_process_pid then
                   raise (TopLevel(globals, value))
	         else switch_context globals)
        | (frame::cont) -> match frame with
	    | (Definition(env, name)) -> 
	        apply_cont (Result.bind env name value) cont value
            | Recv  ->
                (* If there are any messages, take the first one and
                   apply the continuation to it.  Otherwise, suspend
                   the continuation (in the blocked_processes table)
                   and let the scheduler choose a different thread.
                *)
                let mqueue = Hashtbl.find Library.messages !Library.current_pid in
                  if not (Queue.is_empty mqueue) then
                    apply_cont globals cont (Queue.pop mqueue)
                  else 
                    begin
                      Hashtbl.add Library.blocked_processes
                        !Library.current_pid
                        ((Recv::cont, value), !Library.current_pid);
                      switch_context globals
                    end
            | FuncEvalCont(_, []) -> 
                apply_cont globals (ApplyCont([], [])::cont) value
            | FuncEvalCont(locals, param::params) ->
	        (* Just evaluate the first parameter; "value" is a
	           function value which will later be applied *)
                interpret globals locals param
                  (ArgEvalCont(locals, value, params, [])::cont)
            | ApplyCont(locals, args_rev) ->
                let args = List.rev args_rev in
                  begin match value with
                    | `RecFunction (defs, fnlocals, name) ->
                        let Syntax.Abstr (vars, body, _data) = 
                          List.assoc name defs in
                        let recPeers = (* recursively-defined peers *)
                          map (fun (name, Syntax.Abstr _) -> 
                                 (name, `RecFunction (defs, fnlocals, name))) 
                            defs
                        in let locals = recPeers @ fnlocals @ locals in
                        let locals = fold_left2 Result.bind locals vars args in
                        let locals = trim_env locals in
                          interpret globals locals body cont

                  | `PrimitiveFunction name ->
                      apply_cont globals cont (Library.apply_pfun name args)

                  | `ClientFunction name ->
                      client_call_impl (map fst globals) name cont args

	          | `Continuation cont ->
                      assert (length args == 1);
                      apply_cont globals cont (List.hd args)

                  | _ -> raise (Runtime_error("Applied non-function value: " ^
                                                string_of_result value))
                end
            | ArgEvalCont(locals, func, unevaluated_args, evaluated_args) ->  
                let evaluated_args = value :: evaluated_args in
                  begin match unevaluated_args with
                      [] ->
                        apply_cont globals 
                          (ApplyCont(locals, evaluated_args) :: cont) func
                    | next_expr :: exprs ->
                        interpret globals locals next_expr 
                          (ArgEvalCont(locals, func, exprs, evaluated_args)::cont)
                  end
            | LetCont(locals, variable, body) ->
	        interpret globals (Result.bind locals variable value) body cont
            | BranchCont(locals, true_branch, false_branch) ->
	        (match value with
                   | `Bool true  -> 
	               interpret globals locals true_branch cont
                   | `Bool false -> 
	               interpret globals locals false_branch cont
                   | _ -> raise (Runtime_error("Attempt to test a non-boolean value: "
					       ^ string_of_result value)))
            | BinopRight(locals, op, rhsExpr) ->
	        interpret globals locals rhsExpr
                  (BinopApply([], op, value) :: cont)
                  (* FIXME: locals aren't needed here *)
            | BinopApply(_, op, lhsVal) ->
	        let result = 
                  begin match op with
                    | `Equal -> bool (Library.equal lhsVal value)
                    | `NotEq -> bool (not (Library.equal lhsVal value))
                    | `LessEq -> bool (Library.less_or_equal lhsVal value)
                    | `Less -> bool (Library.less lhsVal value)
	            | `Union -> 
                        begin match lhsVal, value with
	                  | `List (l), `List (r) -> `List (l @ r)
	                  | _ -> raise(Runtime_error
                                         ("Type error: Concatenation of non-list values: "
					  ^ string_of_result lhsVal ^ " and "
					  ^ string_of_result value))
                        end
	            | `RecExt label -> 
		        begin match lhsVal with
		          | `Record fields -> 
		              `Record ((label, value) :: fields)
		          | _ -> assert false
                        end
	             | `MkTableHandle row ->
			 begin match lhsVal with
			   | `Database (db, params) ->
			       apply_cont globals cont 
                                 (`Table((db, params), charlist_as_string value, row))
			   | _ -> failwith("Runtime type error: argument to table was not a database.")
                         end
                  end
	        in
	          apply_cont globals cont result
            | UnopApply (locals, op) ->
                begin
                  match op with
                     MkColl -> apply_cont globals cont (`List [(value)])
	           | MkVariant(label) -> 
	               apply_cont globals cont (`Variant (label, value))
                   | VrntSelect(case_label, case_variable, case_body, variable, body) ->
	               (match value with
                          | `Variant (label, value) when label = case_label ->
                              (interpret globals (Result.bind locals case_variable value) case_body cont)
                          | `Variant (_) as value ->
		              (interpret globals (Result.bind locals (val_of variable) value)
		                 (val_of body) cont)
                          | _ -> raise (Runtime_error "TF181"))
	           | MkDatabase ->
                       let result = (let driver = charlist_as_string (links_project "driver" value)
				     and name = charlist_as_string (links_project "name" value)
				     and args = charlist_as_string (links_project "args" value) in
				     let params =
				       (if args = "" then name
					else name ^ ":" ^ args)
				     in
                                       `Database (db_connect driver params)) in
	               apply_cont globals cont result
                   | Result.Erase label ->
                       apply_cont globals cont (`Record (snd (crack_row label (recfields value))))
                   | Result.Project label ->
                       apply_cont globals cont (fst (crack_row label (recfields value)))
	        end
            | RecSelect (locals, label, label_var, variable, body) ->
	        let field, remaining = crack_row label (recfields value) in
                let new_env = trim_env (Result.bind (Result.bind locals variable
					        (`Record remaining))
				          label_var field) in
                  interpret globals new_env body cont
                    
            | StartCollExtn (locals, variable, expr) -> 
	        (match value with
                   | `List (source_elems) ->
	               (match source_elems with
		            [] -> apply_cont globals cont (`List [])
	                  | (first_elem::other_elems) ->
	                      (* bind 'var' to the first element, save the others for later *)
		              interpret globals (Result.bind locals variable first_elem) expr
		                (CollExtn(locals, variable, expr, [], other_elems) :: cont))
	           | _ -> assert false)
	          
            | CollExtn (locals, var, expr, rslts, inputs) ->
                (let new_results = match value with
                     (* Check that value is a collection, and extract its
                        contents: *)
                   | `List (expr_elems) -> expr_elems
                   | _ -> assert false
	         in
	           (* Extend rslts with the newest list of results. *)
                 let rslts = (List.rev new_results) :: rslts in
	           match inputs with
		       [] -> (* no more inputs, collect results & continue *)
		         apply_cont globals cont (`List (List.rev (List.concat rslts)))
		     | (next_input::inputs) ->
		         (* Eval next input, continue with given results: *)
		         interpret globals (Result.bind locals var next_input) expr
		           (CollExtn(locals, var, expr, rslts, inputs) :: cont)
	        )
                  
            | XMLCont (locals, tag, attrtag, children, attrs, elems) ->
                (let new_children = 
                   match attrtag, value with 
                       (* FIXME: multiple attrs resulting from one expr? *)
                     | Some attrtag, (`List (_) as s) -> 
                         [Attr (attrtag, charlist_as_string s)]
                     | None, (`List (elems)) ->
                         (match elems with
                            | [] -> []
                            | `XML _ :: _ ->
                                map xmlitem_of elems
                            | `Char _ :: _ ->
                                [ Result.Text(charlist_as_string value) ]
                            | _ -> failwith("Internal error: unexpected contents in XML construction"))
                     | _ -> failwith("Internal error: unexpected contents in XML construction")
                 in
                 let children = children @ new_children in
                   match attrs, elems with
                     | [], [] -> 
                         let result = listval [xmlnodeval(tag, children)] in
                           apply_cont globals cont result
                     | ((k,v)::attrs), _ -> 
                         interpret globals locals v
                           (XMLCont (locals, tag, Some k, children, attrs, elems) :: cont)
                     | _, (elem::elems) -> 
                         interpret globals locals elem
                           (XMLCont (locals, tag, None, children, attrs, elems) :: cont)
                )
              (* EvalDef ignores the incoming value and evaluates 
                 the contained definition *)
            | EvalDef (locals, def) ->
	        interpret_definition globals locals def cont
            | Ignore (locals, expr) ->
	        interpret globals locals expr cont
    in
      scheduler globals (cont, value) stepf

and interpret_definition : 
    environment -> environment -> definition -> continuation -> result =
  fun globals locals def cont ->
    match def with
      | Syntax.Module (_, Some defs, _) -> 
          let def_conts = map (fun def -> EvalDef(locals, def)) defs in
            apply_cont globals (def_conts @ cont) (`Record [])

      | Syntax.Module (_, None, _) -> assert false 
              (* defs should've been inserted by loader *)

      | Syntax.Define (name, expr, (`Server|`Unknown), _) -> 
          interpret globals [] expr (Definition (globals, name) :: cont)

      | Syntax.Define (name, _, (`Client), _) -> 
          apply_cont globals (Definition (globals, name) :: cont)
            (`ClientFunction name)

      | Syntax.Alien _ ->
          apply_cont globals cont (`Record [])

and interpret : environment -> environment -> expression -> continuation -> result =
fun globals locals expr cont ->
(*  Debug.print ("expr: "^string_of_expression expr); *)
  let eval = interpret globals locals in
  let box_constant = function
    | `Bool b -> bool b
    | `Int i -> int i
    | `String s -> string_as_charlist s
    | `Float f -> float f
    | `Char ch -> char ch in
  match expr with
  | Syntax.Constant (c, _) -> apply_cont globals cont (box_constant c)
  | Syntax.Variable(name, _) -> 
      let value = (lookup globals locals name) in
	apply_cont globals cont value
  | Syntax.Abstr (variable, body, _) as f ->
      let value = `RecFunction([("_anon", f)],
                               retain (freevars body) locals,
                               "_anon") in
        apply_cont globals cont value
  | Syntax.Apply (Variable ("recv", _), [], _) ->
      apply_cont globals (Recv::cont) (`Record [])
  | Syntax.Apply (fn, params, _) ->
      let locals = retain (freevars_all params) locals in
        eval fn (FuncEvalCont (locals, params)::cont)
  | Syntax.Condition (condition, if_true, if_false, _) ->
      let locals = retain (StringSet.union
                             (freevars if_true)
                             (freevars if_false)) locals in
        eval condition (BranchCont(locals, if_true, if_false) :: cont)
  | Syntax.Comparison (l, oper, r, _) ->
      let locals = retain (freevars r) locals in
      eval l (BinopRight(locals, (oper :> Result.binop), r) :: cont)
  | Syntax.Let (variable, value, body, _) ->
      let locals = retain (freevars body) locals in
      eval value (LetCont(locals, variable, body) :: cont)
  | Syntax.Rec (defs, body, _) ->
      let defs' = List.map (fun (n, v, _type) -> (n, v)) defs in
      let new_env = bind_rec locals defs' in
        interpret globals new_env body cont
  | Syntax.Xml_node (tag, [], [], _) -> 
      apply_cont globals cont (listval [xmlnodeval (tag, [])])
  | Syntax.Xml_node (tag, (k, v)::attrs, elems, _) -> 
      let locals = retain (freevars_all elems <|StringSet.union|>
                               freevars_all (map snd attrs)
                          ) locals in
      eval v (XMLCont (locals, tag, Some k, [], attrs, elems) :: cont)
  | Syntax.Xml_node (tag, [], (child::children), _) -> 
      let locals = retain (freevars_all children) locals in
      eval child (XMLCont (locals, tag, None, [], [], children) :: cont)

  | Syntax.Record_intro (fields, None, _) ->
      apply_cont
        globals
        (StringMap.fold (fun label value cont ->
                           BinopRight(locals, `RecExt label, value) :: cont) fields cont)
        (`Record [])
  | Syntax.Record_intro (fields, Some record, _) ->
      eval record (StringMap.fold (fun label value cont ->
                                     BinopRight(locals, `RecExt label, value) :: cont) fields cont)
  | Syntax.Project (expr, label, _) ->
      eval expr (UnopApply ([], Result.Project label) :: cont)
  | Syntax.Erase (expr, label, _) ->
      eval expr (UnopApply ([], Result.Erase label) :: cont)
  | Syntax.Variant_injection (label, value, _) ->
       eval value (UnopApply([], MkVariant label) :: cont)
  | Syntax.Variant_selection (value, case_label, case_variable, case_body, variable, body, _) ->
      eval value (UnopApply(locals, VrntSelect(case_label, case_variable, case_body, Some variable, Some body)) :: cont)
  | Syntax.Variant_selection_empty (_) ->
      failwith("internal error: attempt to evaluate empty closed case expression")
  | Syntax.Nil _ ->
      apply_cont globals cont (`List [])
  | Syntax.List_of (elem, _) ->
      eval elem (UnopApply([], MkColl) :: cont)
  | Syntax.Concat (l, r, _) ->
      let locals = retain (freevars r) locals in
      eval l (BinopRight(locals, `Union, r) :: cont)

  | Syntax.For (body, var, src, _) ->
      let locals = retain (freevars body) locals in
      eval src (StartCollExtn(locals, var, body) :: cont)
  | Syntax.Database (params, _) ->
      eval params (UnopApply([], MkDatabase) :: cont)
  | Syntax.TableHandle (database, table_name, (readtype, writetype), _) ->
      begin
        match readtype with
          | `Record row ->
              let locals = retain (freevars table_name) locals in
              eval database (BinopRight(locals, `MkTableHandle row, table_name)
                             :: cont)
          | _ ->
              failwith ("table rows must have record type")
      end

  | Syntax.TableQuery (query, _) ->
      apply_cont globals cont (do_query globals locals query)

  | Syntax.Call_cc(arg, _) ->
      let locals = [] in
      let cc = `Continuation cont in
        eval arg (ApplyCont(locals, [cc]) :: cont)
  | Syntax.SortBy (list, byExpr, d) ->
      eval (Apply (Variable ("sortBy", d), [byExpr; list], d)) cont
  | Syntax.Wrong (_) ->
      failwith("Went wrong (pattern matching failed?)")
  | Syntax.HasType(expr, _, _) ->
      eval expr cont

let run_program (globals : environment) locals (Program (defs, body))
    : (environment * result) = 
  try (
    ignore 
      (apply_cont globals 
         (map (fun def -> EvalDef([], def)) defs @ [Ignore(locals, body)])
         (`Record []));
    failwith "boom"
  ) with
    | TopLevel s -> s
    | NotFound s -> failwith ("Internal error: NotFound "^s^" while interpreting.")

let run_expr (globals: environment) locals expr cont : (environment * result) =
  try (
    ignore (interpret globals locals expr cont);
    failwith "boom"
  ) with
    | TopLevel s -> s
    | NotFound s -> failwith ("Internal error: NotFound "^s^" while interpreting.")

let run_defs (globals : environment) locals defs : environment =
  let env, _ =
    run_program globals locals
      (Program (defs, (Syntax.unit_expression (Syntax.no_expr_data))))
  in
    env

let apply_cont_safe x y z = 
  try apply_cont x y z
  with
    | TopLevel s -> snd s
    | NotFound s -> failwith ("Internal error: NotFound "^s^" while interpreting.")