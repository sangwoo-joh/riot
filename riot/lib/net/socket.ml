open Runtime
open Net
include Socket

module Logger = Logger.Make (struct
  let namespace = [ "riot"; "net"; "socket" ]
end)

type listen_opts = {
  reuse_addr : bool;
  reuse_port : bool;
  backlog : int;
  addr : Addr.tcp_addr;
}

type timeout = Infinity | Bounded of float
type unix_error = [ `Unix_error of Unix.error ]
type ('ok, 'err) result = ('ok, ([> unix_error ] as 'err)) Stdlib.result

let default_listen_opts =
  { reuse_addr = true; reuse_port = true; backlog = 128; addr = Addr.loopback }

let close socket =
  let pool = Scheduler.Pool.get_pool () in
  let this = self () in
  Logger.trace (fun f ->
      f "Process %a: Closing socket fd=%a" Pid.pp this Fd.pp socket);
  Io.close pool.io_scheduler.io_tbl socket

let listen ?(opts = default_listen_opts) ~port () =
  let pool = Scheduler.Pool.get_pool () in
  let { reuse_addr; reuse_port; backlog; addr } = opts in
  let addr = Addr.tcp addr port in
  Logger.trace (fun f -> f "Listening on 0.0.0.0:%d" port);
  Io.listen pool.io_scheduler.io_tbl ~reuse_port ~reuse_addr ~backlog addr

let rec connect addr =
  let pool = Scheduler.Pool.get_pool () in
  Logger.debug (fun f -> f "Connecting to %a" Addr.pp addr);
  match Io.connect pool.io_scheduler.io_tbl addr with
  | `Connected fd -> connected addr fd
  | `In_progress fd -> in_progress addr fd
  | `Abort reason -> Error (`Unix_error reason)
  | `Retry ->
      yield ();
      connect addr

and in_progress addr fd = syscall "connect" `w fd @@ connected addr

and connected addr fd =
  Logger.debug (fun f -> f "Connecting to %a via %a" Addr.pp addr Socket.pp fd);
  Ok fd

let rec accept ?(timeout = Infinity) (socket : Socket.listen_socket) =
  let pool = Scheduler.Pool.get_pool () in
  Log.debug (fun f -> f "Socket is Accepting client at fd=%a" Fd.pp socket);
  match Io.accept pool.io_scheduler.io_tbl socket with
  | exception Fd.(Already_closed _) -> Error `Closed
  | `Abort reason -> Error (`Unix_error reason)
  | `Retry -> syscall "accept" `r socket @@ accept ~timeout
  | `Connected (conn, addr) -> Ok (conn, addr)

let controlling_process _socket ~new_owner:_ = Ok ()

let rec receive ?(timeout = Infinity) ~buf socket =
  let bytes = Bytes.create (Bigstringaf.length buf) in
  match Io.read socket bytes 0 (Bytes.length bytes - 1) with
  | exception Fd.(Already_closed _) -> Error `Closed
  | `Abort reason -> Error (`Unix_error reason)
  | `Retry -> syscall "receive" `r socket @@ receive ~timeout ~buf
  | `Read 0 -> Error `Closed
  | `Read len ->
      Bigstringaf.blit_from_bytes bytes ~src_off:0 buf ~dst_off:0 ~len;
      Ok len

let rec send ~data socket =
  Logger.debug (fun f -> f "sending: %S" (Bigstringaf.to_string data));
  let off = 0 in
  let len = Bigstringaf.length data in
  let bytes = Bytes.create len in
  Bigstringaf.blit_to_bytes data ~src_off:off bytes ~dst_off:0 ~len;
  match Io.write socket bytes off len with
  | exception Fd.(Already_closed _) -> Error `Closed
  | `Abort reason -> Error (`Unix_error reason)
  | `Retry ->
      Logger.debug (fun f -> f "retrying");
      syscall "send" `w socket @@ send ~data
  | `Wrote bytes ->
      Logger.debug (fun f -> f "sent: %S" (Bigstringaf.to_string data));
      Ok bytes

let pp_err fmt = function
  | `Timeout -> Format.fprintf fmt "Timeout"
  | `System_limit -> Format.fprintf fmt "System_limit"
  | `Closed -> Format.fprintf fmt "Closed"
  | `Unix_error err ->
      Format.fprintf fmt "Unix_error(%s)" (Unix.error_message err)