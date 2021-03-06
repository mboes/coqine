open Environ
open Names
open Term
open Typeops
open Dkterm
open Declarations

exception RuleDoesNotExist
exception Typehasnotype
exception NotASort
exception NotACoqVar
exception AnonymousCoqVar
exception NotImplementedYet
exception ShouldNotAppear
exception EmptyArrayInApp


(**************** Fresh vars **********************)

(* TODO: better fresh vars *)
module VarMap = Map.Make
  (struct
     type t = string
     let compare = compare
   end)

let fresh_map = ref VarMap.empty

(* Get a new name beginning with a prefix. *)
let fresh_var prefix =
  let i =
    try VarMap.find prefix !fresh_map
    with Not_found -> 0 in
    fresh_map := VarMap.add prefix (i+1) !fresh_map;
  prefix ^ string_of_int i




(*********** Translation constr (i.e. coq term) to dkterm  *************)

let which_dotpi r = match r with
  | Prop Null,Prop Null  -> "dotpipp"
  | Prop Null,Prop Pos   -> "dotpips"
  | Prop Null,Type _     -> "dotpipt"
  | Prop Pos,Prop Null   -> "dotpisp"
  | Type _,Prop Null     -> "dotpitp"
  | Prop Pos,Type _      -> "dotpist"
  | Type _,Prop Pos      -> "dotpits"
  | Prop Pos,Prop Pos    -> "dotpiss"
  | Type _,Type _        -> "dotpitt"


let get_dotpi e n t1 t2 =
  let e1 =  push_rel (n,None,t1) e in
    which_dotpi (infer_type e t1, infer_type e1 t2)

let which_e s = match s with
  | Prop Pos  -> "eset"
  | Prop Null -> "eprop"
  | Type _    -> "etype"

(* Given environment e, get the scene in which t plays. *)
let get_e e t = which_e (infer_type e t)

(* From coq names to string. *)
let name_to_string n = match n with
  | Anonymous -> fresh_var "_dk_anon"
  | Name s -> s

let get_identifier n = match n with
  | Anonymous -> fresh_var "_dk_anon"
  | Name s -> s

(* Get an identifier depending on the current environment e. *)
let rec get_identifier_env e n =
  match n with
    | Anonymous -> get_identifier_env e (Name "_dk_anon")
    | Name s ->
	let rec compute_alpha ch =
	  let rec alpha_counts n = function
	      (Name i,_,_)::q when i = ch -> alpha_counts (n+1) q
	    | (Anonymous, _, _)::q when ch = "_dk_anon" -> alpha_counts (n+1) q
	    | _::q -> alpha_counts n q
	  | [] -> n
	  in
	  let n = alpha_counts 0 e.env_rel_context in
	    if n = 0 then ch
	    else compute_alpha (ch ^ "xxx" ^ string_of_int (n-1))
	in
	  compute_alpha s

let nth_rel_in_env n e =
  let rec aux = function
      1, (n,_,_)::l -> get_identifier_env { e with env_rel_context = l } n
    | n, x::l -> aux (n-1,l)
    | _ -> failwith "nth_rel_in_env: context not big enough"
  in
    aux (n, e.env_rel_context)

(* From coq names to dedukti ids. *)
let name_to_qid n = Id (string_of_id (get_identifier n))


(* base_env is the environment in which inductive declarations are
   progressively added. *)
let base_env = ref empty_env


(* Translation of t as a term, given an environment e and a set of
   intermediary declarations decls (in reverse order). *)
