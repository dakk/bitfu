open Stdint;;
open Unix;;
open Utils;;
open Conv;;
open Message;;
open Blockchain;;
open Chain;;
open Random;;

type status = 
	| CONNECTED
	| DISCONNECTED
	| WAITPING of int64
;;

type t = {
	socket		: Unix.file_descr;
	address 	: Unix.inet_addr;
	port			: int;
	params		: Params.t;
	config		: Config.t;

	mutable received	: int;
	mutable sent		: int;

	mutable status		: status;
	mutable last_seen	: float;
	mutable height		: int32;
	mutable user_agent	: string;
};;


let rec is_readable s = match String.length s with
| 0 -> true
| n -> 
	let c = Char.code (String.get s 0) in
	if c >= Char.code 'a' && c <= Char.code 'z' then
		is_readable (String.sub s 1 (n - 1))
	else
		false  
;;


let create params conf addr port = {
	socket		= Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0; 
	address		= addr; 
	port			= port; 
	params		= params; 
	config		= conf;

	received	= 0;
	sent			= 0;

	last_seen	= Unix.time ();
	height		= Int32.of_int 0;
	user_agent	= ""; 
	status		= DISCONNECTED;
};;

let connect peer =
	Log.debug "Peer" "Connecting to peer %s:%d..." (Unix.string_of_inet_addr peer.address) peer.port;
	try
		Unix.connect peer.socket (ADDR_INET (peer.address, peer.port));
		Log.debug "Peer" "Connected to peer %s:%d" (Unix.string_of_inet_addr peer.address) peer.port;
		peer.status <- CONNECTED; CONNECTED					
	with
		| _ -> 
			peer.status <- DISCONNECTED; 
			Log.error "Peer" "Failed to connect to peer %s:%d." (Unix.string_of_inet_addr peer.address) peer.port;
			DISCONNECTED
;;


let disconnect peer = 
	Log.debug "Peer" "Disconnecting peer %s:%d..." (Unix.string_of_inet_addr peer.address) peer.port;
	peer.status <- DISCONNECTED;
	try ( Unix.shutdown peer.socket Unix.SHUTDOWN_ALL ) with | _ -> ()
;;

let send peer message = 
	try (
		let data = Message.serialize peer.params message in
		let wl = Unix.send peer.socket data 0 (Bytes.length data) [] in
		if peer.config.log_peer then 
			Log.debug "Peer →" "%s: %s (s: %s, r: %s)" (Unix.string_of_inet_addr peer.address) 
				(string_of_command message) (byten_to_string peer.sent) (byten_to_string peer.received);
		peer.sent <- peer.sent + wl;
	) with
	| _ -> disconnect peer; Log.error "Peer →" "Broken pipe"; ()
;;


