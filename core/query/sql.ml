open Utility
open CommonTypes

type index = (Var.var * string) list
type range = int * int

type query =
  | UnionAll  of query list * int
  | Select    of select_clause
  | Insert    of {
      ins_table: string;
      ins_fields: string list;
      ins_records: base list list
    }
  | Update    of {
      upd_table: string;
      upd_fields: (string * base) list;
      upd_where: base option
    }
  | Delete    of { del_table: string; del_where: base option }
  | With      of Var.var * query * Var.var * query
and select_clause = (base * string) list * (string * Var.var) list * base * base list
and base =
  | Case      of base * base * base
  | Constant  of Constant.t
  | Project   of Var.var * string
  | Apply     of string * base list
  | Empty     of query
  | Length    of query
  | RowNumber of (Var.var * string) list
    [@@deriving show]

(* optimizing smart constructor for && *)
let smart_and c c' =
  let open Constant in
  match c, c' with
  (* optimisations *)
  | Constant (Bool true), c
  | c, Constant (Bool true) -> c
  | Constant (Bool false), _
  | _, Constant (Bool false) ->
    Constant (Bool false)
  (* default case *)
  | c, c' -> Apply ("&&", [c; c'])

(* Table variables that are actually used are always bound in a for
   comprehension. In this case the IR variable from the for
   comprehension is used to generate the table variable.

   e.g. if the IR variable is 1485 then the table variable is t1485
*)
let fresh_table_var : unit -> Var.var = Var.fresh_raw_var
let string_of_table_var var = "t" ^ string_of_int var
let string_of_subquery_var var = "q" ^ string_of_int var

(* Because of limitations of SQL we sometimes need to generate dummy
   table variables. These have the prefix "dummy" and have their own
   name source. *)
let dummy_counter = ref 0
let reset_dummy_counter () = dummy_counter := 0
let fresh_dummy_var () =
  incr dummy_counter;
  "dummy" ^ string_of_int (!dummy_counter)

let string_of_label label =
  if Str.string_match (Str.regexp "[0-9]+") label 0 then
    "\"" ^ label ^ "\""     (* The SQL-standard way to quote an identifier;
                               works in MySQL and PostgreSQL *)
  else
    label

(* concatenation implement with Buffer module*)
let buffer_concat xs =
  let buf = Buffer.create 0 in (* maybe a better heuristic init size? *)
  List.iter (Buffer.add_string buf) xs;
  Buffer.contents buf

let rec buf_mapstrcat buf list f sep = 
  match list with
    | [] -> ()
    | [x] -> f x
    | x :: xs -> 
      f x; Buffer.add_string buf sep; buf_mapstrcat buf xs f sep

module Arithmetic :
sig
  val is : string -> bool
  val gen : (string * string * string) -> string
end =
struct
  let builtin_ops =
    StringMap.from_alist
      [ "+",   Some "+"  ;
        "+.",  Some "+"  ;
        "-",   Some "-"  ;
        "-.",  Some "-"  ;
        "*",   Some "*"  ;
        "*.",  Some "*"  ;
        "/",   None      ;
        "^",   None      ;
        "^.",  None      ;
        "/.",  Some "/"  ;
        "mod", Some "%"  ;
        (* FIXME: The SQL99 || operator is supported in PostgreSQL and
           SQLite but not in MySQL, where it denotes the logical or
           operator *)
        "^^",  Some "||" ]

  let is x = StringMap.mem x builtin_ops
  let sql_name op = val_of (StringMap.find op builtin_ops)
  let gen (l, op, r) =
    match op with
      | "/" -> "floor("^l^"/"^r^")"
      | "^" -> "floor(pow("^l^","^r^"))"
      | "^." -> "pow("^l^","^r^")"
      | _ -> "("^l^sql_name op^r^")"
end

module SqlFuns :
sig
  val is : string -> bool
  val name : string -> string
end =
struct
  let funs =
    StringMap.from_alist
      [ "toUpper",  "upper";
        "toLower",  "lower";
        "ord",      "ord";
        "chr",      "char";
        "random",   "rand" ]

  let is f = StringMap.mem f funs
  let name f = StringMap.find f funs
end

let order_by_clause n =
  if n == 0 then
    ""
  else
    let rec order i n =
      if i > n then
        []
      else
        ("order_" ^ string_of_int i) :: order (i+1) n
    in
      " order by " ^ String.concat "," (order 1 n)

