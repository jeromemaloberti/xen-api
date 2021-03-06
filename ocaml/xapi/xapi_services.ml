(*
 * Copyright (C) 2011 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
(** Advertise services
 *)

module D=Debug.Debugger(struct let name="xapi" end)
open D

open Fun
open Stringext
open Pervasiveext
open Constants

let convert_driver_info x =
	let open Smint in {
		Storage_interface.Driver_info.uri = path [ _services; _SM; x.sr_driver_filename ];
		name = x.sr_driver_name;
		description = x.sr_driver_description;
		vendor = x.sr_driver_vendor;
		copyright = x.sr_driver_copyright;
		version = x.sr_driver_version;
		required_api_version = x.sr_driver_required_api_version;
		capabilities = x.sr_driver_text_capabilities;
		configuration = x.sr_driver_configuration
	}

let list_sm_drivers ~__context =
	let all = List.map (convert_driver_info ++ Sm.info_of_driver) (Sm.supported_drivers ()) in
	Storage_interface.Driver_info.rpc_of_ts all

let respond req rpc s =
	let txt = Jsonrpc.to_string rpc in
	Http_svr.headers s (Http.http_200_ok ~version:"1.0" ~keep_alive:false ());
	req.Http.Request.close <- true;
	Unixext.really_write s txt 0 (String.length txt)

(* Transmits [req] and [s] to the service listening on [path] *)
let hand_over_connection req s path =
	try
		debug "hand_over_connection %s %s to %s" (Http.string_of_method_t req.Http.Request.m) req.Http.Request.uri path;
		let control_fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
		finally
			(fun () ->
				Unix.connect control_fd (Unix.ADDR_UNIX path);
				let msg = req |> Http.Request.rpc_of_t |> Jsonrpc.to_string in
				let len = String.length msg in
				let written = Unixext.send_fd control_fd msg 0 len [] s in
				if written <> len then begin
					error "Failed to transfer fd to %s" path;
					Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
					req.Http.Request.close <- true;
					None
				end else begin
					let response = Http_client.response_of_fd control_fd in
					match response with
					| Some res -> res.Http.Response.task
					| None -> None
				end
			)
			(fun () -> Unix.close control_fd)
	with e ->
		error "Failed to transfer fd to %s: %s" path (Printexc.to_string e);
		Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
		req.Http.Request.close <- true;
		None

let post_handler (req: Http.Request.t) s _ =
	Xapi_http.with_context ~dummy:true "Querying services" req s
		(fun __context ->
			match String.split '/' req.Http.Request.uri with
				| "" :: services :: "xenops" :: _ when services = _services ->
					ignore (hand_over_connection req s "/var/xapi/xenopsd.forwarded")
				| [ ""; services; "SM" ] when services = _services ->
					Storage_impl.Local_domain_socket.xmlrpc_handler Storage_mux.Server.process req (Buf_io.of_fd s) ()
				| _ ->
					Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
					req.Http.Request.close <- true
		)


let rpc ~srcstr ~dststr call =
	let url = Http.Url.(File { path = "/var/xapi/storage" }, { uri = "/"; query_params = [] }) in
	let open Xmlrpc_client in
	XMLRPC_protocol.rpc ~transport:(transport_of_url url) ~srcstr ~dststr
		~http:(xmlrpc ~version:"1.0" ?auth:(Http.Url.auth_of url) ~query:(Http.Url.get_query_params url) (Http.Url.get_uri url)) call

module Local = Storage_interface.Client(struct let rpc = rpc ~srcstr:"xapi" ~dststr:"smapiv2" end)

let put_handler (req: Http.Request.t) s _ =
	Xapi_http.with_context ~dummy:true "Querying services" req s
		(fun __context ->
			match String.split '/' req.Http.Request.uri with
				| "" :: services :: "xenops" :: _ when services = _services ->
					ignore (hand_over_connection req s "/var/xapi/xenopsd.forwarded")
				| [ ""; services; "SM"; "data"; sr; vdi ] when services = _services ->
					let vdi, _ = Storage_access.find_vdi ~__context sr vdi in
					Import_raw_vdi.import vdi req s ()
				| [ ""; services; "SM"; "nbd"; sr; vdi; dp ] when services = _services ->
					Storage_migrate.nbd_handler req s sr vdi dp
				| _ ->
					Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
					req.Http.Request.close <- true
		)

let get_handler (req: Http.Request.t) s _ =
	Xapi_http.with_context ~dummy:true "Querying services" req s
		(fun __context ->
			debug "uri = %s" req.Http.Request.uri;
			match String.split '/' req.Http.Request.uri with
				| [ ""; services; "xenops" ] when services = _services ->
					ignore (hand_over_connection req s (Filename.concat Fhs.vardir "xenopsd.forwarded"))
				| [ ""; services; "SM"; driver ] when services = _services ->
					begin
						try
							respond req (Storage_interface.Driver_info.rpc_of_t (convert_driver_info (Sm.info_of_driver driver))) s
						with _ ->
							Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
							req.Http.Request.close <- true
					end
				| [ ""; services; "SM" ] when services = _services ->
					let rpc = list_sm_drivers ~__context in
					respond req rpc s
				| [ ""; services ] when services = _services ->
					let q = {
						Storage_interface.name = "XCP";
						vendor = "xen.org";
						version = "0.1";
						features = List.map (fun x -> path [_services; x]) [ _SM ];
					} in
					respond req (Storage_interface.rpc_of_query_result q) s
				| _ ->
					Http_svr.headers s (Http.http_404_missing ~version:"1.0" ());
					req.Http.Request.close <- true
		)

	
