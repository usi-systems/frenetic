module Int32Set = Set.Make(Int32)

let read_file (fname : string) : string = 
  let open Util in 
  let lines = ref [] in
  let chan = open_in fname in 
  try 
	while true; do
	  lines := input_line chan :: 
		!lines
	done; ""
  with End_of_file -> 
	close_in chan;
	(intercalate (fun x -> x) "\n" (List.rev !lines))


module Dexterize = struct
  open Decide_Ast
  open Decide_Ast.Term
  module Value = Decide_Util.Value
  module Field = Decide_Util.Field

  let header_value_to_pair h = 
    let open NetKAT_Types in 
    match h with
      | Switch(n) -> ("switch", Int64.to_string n)
      | Location(Physical n) -> ("port", Int32.to_string n)
      | Location(Pipe x) -> ("port", x)
      | EthSrc(n) -> ("ethsrc", Int64.to_string n)
      | EthDst(n) -> ("ethdst", Int64.to_string n)
      | Vlan(n) -> ("vlan", string_of_int n)
      | VlanPcp(n) -> ("vlanpcp", string_of_int n)
      | EthType(n) -> ("ethtype", string_of_int n)
      | IPProto(n) -> ("ipproto", string_of_int n)
      | IP4Src(n,32l) -> ("ipsrc", Int32.to_string n)
      | IP4Dst(n,32l) -> ("ipdst", Int32.to_string n)
      | IP4Src(n,m) -> ("ipsrc", Int32.to_string n)
      | IP4Dst(n,m) -> ("ipdst", Int32.to_string n)
      | TCPSrcPort(n) -> ("tcpsrcport", string_of_int n)
      | TCPDstPort(n) -> ("tcpdstport", string_of_int n)

  let rec pred_to_term = function
    | NetKAT_Types.True -> 
      make_one ()
    | NetKAT_Types.False -> 
      make_zero ()
    | NetKAT_Types.Test(h) -> 
      let x,n = header_value_to_pair h in 
      make_test (Field.of_string x, Value.of_string n)
    | NetKAT_Types.And(pr1,pr2) -> 
      make_times [pred_to_term pr1; pred_to_term pr2]
    | NetKAT_Types.Or(pr1,pr2) -> 
      make_plus (Decide_Ast.TermSet.of_list [(pred_to_term pr1);(pred_to_term pr2)])
    | NetKAT_Types.Neg(pr) -> 
      make_not (pred_to_term pr) 

  let rec policy_to_term ?dup:(dup=true) = function
    | NetKAT_Types.Filter(p) -> 
      pred_to_term p
    | NetKAT_Types.Mod(h) -> 
      let x,n = header_value_to_pair h in 
      make_assg (Field.of_string x, Value.of_string n)
    | NetKAT_Types.Union(p1,p2) -> 
      make_plus (Decide_Ast.TermSet.of_list [policy_to_term ~dup:dup p1; policy_to_term ~dup:dup p2])
    | NetKAT_Types.Seq(p1,p2) -> 
      make_times [policy_to_term ~dup:dup p1; policy_to_term ~dup:dup p2]
    | NetKAT_Types.Star(p) -> 
      make_star (policy_to_term ~dup:dup p)
    | NetKAT_Types.Link(sw1,pt1,sw2,pt2) -> 
      make_times (make_test (Field.of_string "switch", Value.of_string (Int64.to_string sw1)) :: 
               make_test (Field.of_string "port", Value.of_string (Int32.to_string pt1)) ::
               make_assg (Field.of_string "switch", Value.of_string (Int64.to_string sw2)) :: 
               make_assg (Field.of_string "port", Value.of_string (Int32.to_string pt2)) ::
               if dup then [make_dup ()] else [])
end

module IPMask = struct
  type t = int32 * int32
  let compare = compare
end
module IP = struct
  type t = int32
  let compare = compare
end
module IPMaskSet = Set.Make(IPMask)
module IPMaskMap = Map.Make(IPMask)
module IPSet = Set.Make(IP)
  
