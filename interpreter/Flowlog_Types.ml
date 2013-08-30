open Printf
open ExtList.List

  type term = 
              | TConst of string 
              | TVar of string 
              | TField of string * string;;  

  type formula = 
              | FTrue 
              | FFalse 
              | FEquals of term * term
              | FNot of formula 
                (* module, relname, args*)
              | FAtom of string * string * term list 
              | FAnd of formula * formula 
              | FOr of formula * formula;;

  type action = 
              | ADelete of string * term list * formula 
              | AInsert of string * term list * formula 
              | ADo of string * term list * formula;;

  type refresh = 
      (* number, units *)
      | RefreshTimeout of int * string
      | RefreshPure
      | RefreshEvery;;

  type assignment = 
      | Assign of string * string;;

  type spec_out = 
      | ReactSend of string * assignment list * string * string;;
  type spec_in =
      | ReactInsert of string;;

  type sreactive = 
        (* table name, query name, ip, port, refresh settings *)
      | ReactRemote of string * string * string * string * refresh
        (* out relation name, args, event type name, assignments, ip, port*)
      | ReactOut of string * string list * string * assignment list * string * string 
        (* incoming event type, trigger relation name*)
      | ReactInc of string * string;;

  type sdecl = 
      | DeclTable of string * string list    
      | DeclRemoteTable of string * string list    
      | DeclInc of string * string   
      | DeclOut of string * string list    
      | DeclEvent of string * string list;;

  type srule = 
      | Rule of string * string * action;;

  type stmt = 
      | SReactive of sreactive 
      | SDecl of sdecl 
      | SRule of srule;;

  type flowlog_ast = 
      | AST of string list * stmt list;;

(*************************************************************)  

  (* Split out a formula by ORs for use with XSB *)
  (* In new semantics, no longer have "on" in clause body. It just gets made an EDB fact. *)
  (* REQUIRE: head, body fmlas atomic or equality *)
  type clause = { orig_rule: srule; 
                  head: formula;
                  body: formula; (* should be always conjunctive *)
                  };;

  type flowlog_program = {  decls: sdecl list; 
                            reacts: sreactive list; 
                            clauses: clause list; };;