(* For Empty and Length we don't care about the actual data
   returned. This allows these operators to take lists that have any
   element type at all. *)

let rec string_of_query buf quote ignore_fields q =
  let buf_add = Buffer.add_string buf in
  let sq = string_of_query buf quote ignore_fields in
  let sb = string_of_base buf quote false in
  let sbt = string_of_base buf quote true in
  let string_of_fields fields =
    if ignore_fields then
      buf_add "0 as \"@unit@\"" (* SQL doesn't support empty records! *)
    else
      match fields with
        | [] -> buf_add "0 as \"@unit@\"" (* SQL doesn't support empty records! *)
        | fields -> buf_mapstrcat buf fields 
                      (fun (b, l) -> 
                        buf_add "("; sb b; buf_add ") as "; buf_add (quote l)) (* string_of_label l) *)
                      "," 
  in
  let string_of_select fields tables condition os =
    let tables = String.concat "," tables in
    let fields = string_of_fields fields in
    let orderby =
      match os with
        | [] -> ()
        | _ ->  buf_add " order by "; buf_mapstrcat buf os (fun os -> sb os) "," in
    let where =
      match condition with
        | Constant (Constant.Bool true) -> ()
        | _ ->  buf_add " where "; (* sb condition*)
    in
       buf_add "select "; fields; buf_add " from "; buf_add tables; where; orderby
  in
  let string_of_delete table where =
      buf_add "delete from";
      buf_add table;
      OptionUtils.opt_app
        (fun x ->  buf_add "where ("; sbt x; buf_add ")") 
        () 
        where 
  in
  let string_of_update table fields where =
    buf_add "update ";
    buf_add table;
    buf_add " set ";
    buf_mapstrcat buf fields (fun (k, v) -> buf_add (quote k); buf_add " = "; sbt v) ",";
    buf_add " ";
    OptionUtils.opt_app
      (fun x -> buf_add "where ("; sbt x; buf_add ")") 
      () 
      where 
  in
  let string_of_insert table fields values = 
    buf_add "insert into ";
    buf_add table;
    buf_add " (";
    buf_mapstrcat buf fields (fun x -> buf_add x) ",";
    buf_add ") values ";
    buf_mapstrcat buf values 
      (fun list -> 
        buf_mapstrcat buf list (fun x -> buf_add "("; sbt x; buf_add ")") ",") 
      ",";
  in
    match q with
      | UnionAll ([], _) -> buf_add "select 42 as \"@unit@\" where false"
      | UnionAll ([q], n) -> sq q; buf_add (order_by_clause n)
      | UnionAll (qs, n) ->
        buf_mapstrcat buf qs (fun x -> buf_add "("; sq x; buf_add ")") " union all ";
        buf_add (order_by_clause n)
      | Select (fields, [], Constant (Constant.Bool true), _os) ->
          buf_add "select "; string_of_fields fields
      | Select (fields, [], condition, _os) ->
          buf_add "select * from (select ";
          string_of_fields fields;
          buf_add ") as ";
          buf_add (fresh_dummy_var ());
          buf_add " where ";
          sb condition;
      | Select (fields, tables, condition, os) ->
          (* using quote_field assumes tables contains table names (not nested queries) *)
          let tables = List.map (fun (t, x) -> buffer_concat [quote t; " as "; (string_of_table_var x)]) tables
          in string_of_select fields tables condition os
      | Delete { del_table; del_where } ->
          string_of_delete del_table del_where
      | Update { upd_table; upd_fields; upd_where } ->
          string_of_update upd_table upd_fields upd_where
      | Insert { ins_table; ins_fields; ins_records } ->
          string_of_insert ins_table ins_fields ins_records
      | With (_, q, z, q') ->
          match q' with
          | Select (fields, tables, condition, os) ->
              (* Inline the query *)
              let tables = List.map (fun (t, x) -> buffer_concat [quote t; " as "; (string_of_table_var x)]) tables in
              let buf2 = Buffer.create 0 in
              let q2 = string_of_query buf2 quote ignore_fields q; Buffer.contents buf2 in 
              let q = buffer_concat ["("; q2; ") as "; string_of_table_var z] in
              string_of_select fields (q::tables) condition os
          | _ -> assert false

and string_of_base buf quote one_table b =
  let string_of_projection quote one_table (var, label) =
  if one_table then
    quote label
  else
    buffer_concat [string_of_table_var var; "."; (quote label)]
  in
  let buf_add = Buffer.add_string buf in
  let sb = string_of_base buf quote one_table in
    match b with
      | Case (c, t, e) ->
          buf_add "case when "; sb c; buf_add " then "; sb t; buf_add " else "; sb e; buf_add " end"
      | Constant c -> buf_add (Constant.to_string c)
      | Project (var, label) -> buf_add (string_of_projection quote one_table (var, label))
      | Apply (op, [l; r]) when Arithmetic.is op -> 
        let buf2 = Buffer.create 0 in
        let buf3 = Buffer.create 0 in
        let l2 = string_of_base buf2 quote one_table l; Buffer.contents buf2 in
        let r2 = string_of_base buf3 quote one_table r; Buffer.contents buf3 in
        buf_add (Arithmetic.gen (l2, op, r2))
      | Apply (("intToString" | "stringToInt" | "intToFloat" | "floatToString"
                | "stringToFloat"), [v]) -> sb v
      | Apply ("floatToInt", [v]) -> buf_add "floor("; sb v; buf_add ")"

      (* optimisation *)
      | Apply ("not", [Empty q]) -> buf_add "exists ("; string_of_query buf quote true q; buf_add ")"
      | Apply ("not", [v]) -> buf_add "not ("; sb v; buf_add ")"
      | Apply (("negate" | "negatef"), [v]) -> buf_add "-("; sb v; buf_add ")"
      | Apply ("&&", [v; w]) -> buf_add "("; sb v; buf_add ")"; buf_add " and "; buf_add "("; sb w; buf_add ")"
      | Apply ("||", [v; w]) -> buf_add "("; sb v; buf_add ")"; buf_add " or "; buf_add "("; sb w; buf_add ")"
      | Apply ("==", [v; w]) -> buf_add "("; sb v; buf_add ")"; buf_add " = "; buf_add "("; sb w; buf_add ")"
      | Apply ("<>", [v; w]) -> buf_add "("; sb v; buf_add ")"; buf_add " <> "; buf_add "("; sb w; buf_add ")"
      | Apply ("<", [v; w]) -> buf_add "("; sb v; buf_add ")"; buf_add " < "; buf_add "("; sb w; buf_add ")"
      | Apply (">", [v; w]) -> buf_add "("; sb v; buf_add ")"; buf_add " > "; buf_add "("; sb w; buf_add ")"
      | Apply ("<=", [v; w]) -> buf_add "("; sb v; buf_add ")"; buf_add " <= "; buf_add "("; sb w; buf_add ")"
      | Apply (">=", [v; w]) -> buf_add "("; sb v; buf_add ")"; buf_add " >= "; buf_add "("; sb w; buf_add ")"
      | Apply ("RLIKE", [v; w]) -> buf_add "("; sb v; buf_add ")"; buf_add " RLIKE "; buf_add "("; sb w; buf_add ")"
      | Apply ("LIKE", [v; w]) -> buf_add "("; sb v; buf_add ")"; buf_add " LIKE "; buf_add "("; sb w; buf_add ")"
      | Apply (f, args) when SqlFuns.is f -> buf_add (SqlFuns.name f); buf_add "("; buf_mapstrcat buf args (fun x -> sb x) ","; buf_add ")"
      | Apply (f, args) -> buf_add f; buf_add "("; buf_mapstrcat buf args (fun x -> sb x) ","; buf_add ")"
      | Empty q -> buf_add "not exists ("; string_of_query buf quote true q; buf_add ")"
      | Length q -> buf_add "select count(*) from ("; string_of_query buf quote true q; buf_add ") as "; buf_add (fresh_dummy_var ())
      | RowNumber [] -> buf_add "1"
      | RowNumber ps ->
        buf_add "row_number() over (order by "; buf_add (String.concat "," (List.map (string_of_projection quote one_table) ps)); buf_add ")"

(* let string_of_insert table fields values =
  let buf = Buffer.create 0 in
  let buf_add = Buffer.add_string buf in
  string_of_insert buf table fields values;
  Buffer.contents buf *)

let string_of_base quote one_table b = 
  let buf = Buffer.create 0 in
  string_of_base buf quote one_table b; Buffer.contents buf


let string_of_query ?(range=None) quote q =
  let buf = Buffer.create 0 in
  let buf_add = Buffer.add_string buf in
  let range =
    match range with
      | None -> ""
      | Some (limit, offset) -> buffer_concat [" limit "; string_of_int limit; " offset "; string_of_int offset]
  in
    string_of_query buf quote false q; buf_add range; Buffer.contents buf