let string_of_ip_mask (p,m) = 
  Printf.sprintf "%s%s" 
    (Packet.string_of_ip p) 
    (if m = 32l then "" else "/" ^ Int32.to_string m) 
    
let f32s s =
  Int32Set.fold 
    (fun x acc -> Printf.sprintf "%s%s%ld" acc (if acc = "" then acc else ", ") x)
    s ""  

let fms s = 
  IPMaskSet.fold
    (fun x acc -> Printf.sprintf "%s%s%s" acc (if acc = "" then acc else ", ") (string_of_ip_mask x)) 
    s ""  

let fr (ins,ip_pats,ip_modo,outs)= 
  Printf.sprintf "<{%s},%s%s,{%s}>" 
    (f32s ins)
    (fms ip_pats)
    (match ip_modo with None -> "" | Some a -> ", " ^ Packet.string_of_ip a)
    (f32s outs) 
  
module IPMasks = struct

  module BrxMap = Map.Make(Brx)

  let brx_of_ip (p,m) = 
    let open Brx in 
    let mask = Int32.to_int m in (* NB: this is the opposite of the usual convention! *)
    let mtch = 32 - mask in 
    let pat = if mask = 0 then p else Int32.shift_right_logical p mask in 
    let rec bits x n acc = 
      if n = 0 then acc
      else
	let acc' = String.make 1 (if Int32.rem x 2l = 0l then '\000' else '\001') ^ acc in 
	let n' = pred n in 
	let x' = Int32.shift_right_logical x 1 in 
	bits x' n' acc' in 
    let bs = bits pat mtch "" in 
    let r = mk_seq (mk_string bs) (mk_iter alphabet mask (Some mask)) in 
    (* Printf.printf "BRX_OF_IP: %s -> %s\n" (string_of_ip_mask (p,m)) (Brx.string_of_t r); *)
    r

  let any_ip = brx_of_ip (0l,32l)

  let ip_of_brx b = 
    match Brx.representative b with 
    | None -> 
      None
    | Some s -> 
      let n = String.length s - 1 in 
      let rec loop i acc = 
	if i > n then acc
	else
	  begin 
	    match s.[i] with
	    | '0' -> 
	      loop (succ i) (Int32.shift_left acc 1)
	    | '1' -> 
	      loop (succ i) (Int32.add (Int32.shift_left acc 1) 1l)
	    | c -> 
	      failwith (Printf.sprintf "invalid regular expression: %c" c)
	  end in 
      Some (loop 0 0l)
	
  let partition_ips ips = 
    (* IPMaskSet.iter (fun x -> Printf.printf "%s\n" (string_of_ip_mask x)) ips; *)
    let n = IPMaskSet.cardinal ips in 
    let i = ref 0 in 
    let part = 
      IPMaskSet.fold
	(fun x acc -> 
	  Printf.printf "[2K\r[32m[Partitioning][0m: %s %d / %d (%d)%!" 
	    (string_of_ip_mask x) !i n (BrxMap.cardinal acc);
	  incr i;
	  let bx = brx_of_ip x in 
	  let sx = IPMaskSet.singleton x in 
	  let bx',acc' = 
	    BrxMap.fold
	      (fun by s (b,acc) -> 
		let i = Brx.mk_inter b by in 
		if Brx.is_empty i then 
		  (b,BrxMap.add by s acc)
		else
		  let r = Brx.mk_diff by b in 
		  let l = Brx.mk_diff b by in 
		  (l, BrxMap.add r s (BrxMap.add i (IPMaskSet.union s sx) acc)))
	      acc (bx,BrxMap.empty) in 
	  assert (Brx.is_empty bx'); 
	  acc')
	ips 
	(BrxMap.singleton any_ip IPMaskSet.empty) in 
    Printf.printf "\n%!";
    BrxMap.fold
      (fun bx s acc -> 
	match ip_of_brx bx with 
	| None -> 
	  acc
	| Some a -> 
	  let sa = IPSet.singleton a in 
	  IPMaskSet.fold
	    (fun y acc -> 
	      let sy = 
		try IPMaskMap.find y acc
		with Not_found -> IPSet.empty in 
	      IPMaskMap.add y (IPSet.union sa sy) acc)
	    s acc)
      part IPMaskMap.empty

  let ips_of_rule (ins,ip_pats,ip_modo,outs) = 
      IPMaskSet.union 
	ip_pats 
	(match ip_modo with 
	| None -> IPMaskSet.empty 
	| Some ip_mod -> IPMaskSet.singleton (ip_mod, 32l))

  let ips_of_rules rules = 
    List.fold_left 
      (fun acc rule -> IPMaskSet.union (ips_of_rule rule) acc)
      IPMaskSet.empty rules 

  let subst_rule subst (ins,ip_pats,ip_modo,outs) = 
    let ip_pats' = 
      IPMaskSet.fold 
	(fun x acc -> 
	  try 
	    IPSet.fold 
	      (fun a acc -> IPMaskSet.add (a,32l) acc) 
	      (IPMaskMap.find x subst) acc 
	  with Not_found ->
	    failwith (Printf.sprintf "subst_rule: no entry for %s" (string_of_ip_mask x)))
	ip_pats IPMaskSet.empty in 
    let rule' = (ins,ip_pats',ip_modo,outs) in 
    (* Printf.printf "RULE\n  %s\n  %s\n\n" *)
    (*   (fr rule) (fr rule'); *)
    rule'

  let rec subst_rules subst rules = 
    List.map (subst_rule subst) rules
	
end

module Verify = 
struct
  module Node = Network_Common.Node
  module Link = Network_Common.Link 
  module Net = Network_Common.Net
  module Topology = Net.Topology
  module Path = Net.UnitPath

  module Json = Yojson.Safe

  let is_host topo v = 
    match Node.device (Topology.vertex_to_label topo v) with 
      | Node.Host -> true 
      | _ -> false  
  let is_switch topo v = 
    match Node.device (Topology.vertex_to_label topo v) with 
      | Node.Switch -> true 
      | _ -> false  

  let ite (pr,pol1) pol2 = 
    (* JNF: the first line produces true tables; the second assumes the rules are disjoint. *)
    (* NetKAT_Types.(Optimize.(mk_union (mk_seq (mk_filter pr) pol1) (mk_seq (mk_filter (mk_not pr)) pol2))) *)
    NetKAT_Types.(Optimize.(mk_union (mk_seq (mk_filter pr) pol1) pol2))

  let rules_of_stanford filename = 
    let parse_rule = function
      | `Assoc [("in_ports", `List in_ports); 
		("ip_dst_wc", ip_dst_wc); 
		("ip_dst_new", ip_dst_new);
		("out_ports", `List out_ports);
		("ip_dst_match", ip_dst_match)] -> 
	let ins = 
	  List.fold_left  
	    (fun acc inp -> 
	      match inp with 
	      | `Int n -> 
		Int32Set.add (Int32.of_int n) acc
	      | j -> 
		failwith (Printf.sprintf "bad in_port: %s" (Json.to_string j)))
	    Int32Set.empty in_ports in 
	let ip_pats = 
	  match ip_dst_match, ip_dst_wc with 
	  | `Int p, `Int m -> 
	    IPMaskSet.singleton (Int32.of_int p, Int32.of_int m)
	  | j1,j2 -> 
	    failwith (Printf.sprintf "bad ip_dst_match or ip_dst_wc: %s %s" 
			(Json.to_string j1) (Json.to_string j2)) in 
	let ip_modo = 
	  match ip_dst_new with 
	  | `Int n -> 
	    Some (Int32.of_int n)
	  | `Null -> 
	    None
	  | j -> 
	    failwith (Printf.sprintf "bad ip_dst_new: %s" (Json.to_string j)) in 
	let outs = 
	  List.fold_left  
	    (fun acc outp -> 
	      match outp with 
	      | `Int n -> 
		Int32Set.add (Int32.of_int n) acc
	      | j -> 
		failwith (Printf.sprintf "bad out_port: %s" (Json.to_string j)))
	    Int32Set.empty out_ports in 
	(ins,ip_pats,ip_modo,outs)
      | j -> 
	failwith (Printf.sprintf "bad_rule: %s" (Json.to_string j)) in 

    let parse_file = function
      | `Assoc ["rules", `List rules] -> 
	List.fold_right  
	  (fun rule acc -> (parse_rule rule) :: acc)
	  rules []
      | j -> 
	failwith (Printf.sprintf "bad file: %s" (Json.to_string j)) in 
    parse_file (Json.from_file filename)

  module S = Set.Make(struct
    type t = int32 * (int32 * int32) 
    let compare (i1,(p1,m1)) (i2,(p2,m2)) = 
      let cmp1 = compare i1 i2 in 
      if cmp1 <> 0 then cmp1
      else
	let cmp2 = compare p1 p2 in 
	if cmp2 <> 0 then cmp2 
	else compare m1 m2
  end)

  let policy_of_rule neg (ins,ip_pats,ip_modo,outs) = 
    let open NetKAT_Types in 
    let open Optimize in 
    let ins_pats,neg' = 
      IPMaskSet.fold (fun (p,m) (acc,neg') -> 	
	let pats,neg' = 
	  Int32Set.fold 
	    (fun i (acc,neg') -> 
	      let x = (i,(p,m)) in 
	      (* Printf.printf "  %ld %s %b\n" i (string_of_ip_mask (p,m)) (S.mem x neg'); *)
	      if S.mem x neg' then (acc,neg') 
	      else i::acc, S.add x neg')
	    ins ([], neg') in 
	((pats,(p,m))::acc, neg'))
	ip_pats 
	([],neg) in 
    let pr = 
      List.fold_left 
	(fun acc (ins,(p,m)) ->
	  let ins_pr = List.fold_left (fun acc i -> mk_or (Test(Location(Physical i))) acc) False ins in 
	  mk_or (mk_and ins_pr (Test(IP4Dst(p,m)))) acc)
	False ins_pats in 
    let pat = mk_filter pr in 
    let outs_pol = Int32Set.fold (fun n acc -> mk_union acc (Mod(Location(Physical n)))) outs (mk_filter False) in 	
    let ip_mod_pol = match ip_modo with Some a -> Mod(IP4Dst(a,32l)) | None -> mk_filter True in 
    let acts = mk_seq ip_mod_pol outs_pol in 
    let pol = mk_seq pat acts in 
    (* Format.printf "TRANSLATE\n  %s\n  %s\n\n"  *)
    (*   (fr rule) (NetKAT_Pretty.string_of_policy pol); *)
    (neg', pol)

  let policy_of_rules rules = 
    let open NetKAT_Types in 
    let open Optimize in 
    let _,pol = 
      List.fold_left (fun (neg,pol) rule -> 
	let neg',rule_pol = policy_of_rule neg rule in 
	(neg', mk_union rule_pol pol)) 
	(S.empty, mk_filter False) rules in 
    pol

  let convert_stanford (switches : string list) : (((string * int) list) * NetKAT_Types.policy)= 
    let open IPMasks in 
    let rules = 
      List.mapi 
	(fun i sw -> (i,sw,rules_of_stanford (sw ^ ".of")))
	switches in 
    let ips = 
      List.fold_left
	(fun acc (_,_,rs) -> 
	  IPMaskSet.union acc (ips_of_rules rs))
	IPMaskSet.empty rules in 
    let subst = 
      partition_ips ips in 
    let rules' = 
      List.map
	(fun (i,sw,rs) -> (i,sw,subst_rules subst rs))
	rules in 
    let policies = 
      List.map 
	(fun (i,sw,rs) -> 
	  let pol = policy_of_rules rs in 
	  let pr = NetKAT_Types.(Optimize.(mk_filter (Test(Switch(Int64.of_int i))))) in 
	  (i, sw, NetKAT_Types.(Optimize.(mk_seq pr pol))))
	rules' in 
    let () =
      List.iter
    	(fun (i,sw,pol) ->
    	  let fd = open_out (sw ^ ".kat") in
    	  Printf.fprintf fd "%s" (NetKAT_Pretty.string_of_policy pol);
    	  close_out fd)
    	policies in
    let assoc, policy = 
      List.fold_left
	(fun (aacc,pacc) (i,sw,pol) -> 
	  ((sw,i)::aacc, NetKAT_Types.(Optimize.(mk_union pol pacc))))
	([], NetKAT_Types.(Filter False)) 
	policies in 
    (assoc, policy)

  (* let () =  *)
  (*   let assoc, policy = convert_stanford ["foo"] in  *)
  (*   List.iter  *)
  (*     (fun (x,sw) -> Printf.printf "%d => %s\n" x sw) *)
  (*     assoc; *)
  (*   Printf.printf "%s\n" (NetKAT_Pretty.string_of_policy policy) *)
  
  let topology filename = 
    let topo = Net.Parse.from_dotfile filename in 
    let vertexes = Topology.vertexes topo in 
    let hosts = Topology.VertexSet.filter (is_host topo) vertexes in 
    let _,hosts = Topology.VertexSet.(fold (fun e (cntr,acc) -> if cntr < 25
      then (cntr + 1, add e acc)
      else (cntr,acc)) hosts (0,empty)) in 
    let switches = Topology.VertexSet.filter (is_switch topo) vertexes in 
    (topo, vertexes, switches, hosts)  

  let hosts_ports_switches topo hosts = 
    Topology.VertexSet.fold
      (fun h pol -> 
        let sw = Topology.VertexSet.choose (Topology.neighbors topo h) in 
        let _,pt = Topology.edge_dst (Topology.find_edge topo h sw) in 
        (h,pt,sw)::pol)
      hosts []

  let shortest_path_policy topo switches hosts = 
    let h = Hashtbl.create 101 in 
    let () = 
      Topology.VertexSet.iter
      (fun h1 -> 
	Topology.VertexSet.iter
	  (fun h2 -> 	    
	    match Path.shortest_path topo h1 h2 with 
	    | Some [] -> ()
	    | Some p -> Hashtbl.add h (h1,h2) p
	    | None -> ())
	  hosts)
      hosts in 
    Hashtbl.fold
      (fun (h1,h2) pi pol -> 
	let m = Node.mac (Topology.vertex_to_label topo h2) in 
	Printf.printf "DOING %s -> %s : [%s]\n" 
	  (Topology.vertex_to_string topo h1)
	  (Topology.vertex_to_string topo h2)
	  (List.fold_left 
	     (fun acc e -> 
	       Printf.sprintf "%s%s%s => %s"
		 acc 
		 (if acc = "" then "" else ";")
		 (Topology.vertex_to_string topo (fst (Topology.edge_src e)))
		 (Topology.vertex_to_string topo (fst (Topology.edge_dst e))))
	     "" pi);
	List.fold_left
	  (fun pol e -> 
	    let v,pt = Topology.edge_src e in 
	    let n = Topology.vertex_to_label topo v in 
	    match Node.device n with 
	    | Node.Switch -> 
	      let i = Node.id n in 
	      Printf.printf "Forwarding sw%Ld mac(%Ld) : %ld\n" i m pt;
              NetKAT_Types.(Optimize.(
		mk_union
		  (mk_seq 
		     (mk_filter (mk_and (Test(Switch(i))) (Test(EthDst(m)))))
		     (Mod(Location(Physical(pt)))))
		  pol))
	    | _ -> pol)	      
	  pol pi)
      h NetKAT_Types.drop

  let shortest_path_table topo switches policy = 
    Topology.VertexSet.fold
      (fun sw tbl -> 
        let i = Node.id (Topology.vertex_to_label topo sw) in                             NetKAT_Types.(Optimize.(NetKAT_LocalCompiler.(
	  mk_union 
	    (mk_seq 
	       (mk_filter(Test(Switch(i))))
	       (to_netkat (compile i policy)))
	    tbl))))
      switches NetKAT_Types.drop   

  let connectivity_policy topo hosts = 
    let hps = hosts_ports_switches topo hosts in 
    List.fold_left
      (fun (pr,pol) (h,pt,sw) -> 
        let m = Node.mac (Topology.vertex_to_label topo h) in               
        let i = Node.id (Topology.vertex_to_label topo sw) in 
        NetKAT_Types.(Optimize.(
	  (mk_or pr (mk_and (Test(Switch(i))) (Test(Location(Physical(pt))))),
           mk_union pol (mk_seq (mk_seq (mk_filter (Test(EthDst(m)))) (Mod(Switch(i)))) (Mod(Location(Physical(pt)))))))))
      NetKAT_Types.(False, drop) hps
      
  let topology_policy topo = 
    Topology.EdgeSet.fold
      (fun e tp_pol -> 
        let v1,pt1 = Topology.edge_src e in 
        let v2,pt2 = Topology.edge_dst e in 
        if is_switch topo v1 && is_switch topo v2 then 
          let n1 = Node.id (Topology.vertex_to_label topo v1) in 
          let n2 = Node.id (Topology.vertex_to_label topo v2) in 
          NetKAT_Types.(Optimize.(mk_union tp_pol (Link(n1,pt1,n2,pt2))))
        else tp_pol)
      (Topology.edges topo) NetKAT_Types.drop 

  let check_equivalent t1 t2 = 
    let module UnivMap = Decide_Util.SetMapF (Decide_Util.Field) (Decide_Util.Value) in
    let t1vals = Decide_Ast.Term.values t1 in 
    let t2vals = Decide_Ast.Term.values t2 in 
    let ret = if ((not (UnivMap.is_empty t1vals)) || (not (UnivMap.is_empty t2vals)))
      then 
	begin 
	  let univ = UnivMap.union t1vals t2vals in 
	  let univ = List.fold_left 
	    (fun u x -> UnivMap.add x Decide_Util.Value.extra_val u) univ (UnivMap.keys univ) in
	  let module UnivDescr = struct
	    let all_fields : Decide_Util.FieldSet.t = 
	      (* TODO: fix me when SSM is eliminated *)
	      List.fold_right 
		(fun f -> 
		  Decide_Util.FieldSet.add f) (UnivMap.keys univ) Decide_Util.FieldSet.empty
	    let _ = assert (Decide_Util.FieldSet.cardinal all_fields > 0 )
	    let all_values f : Decide_Util.ValueSet.t = 
	      try 
		UnivMap.Values.fold (fun v acc -> Decide_Util.ValueSet.add v acc ) (UnivMap.find_all f univ) 
		  Decide_Util.ValueSet.empty
	      with Not_found -> 
		Decide_Util.ValueSet.empty
	  end in   
	  Decide_Util.all_fields := (fun _ -> UnivDescr.all_fields);
	  Decide_Util.all_values := (fun _ -> UnivDescr.all_values);
	  Decide_Bisimulation.check_equivalent t1 t2
	end      
      else (
	Decide_Ast.Term.equal t1 t2) in 
    ret


  let sanity_check topo pol = 
    let parse str = 
      NetKAT_Parser.program NetKAT_Lexer.token (Lexing.from_string (read_file str)) in
    let topo, vertexes, switches, hosts = topology topo in 
    let parsed_pol = parse pol in 
    let edge_pol,_ = connectivity_policy topo hosts in 
    let wrap pol = NetKAT_Types.(Seq(Seq(Filter edge_pol, pol), Filter edge_pol)) in 
    let sanity_pol = NetKAT_Types.drop in 
    let tp_pol = topology_policy topo in
    let sw_pol = NetKAT_Types.(Star(Seq(parsed_pol, tp_pol))) in 
    let dl = (Dexterize.policy_to_term ~dup:true (wrap sw_pol)) in 
    let dr = Dexterize.policy_to_term ~dup:true (wrap sanity_pol) in 
(*    Printf.printf "## NetKAT Policy ##\n%s\n## Topology ##\n%s\n%!"
      "turned off for debugging" (*(NetKAT_Pretty.string_of_policy parsed_pol)*)
      (NetKAT_Pretty.string_of_policy tp_pol);
    Printf.printf "Term: %s\n " "turned off for debugging" (*(Decide_Ast.Term.to_string dl) *); *)
    let ret = (check_equivalent dl dr) in 
    Printf.printf "## Equivalent ##\n%b\n" ret; 
    ret
    
  let verify_shortest_paths ?(print=true) filename = 
    let topo, vertexes, switches, hosts = topology filename in 
    let sw_pol = shortest_path_policy topo switches hosts in 
    let edge_pol, _ = connectivity_policy topo hosts in 
    let wrap pol = NetKAT_Types.(Optimize.(mk_seq (mk_seq (mk_filter edge_pol) pol) (mk_filter edge_pol))) in 
    let sw_tbl = shortest_path_table topo switches sw_pol in 
    let tp_pol = topology_policy topo in 
    let net_sw_pol = NetKAT_Types.(Optimize.(mk_star (mk_seq sw_pol tp_pol))) in 
    let net_sw_tbl = NetKAT_Types.(Optimize.(mk_star (mk_seq sw_tbl tp_pol))) in 
    if print then Printf.printf "## NetKAT Policy ##\n%s\n## OpenFlow Table ##\n%s\n## Topology ##\n%s\n%!"
      (NetKAT_Pretty.string_of_policy sw_pol)
      (NetKAT_Pretty.string_of_policy sw_tbl)
      (NetKAT_Pretty.string_of_policy tp_pol);
    let dl = (Dexterize.policy_to_term ~dup:true (wrap net_sw_pol)) in 
    let dr = (Dexterize.policy_to_term ~dup:true (wrap net_sw_tbl)) in
    if print then Printf.printf "## Dexter Policy: ##\n%s\n##Dexter OF policy: ##\n%s\n"
      (Decide_Ast.Term.to_string dl)
      (Decide_Ast.Term.to_string dr);
    let ret = (check_equivalent dl dr) in 
    if print then Printf.printf "## Equivalent ##\n%b\n" ret;
    ret
      
  let verify_connectivity ?(print=false) filename = 
    let topo, vertexes, switches, hosts = topology filename in 
    let sw_pol = shortest_path_policy topo switches hosts in 
    let cn_pr, cn_pol = connectivity_policy topo hosts in 
    let wrap pol = NetKAT_Types.(Optimize.(mk_seq (mk_seq (mk_filter cn_pr) pol) (mk_filter cn_pr))) in 
    let tp_pol = topology_policy topo in 
    let net_sw_pol = wrap NetKAT_Types.(Optimize.(mk_seq (mk_star (mk_seq sw_pol tp_pol)) sw_pol)) in 
    let net_cn_pol = wrap NetKAT_Types.(cn_pol) in 
(*    Printf.printf "## NetKAT Policy ##\n%s\n## Connectivity Policy ##\n%s\n%!"
      (NetKAT_Pretty.string_of_policy net_sw_pol)
      (NetKAT_Pretty.string_of_policy net_cn_pol); *)
    let lhs = Dexterize.policy_to_term ~dup:false net_sw_pol in 
    let rhs = Dexterize.policy_to_term ~dup:false net_cn_pol in 
(*    Printf.printf "## Dexter NetKAT Policy ##\n%s\n## Dexter Connectivity Policy ##\n%s\n%!" 
      (Decide_Ast.Term.to_string lhs)
      (Decide_Ast.Term.to_string rhs); *)
    Printf.printf "## Equivalent ##\n%b\n"
      (check_equivalent lhs rhs)
end