(*************************************************************)

  let string_of_term ?(verbose:bool = false) (t: term): string = 
    match t with
      | TConst(s) -> 
        if verbose then "TConst("^s^")" 
        else s
      | TVar(s) ->
        if verbose then "TVar("^s^")"
        else s
      | TField(varname, fname) -> 
        if verbose then "TField("^varname^"."^fname^")" 
        else varname^"__"^fname;;

  let rec string_of_formula ?(verbose:bool = false) (f: formula): string = 
    match f with
      | FTrue -> "true"
      | FFalse -> "false"
      | FEquals(t1, t2) -> (string_of_term ~verbose:verbose t1) ^ " = "^ (string_of_term ~verbose:verbose t2)
      | FNot(f) ->  "(not "^(string_of_formula ~verbose:verbose f)^")"
      | FAtom("", relname, tlargs) -> 
          relname^"("^(String.concat "," (List.map (string_of_term ~verbose:verbose) tlargs))^")"
      | FAtom(modname, relname, tlargs) -> 
          modname^"/"^relname^"("^(String.concat "," (List.map (string_of_term ~verbose:verbose) tlargs))^")"
      | FAnd(f1, f2) -> (string_of_formula ~verbose:verbose f1) ^ ", "^ (string_of_formula ~verbose:verbose f2)
      | FOr(f1, f2) -> (string_of_formula ~verbose:verbose f1) ^ " or "^ (string_of_formula ~verbose:verbose f2)
  
  let action_string outrel argterms fmla: string = 
    let argstring = (String.concat "," (List.map string_of_term argterms)) in
      outrel^"("^argstring^") WHERE "^(string_of_formula fmla);;

  let string_of_rule (r: srule): string =
    match r with 
      | Rule(trigrel, trigvar, act) -> 
        match act with 
          | ADelete(outrel, argterms, fmla) ->  
            "ON "^trigrel^"("^trigvar^"): DELETE "^(action_string outrel argterms fmla);                         
          | AInsert(outrel, argterms, fmla) ->
            "ON "^trigrel^"("^trigvar^"): INSERT "^(action_string outrel argterms fmla);
          | ADo(outrel, argterms, fmla) ->  
            "ON "^trigrel^"("^trigvar^"): DO "^(action_string outrel argterms fmla);;

  let string_of_declaration (d: sdecl): string =
    match d with 
      | DeclTable(tname, argtypes) -> "TABLE "^tname^(String.concat "," argtypes);
      | DeclRemoteTable(tname, argtypes) -> "REMOTE TABLE "^tname^" "^(String.concat "," argtypes);
      | DeclInc(tname, argtype) -> "INCOMING "^tname^" "^argtype;
      | DeclOut(tname, argtypes) -> "OUTGOING "^tname^(String.concat "," argtypes);
      | DeclEvent(evname, argnames) -> "EVENT "^evname^" "^(String.concat "," argnames);;

  let string_of_reactive (r: sreactive): string =
    match r with       
      | ReactRemote(tblname, qname, ip, port, refresh) ->
        tblname^" (remote) = "^qname^" @ "^ip^" "^port;
      | ReactOut(outrel, args, evtype, assignments, ip, port) ->
        outrel^"("^(String.concat "," args)^") (output rel) = "^evtype^" @ "^ip^" "^port;
      | ReactInc(evtype, relname) -> 
        relname^" (input rel) "^evtype;;
  
  let string_of_stmt (stmt: stmt): string = 
    match stmt with 
      | SReactive(rstmt) -> (string_of_reactive rstmt);
      | SDecl(dstmt) -> (string_of_declaration dstmt);
      | SRule(rstmt) -> (string_of_rule rstmt);;

  let pretty_print_program (ast: flowlog_ast): unit =
    match ast with
      | AST(imports, stmts) ->
        List.iter (fun imp -> printf "IMPORT %s;\n%!" imp) imports;
        List.iter (fun stmt -> printf "%s\n%!" (string_of_stmt stmt)) stmts;;

  let string_of_clause (cl: clause): string =
    "CLAUSE: "^(string_of_formula cl.head)^" :- "^(string_of_formula cl.body)^"\n"^
    "FROM RULE: "^(string_of_rule cl.orig_rule);;

(*************************************************************)

let product_of_lists lst1 lst2 = 
  List.concat (List.map (fun e1 -> List.map (fun e2 -> (e1,e2)) lst2) lst1);;

(* all disjunctions need to be pulled to top already *)
let rec extract_disj_list (f: formula): formula list =    
    match f with 
        | FOr(f1, f2) -> (extract_disj_list f1) @ (extract_disj_list f2);
        | _ -> [f];;

let rec nnf (f: formula): formula =
  match f with 
        | FTrue -> f
        | FFalse -> f
        | FEquals(t1, t2) -> f
        | FAtom(modstr, relstr, argterms) -> f
        | FOr(f1, f2) -> FOr(nnf f1, nnf f2)
        | FAnd(f1, f2) -> FAnd(nnf f1, nnf f2)
        | FNot(f2) -> 
          match f2 with
            | FTrue -> FFalse
            | FFalse -> FTrue
            | FEquals(t1, t2) -> f
            | FAtom(modstr, relstr, argterms) -> f            
            | FNot(f3) -> f3            
            | FOr(f1, f2) -> FAnd(nnf (FNot f1), nnf (FNot f2))
            | FAnd(f1, f2) -> FOr(nnf (FNot f1), nnf (FNot f2));;
            