let rec term_trans_aux e t decls =

  (* Applies every variable in the rel context of the environment e to c. *)
  let rec app_rel_context e c decls = match e.env_rel_context  with
      [] -> [], c, decls
    | (n,_,t)::rel_context ->
	let e = { e with env_rel_context = rel_context } in
	let v = get_identifier_env e n in
	let vs, c, decls1 = app_rel_context e c decls in
	let t_tt, decls2 = type_trans_aux e t decls1 in
	  (Id v, t_tt)::vs, DApp(c,DVar (Id v)), decls
  in

    (* Add free variables to complete a constructor
       add_vars free_vars e c (t, params) :
       free_vars : accumulator for the free variables (as a list of pairs
       id * type
       e : current environment
       c : constr to be completed
       t : type of constr
       params : parameters of the inductive type
       example : add_vars [] e c (a : A -> b : B -> d : D -> I x y z, [A])
       returns [b0 : B; d0 : D], c b0 d0, [|x; y; z|] *)
    (*   let rec add_vars free_vars e c  = function *)
    (*     | Prod(_,t, q), [] -> let v = fresh_var "var_" in *)
    (*       let e' = push_rel (Name v, None, t) e in *)
    (* 	add_vars ((Id v,type_trans_aux e t)::free_vars) e' (DApp(c, DVar (Id v))) (q,[]) *)
    (*     | t,[] -> free_vars, c, *)
    (* 	begin match collapse_appl t with App(_,a) -> a *)
    (* 	  | _ -> [||] *)
    (* 	end *)
    (*     | Prod(_,t, q),arg::args -> *)
    (* 	let n = List.length e.env_rel_context in *)
    (* 	let e' = push_named (arg, None, it_mkProd_or_LetIn t e.env_rel_context) *)
    (* 	  e in *)
    (* 	  add_vars free_vars e' *)
    (* 	    (DApp(c, snd (app_rel_context e (DVar (Id arg))))) *)
    (* 	    (subst1 (App(Var arg, Array.init n (fun m -> Rel (n-m)))) q, args) *)
    (*     | _ -> failwith "add_vars: too many parameters" *)
    (*   in *)
    (* Transform a list of dedukti variables into an array of Coq variables. *)
    (*   let vars_to_args l =  *)
    (*     let rec vars_to_args array = function *)
    (* 	0,[] -> array *)
    (*       | n,(Id v,_)::q -> array.(n-1) <- Var v; vars_to_args array (n-1,q) *)
    (*       | _ -> failwith "vars_to_args:discrepency" *)
    (*     in *)
    (*     let n = List.length l in  *)
    (*       vars_to_args (Array.make n (Var "dummy")) (n,l) *)
    (*   in *)

    (* The translation is by induction on the term. *)
    match t with
      | Rel n -> DVar (Id (nth_rel_in_env n e)), decls

      | Var v  -> DVar(Id v), decls

      | Meta _ -> raise ShouldNotAppear

      | Evar _ -> raise ShouldNotAppear

      | Sort s -> (match s with
                     | Prop Null -> DVar (Qid ("Coq1univ","dotprop"))
                     | Prop Pos ->  DVar (Qid ("Coq1univ","dotset"))
                     | Type _ ->    DVar (Qid ("Coq1univ","dottype")))  (*** !!! Attention a Type 0 ***)
	  , decls

      | Cast _ -> raise NotImplementedYet


      | Prod (n,t1,t2)  ->
	  let t_tt1, decls1 = term_trans_aux e t1 decls
	  and e1 = push_rel (n,None,t1) e in
	  let t_tt2, decls2 = term_trans_aux e1 t2 decls1 in
	    DApp (DApp (DVar(Qid("Coq1univ",get_dotpi e n t1 t2)), t_tt1),
		  DFun (Id (get_identifier_env e n),
			DApp(DVar(Qid ("Coq1univ",get_e e t1)), t_tt1),
			t_tt2)), decls2

      | Lambda (n,t1,t2)  ->
	  let t_tt1, decls1 = type_trans_aux e t1 decls
	  and e1 = push_rel (n,None,t1) e in
	  let t_tt2, decls2 = term_trans_aux e1 t2 decls1 in
	    DFun ((Id (get_identifier_env e n)),
                  t_tt1,
                  t_tt2), decls2

      | LetIn (var, eq, ty, body)  ->
	  term_trans_aux e (App(Lambda(var, ty, body), [| eq |])) decls

      | App (t1,a)  ->
	  Array.fold_left
	    (fun (u1,decls1) u2 ->
	       let u_tt2, decls2 = term_trans_aux e u2 decls1 in
		 DApp(u1, u_tt2), decls2)
	    (term_trans_aux e t1 decls) a

      | Const(mod_path,dp,name)  -> (* TODO: treat the module path and the dir path. *)
	  (* depending whether the const is defined here or in
	     another module *)
	  (match mod_path with
	       MPself _ -> DVar (Id name)
	     | MPfile (m :: _) -> (* TODO : use the whole dirpath *)
		 DVar (Qid (m,name))
	     | _ -> failwith "Not implemented: modules bound and dot module path"
	  ),
	  decls

      | Ind((mod_path,_,l) as ind, num)  -> begin
	  try
	    let name = (lookup_mind ind e).mind_packets.(num).mind_typename in
	      (* depending whether the inductive is defined here or in
		 another module *)
	      (match mod_path with
		   MPself _ -> DVar (Id name)
		 | MPfile (m :: _) -> (* TODO : use the whole dirpath *)
		     DVar (Qid (m,name))
		 | _ -> failwith "Not implemented: modules bound and dot module path"
	      ),
	    decls
	  with Not_found -> failwith ("term translation: unknown inductive "
				      ^ l) end

      | Construct(((mod_path,_,l) as ind,j), i) -> begin
	  try
	    let name = (lookup_mind ind e).mind_packets.(j).mind_consnames.(i-1) in
	      (match mod_path with
		   MPself _ -> DVar (Id name)
		 | MPfile (m :: _) -> (* TODO : use the whole dirpath *)
		     DVar (Qid (m,name))
		 | _ -> failwith "Not implemented: modules bound and dot module path"
	      ),

	    decls
	  with Not_found -> failwith ("term translation: unknown inductive "
				      ^l) end

      | Case (ind, ret_ty, matched, branches)  ->
	  let mind_body = lookup_mind (fst ind.ci_ind) e in
	  let case_name =
	    mind_body.mind_packets.(snd ind.ci_ind).mind_typename ^ "__case"
	  in
	    (* Get the arguments of the type of the matched term. *)
	  let matched_args =
	    match collapse_appl (Reduction.whd_betadeltaiota e (infer e matched))
	    with App(Ind(i),t) when i = ind.ci_ind -> t
	      | Ind(i) when i = ind.ci_ind -> [||]
	      | _ -> failwith "term_trans: matched term badly typed"
	  in
	  let r = ref (match fst ind.ci_ind with
		   MPself _, _, _ -> DVar (Id case_name)
		 | MPfile (m :: _), _ , _  -> (* TODO : use the whole dirpath *)
		     DVar (Qid (m,case_name))
		 | _ -> failwith "Not implemented: modules bound and dot module path"
			      )
	  and d = ref decls in
	    for i = 0 to ind.ci_npar - 1 do
	      (* We cannot use Array.fold_left since we only need
		 the parameters. *)
	      let arg_tt, decls' =
		term_trans_aux e matched_args.(i) !d in
		r := DApp(!r, arg_tt);
		d := decls'
	    done;
	    let ret_ty_tt, decls' = term_trans_aux e ret_ty !d in
	      r := DApp(!r, ret_ty_tt);
	      d := decls';
	      Array.iter
		(fun b ->
		   let b_tt, decls' = term_trans_aux e b !d in
		     r := DApp(!r, b_tt);
		     d := decls')
		branches;
	      for i = ind.ci_npar to Array.length matched_args - 1 do
		let arg_tt, decls' =
		  term_trans_aux e matched_args.(i) !d in
		  r := DApp(!r, arg_tt);
		  d := decls'
	      done;
	      let m_tt, decls' = term_trans_aux e matched !d in
		DApp(!r, m_tt), decls'

      | Fix((struct_arg_nums, num_def),(names, body_types, body_terms)) ->
	  (* May create an unterminating rule. *)
	  (* Get fresh names for the fixpoints. *)
	  let names = Array.map
	    (function
		 Name n -> fresh_var (n ^ "_")
	       | Anonymous -> fresh_var "fix_"
	    )
	    names in
	    (* Translation of one inductive fixpoint. *)
	  let one_trans struct_arg_num name body_type body_term decls =
	    (* Declare the type of the fixpoint function. *)
	    let decls' =
	      let t, decls' = type_trans_aux
		{ e with env_rel_context = [] }
		(it_mkProd_or_LetIn
		   body_type
		   e.env_rel_context
		) decls in
		Declaration(Id name, t)::decls' in
	      (* Recursively applies all the variables in the context at the
		 point of the fixpoint definition down to the recursive
		 variable, and creates a rule outside of the current context. *)
	    let env_vars, fix, decls' =
	      app_rel_context e (DVar(Id name)) decls' in
	    let rec make_rule e vars fix rhs decls = function
		0, Prod(n, a, _) ->
		  let s = get_identifier_env e n in
		    (* Adds s:Typeofs to the list of things to apply to the
		       fixpoint. *)
		  let a_tt, decls' = type_trans_aux e a decls in
		  let vars = List.rev_append vars
		    [Id s, a_tt]
		  in
		    (* This is the final case, apply the recursive variable to
		       f and create a rule f x1...xn --> rhs x1...xn. *)
                    Rule(List.rev_append env_vars vars,
			 DApp(fix, DVar (Id s)),
			 DApp(rhs, DVar (Id s))
			)
		    ::decls'
	      | n, Prod(nom, a, t) ->
		  let s = get_identifier_env e nom in
		  let e' = push_rel (nom, None, a) e in
		  let a_tt, decls' = type_trans_aux e a decls in
		    (* This is the not final case, apply the current variable
		       to f x1...xi and to rhs and call yourself
		       recursively. *)
		    make_rule e' ((Id s, a_tt)::vars)
		      (DApp(fix, DVar (Id s)))
		      (DApp(rhs, DVar (Id s)))
		      decls'
		      (n-1, t)
	      | _ -> failwith "fixpoint translation: ill-formed type" in
	      (* Here we need to give the right parameters to
		 make_rule. *)
	    let n = List.length e.env_rel_context in
	      (* The variable arguments to pass to fix have de bruijn
		 indices from 0 to n. *)
	    let rel_args = Array.init n (fun i -> Rel (n - i)) in
	      (*rhs_env  adds the names of the mutually defined recursive
		functions in the context for the rhs*)
	    let _,rhs_env = Array.fold_left
	      (fun (i,e) n ->
		 i+1, push_named (n, None, body_types.(i)) e)
	      (0,e) names in
	      (* We use the just defined context to replace the indexes in the
		 rhs that refer to recursive calls (the rhs is typed in the
		 context with the recursive functions and their types). *)
	    let sigma = Array.fold_left
	      (fun l n -> App(Var n, rel_args)::l) [] names
	    in
	    let rhs, decls2 =
	      term_trans_aux rhs_env (substl sigma body_term) decls'
	    in
	      make_rule e [] fix rhs decls2 (struct_arg_num, body_type)
	  in
	    (* And we iterate this process over the body of every. *)
	  let _, decls' = Array.fold_left
	    (fun (i,decls) struct_arg_num -> i+1,
	       one_trans struct_arg_num names.(i)
		 body_types.(i) body_terms.(i) decls)
	    (0,decls) struct_arg_nums in
	    (* The term corresponding to the fix point is the identifier
	       to which the context is applied. *)
	  let _, t, decls = app_rel_context e (DVar(Id names.(num_def))) decls'
	  in
	    t, decls

      | CoFix   _  -> raise NotImplementedYet

(*** Translation of t as a type, given an environment e. ***)

and type_trans_aux e t decls = match t with
  | Sort s -> (match s with
		 | Prop Pos  -> DVar(Qid("Coq1univ","Uset"))
		 | Prop Null -> DVar(Qid("Coq1univ","Uprop"))
		 | Type _    -> DVar(Qid("Coq1univ","Utype"))), decls

  | Prod(n,t1,t2) ->  let t_tt1, decls1 = type_trans_aux e t1 decls and e1 = push_rel (n,None,t1) e in
    let t_tt2, decls2 = type_trans_aux e1 t2 decls1 in
      DPi(Id (get_identifier_env e n),t_tt1,t_tt2), decls2

  | t -> let t', decls' = term_trans_aux e t decls in
      DApp(DVar(Qid("Coq1univ",get_e e t)), t'), decls'


(* Translation functions without environment. *)
let term_trans t = term_trans_aux !base_env t []

let type_trans t = type_trans_aux !base_env t []

(*** Translation of a declaration in a structure body. ***)

(* auxiliary function for add_ind_and_constr
   add variables corresponding to the remaining args of the constructor
*)
let rec add_ind_and_constr' m e vars cons_name decls = function
    Prod(n,t1,t2) ->
      let v = fresh_var "c_arg_" in
      let e' = push_rel (Name v, None, t1) e in
      let t_tt1, decls' = type_trans_aux e t1 decls in
        add_ind_and_constr' m e' ((Id v, t_tt1)::vars)
          (DApp(cons_name, DVar (Id v))) decls' t2
  | App(_,args) ->
      let ind =
        Array.make (Array.length args - m) DKind in
      let d = ref decls in
        for i = 0 to Array.length ind - 1 do
	  let a_i, d' = term_trans_aux e args.(i+m) decls in
            ind.(i) <- a_i;
	    d := d'
        done;
        cons_name, ind, vars, !d
  | _ ->
      cons_name, [||], vars, decls

(* p : number of constructors
   e : environment
   vars : accumulator
   cons_name : name of the constructor
   decls : accumulator for the declarations
   params : list of variables for the parameter
   typ : type of the constructor

   returns the constructor with variables for the parameters and the other args
           the new variables
           their declaration
           the auxiliary declarations
*)
let add_ind_and_constr p e cons_name decls params typ =
  let m = List.length params in
  (* add the parameters to the constructor *)
  let rec aux i c = function
      [], typ -> add_ind_and_constr' m e [] c decls typ
    | (id, _)::q, Prod(n,t1,t2) ->
	 let t2 = subst1 (Rel (i + m + 1)) t2 in
           aux (i-1) (DApp(c, DVar id)) (q,t2)
    | _ -> failwith "inductive translation: ill-typed constructor"
  in
    aux p cons_name (params, typ)


(* Auxiliary function for make_constr_func_type *)
let rec make_constr_func_type' cons_name num_treated num_param num_args = function
    Prod(n, t1, t2) ->
      Prod(n, t1,
	   make_constr_func_type' cons_name num_treated num_param
	     (num_args+1) t2)
  | App(_,args) ->
      App(App(Rel (num_args + 1 + num_treated),
	      Array.init (Array.length args - num_param)
			(fun i -> args.(i+ num_param))),
		  [| App(Var cons_name,
			 Array.init (num_args+num_param)
			   (fun i -> if i < num_param
			    then Rel(num_args + 1 + num_treated + num_param - i)
			    else Rel(num_args + num_param - i))) |] )
  |  _ ->
	      App(Rel (num_args + 1 + num_treated),
		  [| App(Var cons_name,
			 Array.init (num_args+num_param)
			   (fun i -> if i < num_param
			    then Rel(num_args + 1 + num_treated + num_param - i)
			    else Rel(num_args + num_param - i))) |] )


(* Makes the type of the function in the __case of an inductive type
   corresponding to a constructor
   make_constr_func_type cons_name num_treated type :
     cons_name : name of the constructor
     num_treated : number of the constructor in the inductive definition
     num_param : number of parameters
     type : type of the constructor
 *)
let make_constr_func_type cons_name num_treated num_param typ =
  let rec aux = function
      0, t -> make_constr_func_type' cons_name num_treated num_param
	0 (lift num_treated t)
    | n, Prod(_, t1, t2) ->
	aux (n-1, subst1 (Rel(n+1)) t2)
    | _ -> failwith "inductive translation: ill-formed constructor type"
  in aux (num_param, typ)


(* translate a packet of a mutual inductive definition (i.e. a single inductive)
   env : environment
   ind : path of the current inductive
   params : parameter context of the mutual inductive definition
   constr_types : type of the constructors in p
   p : packet
   decls : accumulator of declarations
*)
let packet_translation env ind params constr_types p decls =
  let n_params = List.length params in
  (* Add the constructors to the environment  *)
  let indices = (* arguments that are not parameters *)
    let rec aux accu = function
	0, _ -> List.rev accu
      | n, x :: q -> aux (x::accu) (n-1, q)
      | _ -> failwith "inductive translation: ill-formed arity"
    in aux [] (List.length p.mind_arity_ctxt - n_params,
	       p.mind_arity_ctxt)
  in
  let constr_decl name c decls =
    let c_tt, decls' = type_trans_aux env c decls in
      Declaration (Id name, c_tt)::decls' in
  let nb_consts =  Array.length p.mind_consnames in
  let case_name = DVar (Id (p.mind_typename ^ "__case")) in
  let _, env, param_vars, case_name, this_decls =
    List.fold_left
      (fun (i, e, vars, c, decls) (n,_,t) ->
	 if i = 0 then i, e, vars, c, decls
	 else
	   let v = fresh_var "param_" in
	   let e' = push_rel (Name v, None, t) e in
	   let t_tt, decls' = type_trans_aux e t decls in
	     i-1,e',(Id v, t_tt)::vars, DApp(c, DVar (Id v)), decls'
      )
      (n_params, env, [], case_name, []) (List.rev p.mind_arity_ctxt)
  in
  let p_var, case_name, env, this_decls =
    let v = fresh_var "P_" in
    let t = it_mkProd_or_LetIn
      (Prod(Name "i",
            App(Ind(ind),
		      let n = List.length p.mind_arity_ctxt in
			Array.init n (fun i -> Rel (n-i))),
		  Term.Sort (Term.Type (Univ.Atom Univ.Set))))
	    indices in
	  let e = push_rel (Name v, None, t) env in
	  let t_tt, decls' = type_trans_aux env t this_decls in
	    (Id v, t_tt),
	  DApp(case_name, DVar(Id v)),
	  e,
	  decls'
	in
	let _,env,func_vars, case_name, this_decls = Array.fold_left
	  (fun (i,e,vars,c,decls) cons_name  ->
	     let t = make_constr_func_type
	       cons_name i n_params
	       constr_types.(i) in
	     let v = fresh_var "f_" in
	     let e' = push_rel (Name v, None, t) e in
	     let t_tt, decls' = type_trans_aux e t decls in
	       i+1,e',(Id v, t_tt)::vars, DApp(c, DVar (Id v)), decls'
	  )
	  (0,env,[],case_name, this_decls) p.mind_consnames
	in
	let _, this_decls =
	  Array.fold_left
	    (fun (i, decls) cons_name ->
	       i+1, constr_decl cons_name p.mind_user_lc.(i) decls)
	    (0,this_decls) p.mind_consnames
	in
	  (* This big piece of code is the type in the Coq world of
	     the __case.
	  *)
	let i__case_coq_type =
	  let return_type =
	    it_mkProd_or_LetIn
	      (Prod(Name "i",
		    App(Ind(ind),
			let n = List.length p.mind_arity_ctxt in
			  Array.init n (fun i -> Rel (n-i))),
		    Term.Sort (Term.Type (Univ.Atom Univ.Set))))
	      indices
	  in
	  let end_type =
	    Prod(Anonymous,
		 App(Ind(ind),
		     let n = List.length p.mind_arity_ctxt in
		       Array.init n (fun i ->
				       if i < n_params
				       then Rel(n - i + Array.length p.mind_consnames + 1)
				       else Rel(n-i))),

		 App(Rel(Array.length p.mind_consnames + 2 + List.length indices),
		     let n = List.length indices + 1
		     in Array.init n (fun i -> Rel(n-i)))
		)
	  in
	  let end_type_with_indices =
	    it_mkProd_or_LetIn
	      end_type
	      (List.map
		 (fun (a,r,t) ->
		    a, r,
		    lift (Array.length p.mind_consnames + 1)
		      t) indices)
	  in
	  let rec add_functions_from_constrs c = function
	      -1 -> c
	    | i -> add_functions_from_constrs
		(Prod(Name "f",
		      make_constr_func_type p.mind_consnames.(i) i
			n_params
			constr_types.(i),
		      c))
		  (i-1)
	  in
	    it_mkProd_or_LetIn
	      (Prod(Name "P",
		    return_type,
		    add_functions_from_constrs
		      end_type_with_indices
		      (Array.length p.mind_consnames-1)
		   ))
	      params in
	  (* end of i__case_coq_type *)

	(* declaration of the __case type *)
	let i__case_trans, this_decls =
	  type_trans_aux env i__case_coq_type this_decls in
	let this_decls =
	  Declaration(
	    Id (p.mind_typename ^ "__case"),
	    i__case_trans)::this_decls
	in
	let _,this_decls =
	  Array.fold_left
	    (fun (i, d) cons_name ->
	       let constr, indices, c_vars, d' =
		 add_ind_and_constr
		   nb_consts env
		   (DVar (Id  cons_name)) d
		   (List.rev param_vars)
		   constr_types.(i) in
		 i+1,
               Rule(List.rev_append param_vars
                      (p_var::List.rev_append func_vars (List.rev c_vars)),
		    DApp(Array.fold_left (fun c a -> DApp(c,a))
			   case_name indices,
			 constr),
		    match List.nth func_vars (List.length func_vars-i-1)
		    with id,_ ->
		      List.fold_right (fun (v,_) c -> DApp(c, DVar v))
			c_vars (DVar id)
		   )::d')
	    (0,this_decls) p.mind_consnames in
	  List.rev_append this_decls decls

(* Translation of a declaration in a structure. *)
let sb_decl_trans label (name, decl) =
  prerr_endline ("declaring "^name);
  match decl with
      (* Declaration of a constant (theorem, definition, etc.). *)
      SFBconst sbfc ->
	base_env := Environ.add_constraints sbfc.const_constraints !base_env;
	let tterm, term_decls = match sbfc.const_body with
	    Some cb -> begin
	      match !cb with
		  LSval c -> term_trans c
		| LSlazy(s,c) -> failwith "not implemented: lazy subst"
	    end
	  | None -> failwith "no term given"
	and ttype, type_decls = match sbfc.const_type with
	    NonPolymorphicType t -> type_trans t
	  | PolymorphicArity(context, arity) ->
	      (* TODO: Not sure this is really how it works. *)
	      type_trans (it_mkProd_or_LetIn (Sort (Type arity.poly_level))
			    context)
	in
          base_env := Environ.add_constant (Names.MPself label, [], name) sbfc !base_env;
	  List.rev_append term_decls
	    (List.rev_append type_decls [Declaration(Id name, ttype); Rule([],DVar(Id name), tterm)])

    (* Declaration of a (co-)inductive type. *)
    | SFBmind m ->
	if not m.mind_finite
	then prerr_endline
	  "mind_translation: coinductive types may not work properly";
	(* Add the mutual inductive type declaration to the environment. *)
	base_env := Environ.add_mind (Names.MPself label,[],name) m !base_env;
	(* The names and typing context of the inductive type. *)
	let mind_names, env =
	  let l = ref []
	  and e = ref
	    (Environ.add_constraints m.mind_constraints !base_env)
	  in
	    for i = 0 to Array.length m.mind_packets - 1 do
	      let p = m.mind_packets.(i) in
		(* For each packet=group of mutal inductive type definitions
		   "p", add the name of the inductive type to l and the
		   declaration of the inductive type with it's kind to the
		   environment. *)
		l := Ind((Names.MPself label, [], name), i)::!l;
		e := Environ.push_rel (Names.Name p.mind_typename, None,
				       (it_mkProd_or_LetIn
					  (Sort (match p.mind_arity with
						     Monomorphic ar ->  ar.mind_sort
						   | Polymorphic par ->
						       Type par.poly_level))
					  p.mind_arity_ctxt))
		  !e
	    done;
	    !l,!e
	in
	  (* Add the inductive type declarations in dedukti. *)
	let decls,_ =
	  Array.fold_right
	    (fun p (d,i) ->
	       let constr_types = Array.map (substl mind_names) p.mind_nf_lc in
	       let _,env = Array.fold_left
		 (fun (j, env) consname ->
		    j + 1,
		    Environ.push_named (consname, None, constr_types.(j)) env)
		 (0, env) p.mind_consnames in
		 packet_translation env ((Names.MPself label, [], name), i)
                   m.mind_params_ctxt constr_types p d, i+1)
	    m.mind_packets ([],0)
	in
	  Array.fold_right
	    (fun p d ->
	       let t, d' = type_trans_aux env
		 (it_mkProd_or_LetIn
		    (Sort (match p.mind_arity with
			       Monomorphic ar ->  ar.mind_sort
			     | Polymorphic par ->
				 Type par.poly_level))
		    p.mind_arity_ctxt
		 )
		 d in
		 Declaration(Id p.mind_typename,
			     t)::d')
	    m.mind_packets decls
    | _ -> raise NotImplementedYet
