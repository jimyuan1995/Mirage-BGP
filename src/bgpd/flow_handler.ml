open Bgp
open Lwt.Infix

module Make (S: Mirage_stack_lwt.V4) = struct
  module Bgp_flow = Bgp_io.Make(S)
    
  type t = {
    remote_id: Ipaddr.V4.t;
    remote_asn: int32;
    callback: Fsm.event -> unit;
    flow: Bgp_flow.t;
    stream: Bgp.t Lwt_stream.t;
    pf: Bgp.t option -> unit;
    log: (module Logs.LOG);
  }

  let rec flow_writer t = 
    Lwt_stream.get t.stream >>= function
    | None -> Bgp_flow.close t.flow
    | Some msg -> 
      let module Log = (val t.log : Logs.LOG) in

      Log.debug (fun m -> m "send message %s" (Bgp.to_string msg)
                                          );
      Bgp_flow.write t.flow msg
      >>= function
      | Error err ->
        let () = match err with
          | `Timeout -> Log.debug (fun m -> m "Timeout when write %s" 
                                      (Bgp.to_string msg))
          | `Refused -> Log.debug (fun m -> m "Refused when Write %s" 
                                      (Bgp.to_string msg))
          | `Closed -> Log.debug (fun m -> m "Connection closed when write %s." 
                                      (Bgp.to_string msg)) 
          | _ -> ()
        in
        Lwt.return_unit
      | Ok () -> flow_writer t
  ;;

  let rec flow_reader t =
    let module Log = (val t.log : Logs.LOG) in
    Bgp_flow.read t.flow >>= function 
    | Ok msg -> 
      let event = match msg with
        | Bgp.Open o -> 
          (* Open message err checking *)
          if o.version <> 4 then Fsm.Bgp_open_msg_err (Unsupported_version_number 4)
          
          (* This is not exactly what the specification indicates *)
          else if o.local_asn <> t.remote_asn then Fsm.Bgp_open_msg_err Bad_peer_as
          
          else Fsm.BGP_open o
        | Bgp.Update u -> begin
          match u.nlri with
          | [] -> 
            (* Do not perform attribute check if no route is advertised *)
            Fsm.Update_msg u
          | _ ->
            match find_aspath u.path_attrs with
            | None -> Fsm.Update_msg_err (Missing_wellknown_attribute 2)
            | Some [] -> Fsm.Update_msg_err Malformed_as_path
            | Some (hd::tl) ->
              match hd with
              | Asn_seq l -> 
                if List.hd l <> t.remote_asn then Fsm.Update_msg_err Malformed_as_path
                else Fsm.Update_msg u
              | Asn_set l ->
                if List.mem t.remote_asn l then Fsm.Update_msg_err Malformed_as_path
                else Fsm.Update_msg u
        end
        | Bgp.Notification e -> Fsm.Notif_msg e
        | Bgp.Keepalive -> Fsm.Keepalive_msg
      in
      Log.debug (fun m -> m "receive message %s" (Bgp.to_string msg));
      
      (* Spawn thread to handle the new message *)
      t.callback event;

      (* Load balancing *)
      OS.Time.sleep_ns (Duration.of_ms 1)
      >>= fun () ->

      flow_reader t
    | Error err ->
      let () = match err with
        | `Closed -> 
          Log.debug (fun m -> m "Connection closed when read.");
          t.callback Fsm.Tcp_connection_fail
        | `Refused -> 
          Log.debug (fun m -> m "Read refused.");
          t.callback Fsm.Tcp_connection_fail
        | `Timeout -> 
          Log.debug (fun m -> m "Read timeout.");
          t.callback Fsm.Tcp_connection_fail
        | `PARSE_ERROR err -> begin
          match err with
          | Bgp.Parsing_error -> 
            Log.warn (fun m -> m "Message parsing error");
            (* I don't know what the correct event for this should be. *)
            t.callback Fsm.Tcp_connection_fail
          | Bgp.Msg_fmt_error err -> begin
            Log.warn (fun m -> m "Message format error");
            match err with
            | Bgp.Parse_msg_h_err sub_err -> t.callback (Fsm.Bgp_header_err sub_err)
            | Bgp.Parse_open_msg_err sub_err -> t.callback (Fsm.Bgp_open_msg_err sub_err)
            | Bgp.Parse_update_msg_err sub_err -> t.callback (Fsm.Update_msg_err sub_err)
          end
          | Bgp.Notif_fmt_error _ -> 
            Log.err (fun m -> m "Got an notification message error");
            (* I don't know what the correct event for this should be. *)
            (* I should log this event locally *)
            t.callback Fsm.Tcp_connection_fail
        end
        | _ -> 
          Log.debug (fun m -> m "Unknown read error in flow reader");
      in
      Lwt.return_unit
  ;;

  let create remote_id remote_asn callback flow log =
    let stream, pf = Lwt_stream.create () in
    let t = { stream; pf; remote_id; remote_asn; callback; flow; log } in
    let _ = flow_writer t in
    let _ = flow_reader t in
    t
  ;;

  let stop t = t.pf None

  let write t msg = t.pf (Some msg)
end