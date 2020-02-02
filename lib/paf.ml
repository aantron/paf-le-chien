module Ke = Ke.Rke.Weighted

module type HTTPAF = sig
  type endpoint = Ipaddr.V4.t * int
  type flow

  val create_connection_handler
    :  ?config:Httpaf.Config.t
    -> request_handler:(endpoint -> Httpaf.Server_connection.request_handler)
    -> error_handler:(endpoint -> Httpaf.Server_connection.error_handler)
    -> endpoint
    -> flow
    -> unit Lwt.t
end

module Httpaf
    (Service : Tuyau_mirage.S)
    (Flow : Tuyau_mirage.F with type flow = Service.flow)
  : HTTPAF with type flow = Flow.flow
= struct
  type t =
    { flow : Flow.flow
    ; rd : Cstruct.t
    ; queue : (char, Bigarray.int8_unsigned_elt) Ke.t
    ; mutable closed : bool }

  type flow = Flow.flow
  type endpoint = Ipaddr.V4.t * int

  exception Recv_error of Flow.error
  exception Send_error of Flow.error
  exception Close_error of Flow.error

  open Lwt.Infix

  let blit src src_off dst dst_off len =
    let src = Cstruct.to_bigarray src in
    Bigstringaf.blit src ~src_off dst ~dst_off ~len

  let rec recv flow ~read =
    match Ke.N.peek flow.queue with
    | [] ->
      let len = min (Ke.available flow.queue) (Cstruct.len flow.rd) in
      let raw = Cstruct.sub flow.rd 0 len in
      ( Flow.recv flow.flow raw >>= function
          | Error err -> Lwt.fail (Recv_error err)
          | Ok `End_of_input ->
            let _ (* 0 *) = read Bigstringaf.empty ~off:0 ~len:0 in
            flow.closed <- true ; Lwt.return ()
          | Ok (`Input len) ->
            let _ = Ke.N.push_exn flow.queue ~blit ~length:Cstruct.len ~off:0 ~len raw in
            recv flow ~read )
    | src :: _ ->
      let len = Bigstringaf.length src in
      let shift = read src ~off:0 ~len in
      Ke.N.shift_exn flow.queue shift ;
      Lwt.return ()

  let send flow iovecs =
    if flow.closed then Lwt.return `Closed
    else
      let rec go w = function
        | [] -> Lwt.return (`Ok w)
        | { Faraday.buffer; Faraday.off; Faraday.len; } :: rest ->
          let raw = Cstruct.of_bigarray buffer ~off ~len in
          Flow.send flow.flow raw >>= function
          | Ok ws ->
            if ws = len then go (w + ws) rest
            else Lwt.return (`Ok (w + ws))
          | Error err -> Lwt.fail (Send_error err) in
      go 0 iovecs

  let close flow =
    if flow.closed
    then Lwt.return ()
    else ( flow.closed <- true
         ; Flow.close flow.flow >>= function
           | Ok () -> Lwt.return ()
           | Error err -> Lwt.fail (Close_error err) )

  let create_connection_handler ?(config= Httpaf.Config.default) ~request_handler ~error_handler =
    let connection_handler (edn : endpoint) flow =
      let module Server_connection = Httpaf.Server_connection in
      let connection =
        Server_connection.create ~config ~error_handler:(error_handler edn)
          (request_handler edn) in
      let queue, _ = Ke.create ~capacity:0x1000 Bigarray.Char in
      let flow =
        { flow; rd= Cstruct.create config.read_buffer_size; queue; closed= false; } in
      let rd_exit, notify_rd_exit = Lwt.wait () in
      let rec rd_fiber () =
        let go () = match Server_connection.next_read_operation connection with
          | `Read ->
            recv flow ~read:(Server_connection.read connection)
          | `Yield ->
            Server_connection.yield_reader connection rd_fiber ;
            Lwt.return ()
          | `Close ->
            Lwt.wakeup_later notify_rd_exit () ;
            close flow in
        Lwt.async @@ fun () ->
        Lwt.catch go (fun exn -> Server_connection.report_exn connection exn ; Lwt.return ()) in
      let wr_exit, notify_wr_exit = Lwt.wait () in
      let rec wr_fiber () =
        let rec go () = match Server_connection.next_write_operation connection with
          | `Write iovecs ->
            send flow iovecs >>= fun len ->
            Server_connection.report_write_result connection len ;
            go ()
          | `Yield ->
            Server_connection.yield_writer connection wr_fiber ;
            Lwt.return ()
          | `Close _ ->
            Lwt.wakeup_later notify_wr_exit () ;
            close flow in
        Lwt.async @@ fun () ->
        Lwt.catch go (fun exn -> Server_connection.report_exn connection exn ; Lwt.return ()) in
      rd_fiber () ;
      wr_fiber () ;
      Lwt.join [ rd_exit; wr_exit ] >>= fun () ->
      if flow.closed
      then close flow
      else Lwt.return () in
    connection_handler
end

module Make (StackV4 : Mirage_stack.V4) = struct
  open Lwt.Infix

  module TCP = Tuyau_mirage_tcp.Make(StackV4)

  let tls_endpoint, tls_protocol = Tuyau_mirage_tls.protocol_with_tls ~key:TCP.endpoint TCP.protocol
  let tls_configuration, tls_service = Tuyau_mirage_tls.service_with_tls ~key:TCP.configuration TCP.service tls_protocol

  let ( >>? ) x f = x >>= function
    | Ok x -> f x
    | Error err -> Lwt.return (Error err)

  let http ?config ~error_handler ~request_handler master =
    Tuyau_mirage.impl_of_service ~key:TCP.configuration TCP.service |> Lwt.return >>? fun (module Service) ->
    Tuyau_mirage.impl_of_protocol ~key:TCP.endpoint TCP.protocol |> Lwt.return >>? fun (module Protocol) ->
    let module Httpaf = Httpaf(Service)(Protocol) in
    let handler edn flow = Httpaf.create_connection_handler ?config ~error_handler ~request_handler edn flow in
    let rec go () =
      let open Lwt.Infix in
      Service.accept master >>= function
      | Error err -> Lwt.return (Rresult.R.error_msgf "%a" Service.pp_error err)
      | Ok flow ->
        let edn = TCP.dst flow in
        Lwt.async (fun () -> handler edn flow) ; Lwt.pause () >>= go in
    go ()

  let https ?config ~error_handler ~request_handler master =
    let open Rresult in
    Tuyau_mirage.impl_of_service ~key:tls_configuration tls_service |> Lwt.return >>? fun (module Service) ->
    Tuyau_mirage.impl_of_protocol ~key:tls_endpoint tls_protocol |> Lwt.return >>? fun (module Protocol) ->
    let module Httpaf = Httpaf(Service)(Protocol) in
    let handler edn flow = Httpaf.create_connection_handler ?config ~error_handler ~request_handler edn flow in
    let rec go () =
      let open Lwt.Infix in
      Service.accept master >>= function
      | Error err -> Lwt.return (Rresult.R.error_msgf "%a" Service.pp_error err)
      | Ok flow ->
        let edn = TCP.dst (Tuyau_mirage_tls.underlying flow) in
        Lwt.async (fun () -> handler edn flow) ; Lwt.pause () >>= go in
    go ()
end