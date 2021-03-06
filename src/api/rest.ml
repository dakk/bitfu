open Utils;;
open Bitcoinml;;
open Log;;
open Unix;;
open Blockchain;;
open Network;;
open Chain;;
open Block;;
open Block.Header;;
open Tx;;
open Tx.In;;
open Tx.Out;;
open Params;;
open Stdint;;
open Yojson.Basic.Util;;
open Yojson.Basic;;


let handle_request bc net req = 
	let reply = Helper.HTTP.reply_json req in
	let not_found () = reply 404 (`Assoc [("status", `String "error"); ("error", `String "notfound")]) in
	
	Log.debug "Api.Rest ↔" "%s" @@ List.fold_left (fun x acc -> x ^ "/" ^ acc) "" req.Helper.HTTP.uri;	

	let json_of_tx txid = 
		let rec inputs_to_jsonlist inputs = match inputs with
		| [] -> []
		| i :: inp' ->
			let utx = Storage.get_tx_output bc.storage i.out_hash (Uint32.to_int i.out_n) in
			let inj = (match utx with 
			| None -> `Assoc [ 
				("out_tx", `String (i.out_hash));
				("out_n", `Int (Uint32.to_int i.out_n))
			]
			| Some (utx) ->
				let addr = match spendable_by utx bc.params.prefixes with None -> "" | Some (a) -> a in
				`Assoc [
					("out_tx", `String (i.out_hash));
					("out_n", `Int (Uint32.to_int i.out_n));
					("address", `String addr);
					("value", `String (Int64.to_string utx.value))
				] 
			) in inj :: (inputs_to_jsonlist inp')
		in
		let rec outputs_to_jsonlist outputs = match outputs with
		| [] -> []
		| o :: out' ->
			let addr = match spendable_by o bc.params.prefixes with None -> "" | Some (a) -> a in
			let outj = `Assoc [
				("address", `String addr);
				("value", `String (Int64.to_string o.value))
			] in outj :: (outputs_to_jsonlist out')
		in
		(match Storage.get_tx bc.storage txid with 
		| None -> None
		| Some (tx) -> (
			let txheight = (match Storage.get_tx_height bc.storage txid with | None -> 0 | Some (n) -> n) in
			let txtime = (match Storage.get_headeri bc.storage (Int64.of_int txheight) with | None -> 0.0 | Some (bh) -> bh.Header.time) in
			Some (`Assoc [
				("txid", `String txid);
				("time", `Float txtime);
				("confirmations", `Int (if txheight = 0 then 0 else (Int64.to_int bc.block_height) + 1 - txheight));
				("inputs", `List (inputs_to_jsonlist tx.txin));
				("outputs", `List (outputs_to_jsonlist tx.txout))
			])
		))
	in
	let get_address addr = 
		let ad = Storage.get_address bc.storage addr in
		(`Assoc [
				("address", `String addr);
				("balance", `String (Int64.to_string ad.balance));
				("unconfirmed_balance", `String (Int64.to_string @@ Int64.zero));
				("sent", `String (Int64.to_string ad.sent));
				("received", `String (Int64.to_string ad.received));
				("txs", `String (Int64.to_string ad.txs))				
		])
	in
	
	match req.Helper.HTTP.rmethod, req.Helper.HTTP.uri, req.Helper.HTTP.body_json with

	(* Push a tx *)
	| (Helper.HTTP.POST, "tx" :: [], Some (body)) ->
		let invalid_hex () = reply 404 (`Assoc [("status", `String "error"); ("error", `String "invalidhex")]) in 
		(match body |> member "hex" |> to_string with
		| "null" -> invalid_hex ()
		| hex -> 
			try 
				let rest, txo = Tx.parse (Hash.to_bin_norev @@ String.sub hex 1 (String.length hex - 2)) in
				match txo with 
				| None -> invalid_hex ()
				| Some (tx) ->
					Chain.broadcast_tx bc tx;
					reply 200 (`Assoc [
						("status", `String "ok");
						("txid", `String (tx.hash))
					])
			with | _ -> invalid_hex ()
		)

	(* Get address info *)
	| (Helper.HTTP.GET, "address" :: addr :: [], _) ->
		reply 200 (`Assoc [
			("status", `String "ok");
			("address", get_address addr)
		])

	(* Get addresses info *)
	| (Helper.HTTP.GET, "addresses" :: addrs :: [], _) -> 
		let addrsl = Str.split (Str.regexp_string "|") addrs in
		reply 200 (`Assoc [
			("status", `String "ok");
			("addresses", `List (List.map get_address addrsl))
		])


	(* Get address txs *)
	| (Helper.HTTP.GET, "address" :: addr :: "txs" :: [], _) -> 
		let txl = Storage.get_address_txs bc.storage addr in
		let assoc = List.map (fun hash -> `String hash) txl in
		reply 200 (`Assoc [
			("status", `String "ok");
			("txs", `List assoc)
		])

	(* Get address txs with full tx *)
	| (Helper.HTTP.GET, "address" :: addr :: "txs" :: "expanded" :: [], _) -> 
	let txl = Storage.get_address_txs bc.storage addr in
	let rec txl_expand hashes acc = match hashes with
	| [] -> acc
	| hash :: hashes' -> match json_of_tx hash with
		| None -> txl_expand hashes' acc
		| Some (tx) -> txl_expand hashes' @@ acc @ [tx]
	in
	reply 200 (`Assoc [
		("status", `String "ok");
		("txs", `List (txl_expand txl []))
	])

	(* Get address utxo *)
	| (Helper.HTTP.GET, "address" :: addr :: "utxo" :: [], _) -> 
		let utxl = Storage.get_address_utxs bc.storage addr in
		let assoc = List.map (fun ut -> 
			match ut with
			| (txhash, i, value) ->
				`Assoc [ ("tx", `String txhash); ("n", `Int i); ("value", `String (Int64.to_string value)) ]
		) utxl in
		reply 200 (`Assoc [
			("status", `String "ok");
			("utxo", `List assoc)
		])

	(* Get a raw tx *)
	| (Helper.HTTP.GET, "tx" :: txid :: "raw" :: [], _) ->
		(match Storage.get_tx bc.storage txid with 
		| None -> not_found ()
		| Some (tx) -> (
			let txhex = Tx.serialize tx |> Hash.of_bin_norev in
			reply 200 (`Assoc [
					("status", `String "ok"); 
					("hex", `String txhex)
			]))
		)

	(* Get tx info *)
	| (Helper.HTTP.GET, "tx" :: txid :: [], _) -> 
		(match json_of_tx txid with
		| None -> not_found ()
		| Some (tx) ->
			reply 200 (`Assoc [
				("status", `String "ok");
				("tx", tx)
			])
		)

	(* Get block info by index *)
	| (Helper.HTTP.GET, "block" :: "i" :: bli :: [], _) -> 
		(match Storage.get_blocki bc.storage @@ Int64.of_string bli with
		| None -> not_found ()
		| Some (b) ->
			reply 200 (`Assoc [
				("status", `String "ok");
				("block", `Assoc [
					("hash", `String (b.header.hash));
					("prev_block", `String (b.header.prev_block));
					("height", `String bli);
					("time", `Float (b.header.time));
					("age", `String (Timediff.diffstring (Unix.time ()) b.header.time));
					("txs", `List (List.map (fun tx -> `String tx.Tx.hash) b.txs));
					("size", `Int (b.size))
				])
			])
		)

	(* Get block info by hash *)
	| (Helper.HTTP.GET, "block" :: bid :: [], _) -> 
		(match Storage.get_block bc.storage bid with
		| None -> not_found ()
		| Some (b) ->
			reply 200 (`Assoc [
				("status", `String "ok");
				("block", `Assoc [
					("hash", `String (b.header.hash));
					("prev_block", `String (b.header.prev_block));
					("height", `Int (Storage.get_block_height bc.storage @@ b.header.hash));
					("time", `Float (b.header.time));
					("age", `String (Timediff.diffstring (Unix.time ()) b.header.time));
					("txs", `List (List.map (fun tx -> `String tx.Tx.hash) b.txs));
					("size", `Int (b.size))
				])
			])
		)

	(* Get last blocks *)
	| (Helper.HTTP.GET, "lastblocks" :: [], _) ->
		let rec get_last_blocks height n = match n with
		| 0 -> []
		| n' -> match Storage.get_blocki bc.storage height with
			| Some (b) ->
				(`Assoc [
					("hash", `String (b.header.hash));
					("height", `Int (Int64.to_int height));
					("time", `Float (b.header.time));
					("age", `String (Timediff.diffstring (Unix.time ()) b.header.time));
					("txs", `Int (List.length b.txs));
					("size", `Int (b.size))
				])::get_last_blocks (Int64.sub height Int64.one) (n-1)
			| None -> []
		in
		reply 200 (`Assoc [
			("status", `String "ok");
			("state", `Assoc [
				("blocks", `List (get_last_blocks bc.block_height 10));
			]);
		])

	(* Get chain state *)
	| (Helper.HTTP.GET, "" :: [], _) ->
		reply 200 (`Assoc [
			("status", `String "ok");
			("state", `Assoc [
				("chain", `String (Params.name_of_network bc.params.network));
				("sync", `Bool bc.sync);
				("height", `Int (Int64.to_int bc.block_height));
				("last", `String bc.block_last.header.hash);
				("time", `String (Timediff.diffstring (Unix.time ()) bc.block_last.header.time));
				("header", `Assoc [
					("sync", `Bool bc.sync_headers);
					("height", `Int (Int64.to_int bc.header_height));
					("last", `String (bc.header_last.hash));
					("time", `String (Timediff.diffstring (Unix.time ()) bc.header_last.time));
				]);
				("network", `Assoc [
					("peers", `Int (Net.connected_peers net));
					("sent", `Int (Net.sent net));
					("received", `Int (Net.received net));
				]);
				("mempool", `Assoc [
					("size", `Int (Mempool.size bc.mempool));
					("n", `Int (Mempool.length bc.mempool));
					("fees", `Int (Int64.to_int @@ Mempool.fees bc.mempool))
				]);
				("txs", `Int (Uint64.to_int bc.storage.chainstate.txs));
				("utxos", `Int (Uint64.to_int bc.storage.chainstate.utxos))
			])
		])

	(* Not found *)
	| (_, _, _) -> 
		not_found ()
;;

type t = {
	blockchain : Chain.t;
	network 	 : Net.t;
	conf 			 : Config.rest;
	mutable run: bool;
	socket		 : Unix.file_descr;
};;

let init (rconf: Config.rest) bc net = { 
	blockchain= bc; 
	conf= rconf; 
	network= net; 
	run= rconf.enable;
	socket= socket PF_INET SOCK_STREAM 0
};;

let loop a =
	let rec do_listen socket =
		let (client_sock, _) = accept socket in		
		match Helper.HTTP.parse_request socket with
		| None -> 
			if a.run then do_listen socket
		| Some (req) -> 
			handle_request a.blockchain a.network req;
			(*close client_sock;*)
			if a.run then do_listen socket
	in
	if a.conf.enable then (
		Log.info "Api.Rest" "Binding to port: %d" a.conf.port;
		Helper.listen a.socket a.conf.port 8;
    try do_listen a.socket with _ -> ()
	) else ()
;;

let shutdown a = 
	if a.conf.enable then (
		Log.fatal "Api.Rest" "Shutdown...";
		Helper.shutdown a.socket;
		a.run <- false
	) else ()
;;