(* Assume: NNF before calling this *)
let rec disj_to_top (f: formula): formula = 
    match f with 
        | FTrue -> f;
        | FFalse -> f;
        | FEquals(t1, t2) -> f;
        | FAtom(modstr, relstr, argterms) -> f;
        | FOr(f1, f2) -> f;
        | FNot(f2) -> f; (* since guaranteed to be in NNF *)            
        | FAnd(f1, f2) -> 
            (* Distributive law if necessary *)
            let f1ds = extract_disj_list (disj_to_top f1) in
            let f2ds = extract_disj_list (disj_to_top f2) in

            (*printf "f: %s\n%!" (string_of_formula f);
            printf "f1ds: %s\n%!" (String.concat "; " (map string_of_formula f1ds));
            printf "f2ds: %s\n%!" (String.concat "; " (map string_of_formula f2ds));*)

            let pairs = product_of_lists f1ds f2ds in
                (* again, start with first pair, not FFalse *)
                let (firstfmla1, firstfmla2) = (hd pairs) in
               (*printf "PAIRS: %s\n%!" (String.concat "," (map (fun (f1, f2) -> (string_of_formula f1)^" "^(string_of_formula f2)) pairs));*)
                fold_left (fun acc (subf1, subf2) ->  (*(printf "%s %s: %s\n%!" (string_of_formula subf1) (string_of_formula subf2)) (string_of_formula  (FOr(acc, FAnd(subf1, subf2))));*)
                                                      FOr(acc, FAnd(subf1, subf2))) 
                          (FAnd(firstfmla1, firstfmla2)) 
                          (tl pairs);;

(* For every non-negated equality that has one TVar in it, produces a tuple for substitution *)    
let rec gather_nonneg_equalities_involving_vars (f: formula) (neg: bool): (term * term) list =
  match f with 
        | FTrue -> []
        | FFalse -> []
        | FEquals((TVar(_) as thevar), t)                 
        | FEquals(t, (TVar(_) as thevar)) 
          when (not neg) && (not (thevar = t)) -> 
            [(thevar, t)]
        | FEquals(_, _) -> []
        | FAtom(modstr, relstr, argterms) -> []
        | FOr(f1, f2) -> 
            unique ((gather_nonneg_equalities_involving_vars f1 neg) @ 
                    (gather_nonneg_equalities_involving_vars f2 neg))
        | FAnd(f1, f2) -> 
            unique ((gather_nonneg_equalities_involving_vars f1 neg) @ 
                    (gather_nonneg_equalities_involving_vars f2 neg))
        | FNot(f2) -> 
            (gather_nonneg_equalities_involving_vars f2 (not neg));; 

(* f[v -> t] *)
let rec substitute_term (f: formula) (v: term) (t: term): formula = 
    match f with
        | FTrue -> f
        | FFalse -> f
        | FEquals(t1, t2) ->
          (* Remove fmlas which will be "x=x"; avoids inf. loop. *)
          if t1 = v && t2 = t then FTrue
          else if t2 = v && t1 = t then FTrue
          else if t1 = v then FEquals(t, t2)
          else if t2 = v then FEquals(t1, t)
          else f
        | FAtom(modstr, relstr, argterms) -> 
          let newargterms = map (fun arg -> 
              (*(printf "***** %s\n%!" (string_of_term arg));*)
              if v = arg then t else arg) argterms in
            FAtom(modstr, relstr, newargterms)
        | FOr(f1, f2) ->         
            let subs1 = substitute_term f1 v t in
            let subs2 = substitute_term f2 v t in
            if subs1 = FFalse then subs2 
            else if subs2 = FFalse then subs1            
            else FOr(subs1, subs2)       
        | FAnd(f1, f2) ->
            (* remove superfluous FTrues/FFalses *) 
            let subs1 = substitute_term f1 v t in
            let subs2 = substitute_term f2 v t in
            if subs1 = FTrue then subs2 
            else if subs2 = FTrue then subs1            
            else FAnd(subs1, subs2)       
        | FNot(f2) -> 
            FNot(substitute_term f2 v t);;

(* assume a clause body *)
let rec minimize_variables (f: formula): formula = 
  (* OPTIMIZATION: don't need to do gathering step repeatedly: *)
  let var_equals_fmlas = gather_nonneg_equalities_involving_vars f false in
    (*printf "at fmla = %s\n%!" (string_of_formula f);        
    iter (fun pr -> let (t1, t2) = pr in (printf "pair: %s, %s\n%!" 
            (string_of_term t1) (string_of_term t2))) var_equals_fmlas;*)

    if length var_equals_fmlas < 1 then
      f
    else 
      let (x, t) = hd var_equals_fmlas in  
      let newf = (substitute_term f x t) in
        minimize_variables newf;;

