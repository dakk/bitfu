module Header : sig
	type t = {
		hash		: Hash.t;
		version		: int32;
		prev_block	: Hash.t;
		merkle_root : Hash.t;
		timestamp	: float;
		bits		: int32;
		nonce		: int32;
		txn			: int64;	
	}
	
	val parse 		: bytes -> t
end

type t = {
	header	: Header.t;
	txs		: Tx.t list;
}

val parse		: bytes -> t
val hash		: t -> Hash.t
val serialize	: t -> bytes