let recv peer = 
	let rec recv_chunks bsize acc zerol = match bsize with
	| bsize when Uint32.compare bsize (Uint32.zero) < 0 -> None
	| bsize when Uint32.compare bsize (Uint32.zero) = 0 -> 
		let res = Buffer.to_bytes acc in
		Buffer.clear acc; Some (res)
	| bsize ->
		let csize = if bsize >= (Uint32.of_int 0xFFFF) then 0xFFFF else Uint32.to_int bsize in
		let rdata = Bytes.create csize in
		let rl = Unix.read peer.socket rdata 0 csize in
		match rl, zerol with
		| rl, zerol when rl < 0 -> disconnect peer; None
		| rl, zerol when rl = 0 && zerol = 5 -> None
		| rl, zerol when rl = 0 && zerol < 5 -> 
			Thread.wait_timed_read peer.socket 0.1 |> ignore;
			recv_chunks bsize acc (zerol+1)
		| rl, zerol when rl > 0 -> (
			Buffer.add_bytes acc (Bytes.sub_string rdata 0 rl);
			recv_chunks (Uint32.sub bsize (Uint32.of_int rl)) acc 0
		)
		| _ -> None
	in
	(* Read and parse the header*)
	let data = Bytes.create 24 in

	try (
		match Unix.recv peer.socket data 0 24 [] with
		| rl when rl < 0 -> disconnect peer; None
		| rl when rl = 0 ->	None
		| rl when rl > 0 -> (
			let m = Message.parse_header data in
						
			(* Read and parse the message*)
			peer.received <- peer.received + 24;

			match recv_chunks m.length (Buffer.create 4096) 0 with
				| None -> None
				| Some (rdata) -> (
					peer.received <- peer.received + String.length rdata;
					let m' = Message.parse m rdata in 

					if peer.config.log_peer then 
						Log.debug "Peer ←" "%s: %s (s: %s, r: %s)" (Unix.string_of_inet_addr peer.address) 
							m.command (byten_to_string peer.sent) (byten_to_string peer.received);
					
					Some (m')
				)
		)
		| _ -> None
	) with 
	| _ -> 
		(*Log.error "Peer ↚" "Invalid message from %s" (Unix.string_of_inet_addr peer.address);*)
		None
;;



let handshake peer =
	let verm = {
		version		= Int32.of_int peer.params.version;
		services	= peer.params.services;
		time		= Unix.time ();
		addr_recv	= { address="0000000000000000" ; services=(Uint64.of_int 1) ; port= Uint16.of_int 8333 };
		addr_from	= { address="0000000000000000" ; services=(Uint64.of_int 1) ; port= Uint16.of_int 8333 };
		nonce		= Random.int64 0xFFFFFFFFFFFFFFFL;
		user_agent	= "/letchain:0.13.1/";
		start_height= Int32.of_int 0;
		relay		= true;
	} in send peer (Message.VERSION (verm))
;;




let handle peer bc = match recv peer with
| None -> ()
| Some (m') -> (
	peer.last_seen <- Unix.time ();
	match m' with 
	| PONG (p) -> peer.status <- CONNECTED;
	| PING (p) -> send peer (PONG (p));
	| VERSION (v) ->
		peer.height <- v.start_height;
		peer.user_agent <- v.user_agent;
		send peer VERACK;
		Log.info "Network" "Peer %s with agent %s starting from height %d" 
			(Unix.string_of_inet_addr peer.address) (peer.user_agent) (Int32.to_int peer.height);
	| BLOCK (b) -> 
		Cqueue.add bc.resources @@ Chain.QueueMessage.RES_BLOCK (b)
	| HEADERS (hl) ->
		Cqueue.add bc.resources (Chain.Resource.RES_HBLOCKS (hl));
	| GETHEADERS (hl) ->
		Cqueue.add bc.resources (Chain.Resource.REQ_HBLOCKS (hl.hashes, hl.stop, peer.address))
	| INV (i) ->
		let rec vis h = match h with
		| x::xl ->
			let _ = (match x with
				| INV_TX (txid) -> 
					(*Log.info "Network" "Got inv tx %s" txid;*)
					Cqueue.add bc.resources (Chain.QueueMessage.RES_INV_TX (txid, peer.address));
				| INV_BLOCK (bhash) -> 
					(*Log.info "Network" "Got inv block %s" bhash;*)
					Cqueue.add bc.resources (Chain.QueueMessage.RES_INV_BLOCK (bhash, peer.address));
				| _ -> ()
			) in vis xl  
		| [] -> ()
		in 
		if bc.sync then vis i else ();
	| _ -> ()
);;

let start peer bc = 
	Sys.set_signal Sys.sigpipe Sys.Signal_ignore;

	match connect peer with 
	| DISCONNECTED -> Thread.exit ()
	| _ -> (
		handshake peer;
		
		let rec loop () = (match peer.status with
		| CONNECTED ->		
			let toread = Thread.wait_timed_read peer.socket 2.0 in
			(if toread then handle peer bc);
			loop ()
		| _ -> Thread.exit ())
		in loop ()
	);
;;