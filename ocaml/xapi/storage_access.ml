(*
 * Copyright (C) 2006-2011 Citrix Systems Inc.
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
open Threadext
open Stringext
module XenAPI = Client.Client
open Fun
open Storage_interface

module D=Debug.Debugger(struct let name="storage_access" end)
open D

exception No_VDI

(* Find a VDI given a storage-layer SR and VDI *)
let find_vdi ~__context sr vdi =
	let open Db_filter_types in
	let sr = Db.SR.get_by_uuid ~__context ~uuid:sr in
	match Db.VDI.get_records_where ~__context ~expr:(And((Eq (Field "location", Literal vdi)),Eq (Field "SR", Literal (Ref.string_of sr)))) with
		| x :: _ -> x
		| _ -> raise No_VDI

(* Find a VDI reference given a name *)
let find_content ~__context ?sr name =
	(* PR-1255: the backend should do this for us *)
	let open Db_filter_types in
	let expr = Opt.default True (Opt.map (fun sr -> Eq(Field "SR", Literal (Ref.string_of (Db.SR.get_by_uuid ~__context ~uuid:sr)))) sr) in
	let all = Db.VDI.get_records_where ~__context ~expr in
	List.find
		(fun (_, vdi_rec) ->
			false
			|| (vdi_rec.API.vDI_location = name) (* PR-1255 *)
			|| (List.mem_assoc "content_id" vdi_rec.API.vDI_other_config && (List.assoc "content_id" vdi_rec.API.vDI_other_config = name))
		) all

let redirect sr =
	raise (Redirect (Some (Pool_role.get_master_address ())))

module Builtin_impl = struct
	(** xapi's builtin ability to call local SM plugins using the existing
	    protocol. The code here should only call the SM functions and encapsulate
	    the return or error properly. It should not perform side-effects on
	    the xapi database: these should be handled in the layer above so they
	    can be shared with other SM implementation types.

	    Where this layer has to perform interface adjustments (see VDI.activate
	    and the read/write debacle), this highlights desirable improvements to
	    the backend interface.
	*)

	type context = Smint.request

    let query context () = {
        name = "SMAPIv1 adapter";
        vendor = "XCP";
        version = "0.1";
        features = [];
    }

	module DP = struct
		let create context ~dbg ~id = assert false
		let destroy context ~dbg ~dp = assert false
		let diagnostics context () = assert false
		let attach_info context ~dbg ~sr ~vdi ~dp = assert false
	end

	module SR = struct
		let attach context ~dbg ~sr ~device_config =
			Server_helpers.exec_with_new_task "SR.attach" ~subtask_of:(Ref.of_string dbg)
				(fun __context ->
					let sr = Db.SR.get_by_uuid ~__context ~uuid:sr in

					(* Existing backends expect an SRMaster flag to be added
					   through the device-config. *)
					let srmaster = Helpers.i_am_srmaster ~__context ~sr in
					let device_config = (Sm.sm_master srmaster) :: device_config in
					Sm.call_sm_functions ~__context ~sR:sr
						(fun _ _type ->
							try
								Sm.sr_attach (Some (Context.get_task_id __context), device_config) _type sr
							with
								| Api_errors.Server_error(code, params) ->
									raise (Backend_error(code, params))
								| e ->
									let e' = ExnHelper.string_of_exn e in
									error "SR.attach failed SR:%s error:%s" (Ref.string_of sr) e';
									raise e
						)
				)
		let detach context ~dbg ~sr =
			Server_helpers.exec_with_new_task "SR.detach" ~subtask_of:(Ref.of_string dbg)
				(fun __context ->
					let sr = Db.SR.get_by_uuid ~__context ~uuid:sr in

					Sm.call_sm_functions ~__context ~sR:sr
						(fun device_config _type ->
							try
								Sm.sr_detach device_config _type sr
							with
								| Api_errors.Server_error(code, params) ->
									raise (Backend_error(code, params))
								| e ->
									let e' = ExnHelper.string_of_exn e in
									error "SR.detach failed SR:%s error:%s" (Ref.string_of sr) e';
									raise e
						)
				)

		let reset context ~dbg ~sr = assert false

		let destroy context ~dbg ~sr = 
			Server_helpers.exec_with_new_task "SR.destroy" ~subtask_of:(Ref.of_string dbg)
				(fun __context ->
					let sr = Db.SR.get_by_uuid ~__context ~uuid:sr in

					Sm.call_sm_functions ~__context ~sR:sr
						(fun device_config _type ->
							try
								Sm.sr_delete device_config _type sr
							with
								| Smint.Not_implemented_in_backend ->
									raise (Storage_interface.Backend_error(Api_errors.sr_operation_not_supported, [ Ref.string_of sr ]))
								| Api_errors.Server_error(code, params) ->
									raise (Backend_error(code, params))
								| e ->
									let e' = ExnHelper.string_of_exn e in
									error "SR.detach failed SR:%s error:%s" (Ref.string_of sr) e';
									raise e
						)
				)

		let vdi_info_of_vdi_rec __context sr vdi_rec =
			let content_id =
				if List.mem_assoc "content_id" vdi_rec.API.vDI_other_config
				then List.assoc "content_id" vdi_rec.API.vDI_other_config
				else vdi_rec.API.vDI_location (* PR-1255 *)
			in {
				vdi = vdi_rec.API.vDI_location;
				sr = sr;
				content_id = content_id; (* PR-1255 *)
				name_label = vdi_rec.API.vDI_name_label;
				name_description = vdi_rec.API.vDI_name_description;
				ty = Record_util.vdi_type_to_string vdi_rec.API.vDI_type;
				metadata_of_pool = Ref.string_of vdi_rec.API.vDI_metadata_of_pool;
				is_a_snapshot = vdi_rec.API.vDI_is_a_snapshot;
				snapshot_time = Date.to_string vdi_rec.API.vDI_snapshot_time;
				snapshot_of = Ref.string_of vdi_rec.API.vDI_snapshot_of;
				read_only = vdi_rec.API.vDI_read_only;
				virtual_size = vdi_rec.API.vDI_virtual_size;
				physical_utilisation = vdi_rec.API.vDI_physical_utilisation;
			}

		let scan context ~dbg ~sr:sr' =
			Server_helpers.exec_with_new_task "SR.scan" ~subtask_of:(Ref.of_string dbg)
				(fun __context ->
					let sr = Db.SR.get_by_uuid ~__context ~uuid:sr' in
					Sm.call_sm_functions ~__context ~sR:sr
						(fun device_config _type ->
							try
								Sm.sr_scan device_config _type sr;
								let open Db_filter_types in
								let vdis = Db.VDI.get_records_where ~__context ~expr:(Eq(Field "SR", Literal (Ref.string_of sr))) |> List.map snd in
								List.map (vdi_info_of_vdi_rec __context sr') vdis
							with
								| Smint.Not_implemented_in_backend ->
									raise (Storage_interface.Backend_error(Api_errors.sr_operation_not_supported, [ Ref.string_of sr ]))
								| Api_errors.Server_error(code, params) ->
									error "SR.scan failed SR:%s code=%s params=[%s]" (Ref.string_of sr) code (String.concat "; " params);
									raise (Backend_error(code, params))
								| Sm.MasterOnly -> redirect sr
								| e ->
									let e' = ExnHelper.string_of_exn e in
									error "SR.scan failed SR:%s error:%s" (Ref.string_of sr) e';
									raise e
						)
				)


		let list context ~dbg = assert false

	end

	module VDI = struct
		let for_vdi ~dbg ~sr ~vdi op_name f =
			Server_helpers.exec_with_new_task op_name ~subtask_of:(Ref.of_string dbg)
				(fun __context ->
					let open Db_filter_types in
					let self = find_vdi ~__context sr vdi |> fst in
					Sm.call_sm_vdi_functions ~__context ~vdi:self
						(fun device_config _type sr ->
							f device_config _type sr self
						)
				)
		(* Allow us to remember whether a VDI is attached read/only or read/write.
		   If this is meaningful to the backend then this should be recorded there! *)
		let vdi_read_write = Hashtbl.create 10
		let vdi_read_write_m = Mutex.create ()


		let attach context ~dbg ~dp ~sr ~vdi ~read_write =
			try
				let attach_info_v1 =
					for_vdi ~dbg ~sr ~vdi "VDI.attach"
						(fun device_config _type sr self ->
							Sm.vdi_attach device_config _type sr self read_write
						) in
				let attach_info =
					{ params = attach_info_v1.Smint.params;
					  xenstore_data = attach_info_v1.Smint.xenstore_data; }
				in
				Mutex.execute vdi_read_write_m
					(fun () -> Hashtbl.replace vdi_read_write (sr, vdi) read_write);
				attach_info
			with Api_errors.Server_error(code, params) ->
				raise (Backend_error(code, params))

		let activate context ~dbg ~dp ~sr ~vdi =
			try
				let read_write = Mutex.execute vdi_read_write_m
					(fun () -> 
						if not (Hashtbl.mem vdi_read_write (sr, vdi)) then error "VDI.activate: doesn't know if sr:%s vdi:%s is RO or RW" sr vdi;
						Hashtbl.find vdi_read_write (sr, vdi)) in
				for_vdi ~dbg ~sr ~vdi "VDI.activate"
					(fun device_config _type sr self ->
						Server_helpers.exec_with_new_task "VDI.activate" ~subtask_of:(Ref.of_string dbg)
							(fun __context ->
								(if read_write 
								then Db.VDI.remove_from_other_config ~__context ~self ~key:"content_id"));
						(* If the backend doesn't advertise the capability then do nothing *)
						if List.mem Smint.Vdi_activate (Sm.capabilities_of_driver _type)
						then Sm.vdi_activate device_config _type sr self read_write
						else info "%s sr:%s does not support vdi_activate: doing nothing" dp (Ref.string_of sr)
					)
			with Api_errors.Server_error(code, params) ->
				raise (Backend_error(code, params))

		let deactivate context ~dbg ~dp ~sr ~vdi =
			try
				for_vdi ~dbg ~sr ~vdi "VDI.deactivate"
					(fun device_config _type sr self ->
						Server_helpers.exec_with_new_task "VDI.activate" ~subtask_of:(Ref.of_string dbg)
							(fun __context ->
								let other_config = Db.VDI.get_other_config ~__context ~self in
								if not (List.mem_assoc "content_id" other_config)
								then Db.VDI.add_to_other_config ~__context ~self ~key:"content_id" ~value:(Uuid.string_of_uuid (Uuid.make_uuid ())));
						(* If the backend doesn't advertise the capability then do nothing *)
						if List.mem Smint.Vdi_activate (Sm.capabilities_of_driver _type)
						then Sm.vdi_deactivate device_config _type sr self
						else info "%s sr:%s does not support vdi_activate: doing nothing" dp (Ref.string_of sr)
					)
			with Api_errors.Server_error(code, params) ->
				raise (Backend_error(code, params))

		let detach context ~dbg ~dp ~sr ~vdi =
			try
				for_vdi ~dbg ~sr ~vdi "VDI.detach"
					(fun device_config _type sr self ->
						Sm.vdi_detach device_config _type sr self
					);
				Mutex.execute vdi_read_write_m
					(fun () -> Hashtbl.remove vdi_read_write (sr, vdi))
			with Api_errors.Server_error(code, params) ->
				raise (Backend_error(code, params))

		let stat context ~dbg ~sr ~vdi () = assert false

        let require_uuid vdi_info =
            match vdi_info.Smint.vdi_info_uuid with
                | Some uuid -> uuid
                | None -> failwith "SM backend failed to return <uuid> field"

		let vdi_info_from_db ~__context self =
            let r = Db.VDI.get_record ~__context ~self in
            {
                vdi = r.API.vDI_location;
				sr = Db.SR.get_uuid ~__context ~self:r.API.vDI_SR;
				content_id = r.API.vDI_location; (* PR-1255 *)
                name_label = r.API.vDI_name_label;
                name_description = r.API.vDI_name_description;
                ty = Record_util.vdi_type_to_string r.API.vDI_type;
				metadata_of_pool = Ref.string_of r.API.vDI_metadata_of_pool;
                is_a_snapshot = r.API.vDI_is_a_snapshot;
                snapshot_time = Date.to_string r.API.vDI_snapshot_time;
                snapshot_of = Ref.string_of r.API.vDI_snapshot_of;
                read_only = r.API.vDI_read_only;
                virtual_size = r.API.vDI_virtual_size;
                physical_utilisation = r.API.vDI_physical_utilisation;
            }

        let newvdi ~__context vi =
            (* The current backends stash data directly in the db *)
            let uuid = require_uuid vi in
            vdi_info_from_db ~__context (Db.VDI.get_by_uuid ~__context ~uuid)

        let create context ~dbg ~sr ~vdi_info ~params =
            try
                Server_helpers.exec_with_new_task "VDI.create" ~subtask_of:(Ref.of_string dbg)
                    (fun __context ->
                        let sr = Db.SR.get_by_uuid ~__context ~uuid:sr in
                        let vi =
                            Sm.call_sm_functions ~__context ~sR:sr
                                (fun device_config _type ->
                                    Sm.vdi_create device_config _type sr params vdi_info.ty
                                        vdi_info.virtual_size vdi_info.name_label vdi_info.name_description
										vdi_info.metadata_of_pool vdi_info.is_a_snapshot
										vdi_info.snapshot_time vdi_info.snapshot_of vdi_info.read_only
                                ) in
                        newvdi ~__context vi
                    )
            with
				| Api_errors.Server_error(code, params) -> raise (Backend_error(code, params))
				| Sm.MasterOnly -> redirect sr

		let snapshot_and_clone call_name call_f context ~dbg ~sr ~vdi ~vdi_info ~params =
			try
				Server_helpers.exec_with_new_task call_name ~subtask_of:(Ref.of_string dbg)
					(fun __context ->
						let vi = for_vdi ~dbg ~sr ~vdi call_name
							(fun device_config _type sr self ->
								call_f device_config _type params sr self
							) in
						(* PR-1255: modify clone, snapshot to take the same parameters as create? *)
						let self, _ = find_vdi ~__context sr vi.Smint.vdi_info_location in
						let clonee, _ = find_vdi ~__context sr vdi in
						let content_id = 
							try 
								List.assoc "content_id" 
									(Db.VDI.get_other_config ~__context ~self:clonee)
							with _ ->
								Uuid.string_of_uuid (Uuid.make_uuid ())
						in
						Db.VDI.set_name_label ~__context ~self ~value:vdi_info.name_label;
						Db.VDI.set_name_description ~__context ~self ~value:vdi_info.name_description;
						Db.VDI.remove_from_other_config ~__context ~self ~key:"content_id";
						Db.VDI.add_to_other_config ~__context ~self ~key:"content_id" ~value:content_id;
						for_vdi ~dbg ~sr ~vdi:vi.Smint.vdi_info_location "VDI.update"
							(fun device_config _type sr self ->
								Sm.vdi_update device_config _type sr self
							);
						vdi_info_from_db ~__context self
					)
            with 
				| Api_errors.Server_error(code, params) ->
					raise (Backend_error(code, params))
				| Smint.Not_implemented_in_backend ->
					raise Unimplemented
				| Sm.MasterOnly -> redirect sr


		let snapshot = snapshot_and_clone "VDI.snapshot" Sm.vdi_snapshot
		let clone = snapshot_and_clone "VDI.clone" Sm.vdi_clone

        let destroy context ~dbg ~sr ~vdi =
            try
                for_vdi ~dbg ~sr ~vdi "VDI.destroy"
                    (fun device_config _type sr self ->
                        Sm.vdi_delete device_config _type sr self
                    );
                Mutex.execute vdi_read_write_m
                    (fun () -> Hashtbl.remove vdi_read_write (sr, vdi))
            with 
				| Api_errors.Server_error(code, params) ->
					raise (Backend_error(code, params))
				| No_VDI ->
					raise Vdi_does_not_exist
				| Sm.MasterOnly -> redirect sr

		let get_by_name context ~dbg ~sr ~name =
			info "VDI.get_by_name dbg:%s sr:%s name:%s" dbg sr name;
			(* PR-1255: the backend should do this for us *)
			 Server_helpers.exec_with_new_task "VDI.get_by_name" ~subtask_of:(Ref.of_string dbg)
                (fun __context ->
					(* PR-1255: the backend should do this for us *)
					try
						let _, vdi = find_content ~__context ~sr name in
						let vi = SR.vdi_info_of_vdi_rec __context sr vdi in
						debug "VDI.get_by_name returning successfully";
						vi
					with e ->
						error "VDI.get_by_name caught: %s" (Printexc.to_string e);
						raise Vdi_does_not_exist
				)

		let set_content_id context ~dbg ~sr ~vdi ~content_id =
			info "VDI.get_by_content dbg:%s sr:%s vdi:%s content_id:%s" dbg sr vdi content_id;
			(* PR-1255: the backend should do this for us *)
			 Server_helpers.exec_with_new_task "VDI.set_content_id" ~subtask_of:(Ref.of_string dbg)
                (fun __context ->
					let vdi, _ = find_vdi ~__context sr vdi in
					Db.VDI.remove_from_other_config ~__context ~self:vdi ~key:"content_id";
					Db.VDI.add_to_other_config ~__context ~self:vdi ~key:"content_id" ~value:content_id
				)

		let similar_content context ~dbg ~sr ~vdi =
			info "VDI.similar_content dbg:%s sr:%s vdi:%s" dbg sr vdi;
            Server_helpers.exec_with_new_task "VDI.similar_content" ~subtask_of:(Ref.of_string dbg)
                (fun __context ->
					(* PR-1255: the backend should do this for us. *)
					let sr_ref = Db.SR.get_by_uuid ~__context ~uuid:sr in
					(* Return a nearest-first list of similar VDIs. "near" should mean
					   "has similar blocks" but we approximate this with distance in the tree *)
					let module StringMap = Map.Make(struct type t = string let compare = compare end) in
					let _vhdparent = "vhd-parent" in
					let open Db_filter_types in
					let all = Db.VDI.get_records_where ~__context ~expr:(Eq (Field "SR", Literal (Ref.string_of sr_ref))) in
					let locations = List.fold_left
						(fun acc (_, vdi_rec) -> StringMap.add vdi_rec.API.vDI_location vdi_rec acc)
						StringMap.empty all in
					(* Compute a map of parent location -> children locations *)
					let children, parents = List.fold_left
						(fun (children, parents) (vdi_r, vdi_rec) ->
							if List.mem_assoc _vhdparent vdi_rec.API.vDI_sm_config then begin
								let me = vdi_rec.API.vDI_location in
								let parent = List.assoc _vhdparent vdi_rec.API.vDI_sm_config in
								let other_children = if StringMap.mem parent children then StringMap.find parent children else [] in
								(StringMap.add parent (me :: other_children) children),
								(StringMap.add me parent parents)
							end else (children, parents)) (StringMap.empty, StringMap.empty) all in

					let rec explore current_distance acc vdi =
						(* add me *)
						let acc = StringMap.add vdi current_distance acc in
						(* add the parent *)
						let parent = if StringMap.mem vdi parents then [ StringMap.find vdi parents ] else [] in
						let children = if StringMap.mem vdi children then StringMap.find vdi children else [] in
						List.fold_left
							(fun acc vdi ->
								if not(StringMap.mem vdi acc)
								then explore (current_distance + 1) acc vdi
								else acc) acc (parent @ children) in
					let module IntMap = Map.Make(struct type t = int let compare = compare end) in
					let invert map =
						StringMap.fold
							(fun vdi n acc ->
								let current = if IntMap.mem n acc then IntMap.find n acc else [] in
								IntMap.add n (vdi :: current) acc
							) map IntMap.empty in
					let _, vdi_rec = find_vdi ~__context sr vdi in
					let vdis = explore 0 StringMap.empty vdi_rec.API.vDI_location |> invert |> IntMap.bindings |> List.map snd |> List.concat in
					let vdi_recs = List.map (fun l -> StringMap.find l locations) vdis in
					List.map (fun x -> SR.vdi_info_of_vdi_rec __context sr x) vdi_recs
				)

		let compose context ~dbg ~sr ~vdi1 ~vdi2 =
			info "VDI.compose dbg:%s sr:%s vdi1:%s vdi2:%s" dbg sr vdi1 vdi2;
			try
				Server_helpers.exec_with_new_task "VDI.compose" ~subtask_of:(Ref.of_string dbg)
					(fun __context ->
						(* This call 'operates' on vdi2 *)
						let vdi1 = find_vdi ~__context sr vdi1 |> fst in
						for_vdi ~dbg ~sr ~vdi:vdi2 "VDI.activate"
							(fun device_config _type sr self ->
								Sm.vdi_compose device_config _type sr vdi1 self
							)
					)
            with
				| Smint.Not_implemented_in_backend ->
					raise Unimplemented
				| Api_errors.Server_error(code, params) ->
					raise (Backend_error(code, params))
				| No_VDI ->
					raise Vdi_does_not_exist
				| Sm.MasterOnly -> redirect sr

		let get_url context ~dbg ~sr ~vdi =
			info "VDI.get_url dbg:%s sr:%s vdi:%s" dbg sr vdi;
			(* XXX: PR-1255: tapdisk shouldn't hardcode xapi urls *)
			(* peer_ip/session_ref/vdi_ref *)
			Server_helpers.exec_with_new_task "VDI.compose" ~subtask_of:(Ref.of_string dbg)
				(fun __context ->
					let ip = Helpers.get_management_ip_addr () |> Opt.unbox in
					let rpc = Helpers.make_rpc ~__context in
					let localhost = Helpers.get_localhost ~__context in
					(* XXX: leaked *)
					let session_ref = XenAPI.Session.slave_login rpc localhost !Xapi_globs.pool_secret in
					let vdi, _ = find_vdi ~__context sr vdi in
					Printf.sprintf "%s/%s/%s" ip (Ref.string_of session_ref) (Ref.string_of vdi))

	end

	let get_by_name context ~dbg ~name = assert false

	module DATA = struct
		let copy_into context ~dbg ~sr ~vdi ~url ~dest = assert false
		let copy context ~dbg ~sr ~vdi ~dp ~url ~dest = assert false
		module MIRROR = struct
			let start context ~dbg ~sr ~vdi ~dp ~url ~dest = assert false
			let stop context ~dbg ~id = assert false
			let list context ~dbg = assert false
			let stat context ~dbg ~id = assert false
			let receive_start context ~dbg ~sr ~vdi_info ~id ~similar = assert false
			let receive_finalize context ~dbg ~id = assert false
			let receive_cancel context ~dbg ~id = assert false
		end
	end

	module TASK = struct
		let stat context ~dbg ~task = assert false
		let destroy context ~dbg ~task = assert false
		let cancel context ~dbg ~task = assert false
		let list context ~dbg = assert false
	end

	module UPDATES = struct
		let get context ~dbg ~from ~timeout = assert false
	end
end

module Qemu_blkfront = struct
	(** If the qemu is in a different domain to the storage backend, a blkfront is
		needed to exposes disks to guests so the emulated interfaces work. *)

	let get_qemu_vm ~__context ~vm = Helpers.get_domain_zero ~__context

	let needed ~__context ~self hvm =
		not(Db.VBD.get_empty ~__context ~self) && begin
            let userdevice = Db.VBD.get_userdevice ~__context ~self in
            let device_number = Device_number.of_string hvm userdevice in
            match Device_number.spec device_number with
                | Device_number.Ide, n, _ when n < 4 -> true
                | _ -> false
		end

	(* If we have a shared VDI (eg CDROM) we don't share the blkfront
	   to simplify the accounting. We use the other_config:related_to key
	   to distinguish the different VBDs. *)
	let vbd_opt ~__context ~self =
		let vdi = Db.VBD.get_VDI ~__context ~self in
		let user_vm = Db.VBD.get_VM ~__context ~self in
		let vm = get_qemu_vm ~__context ~vm:user_vm in
		if Db.is_valid_ref __context vdi
		then begin
			match List.filter (fun other ->
				try
					let vbd_r = Db.VBD.get_record ~__context ~self:other in
					true
					&& vbd_r.API.vBD_VM = vm
							&& (List.mem_assoc Xapi_globs.related_to_key vbd_r.API.vBD_other_config)
							&& (List.assoc Xapi_globs.related_to_key vbd_r.API.vBD_other_config = Ref.string_of self)
				with _ -> false (* the VBD may be destroyed concurrently *)
			) (Db.VDI.get_VBDs ~__context ~self:vdi) with
				| vbd :: _ -> Some vbd
				| [] -> None
		end else None

	let create ~__context ~self ~read_write hvm =
		match vbd_opt ~__context ~self with
			| Some vbd ->
				if not (Db.VBD.get_currently_attached ~__context ~self:vbd)
				then Helpers.call_api_functions ~__context
					(fun rpc session_id -> XenAPI.VBD.plug rpc session_id vbd)
			| None ->
				let vdi = Db.VBD.get_VDI ~__context ~self in
				let user_vm = Db.VBD.get_VM ~__context ~self in
				let vm = get_qemu_vm ~__context ~vm:user_vm in
				if needed ~__context ~self hvm
				then Helpers.call_api_functions ~__context
					(fun rpc session_id ->
						let mode = if read_write then `RW else `RO in
						let vbd = XenAPI.VBD.create
							~rpc ~session_id ~vM:vm ~vDI:vdi
							~other_config:[ Xapi_globs.related_to_key, Ref.string_of self ]
							~userdevice:"autodetect" ~bootable:false ~mode
							~_type:`Disk ~empty:false ~unpluggable:true
							~qos_algorithm_type:"" ~qos_algorithm_params:[] in
						XenAPI.VBD.plug rpc session_id vbd
					)

	let path_opt ~__context ~self =
		let vbd = vbd_opt ~__context ~self in
		let path_of vbd = "/dev/" ^ (Db.VBD.get_device ~__context ~self:vbd) in
		Opt.map path_of vbd

	let on_vbd ~__context ~self f =
		let vbd = vbd_opt ~__context ~self in
		Opt.iter
            (fun vbd ->
                Helpers.call_api_functions ~__context
                    (fun rpc session_id -> f rpc session_id vbd)
            ) vbd

	let unplug_nowait ~__context ~self =
		on_vbd ~__context ~self
			(fun rpc session_id vbd ->
				try XenAPI.VBD.unplug rpc session_id vbd
				with _ -> ()
			)
		
	let destroy ~__context ~self =
		on_vbd ~__context ~self
			(fun rpc session_id vbd ->
                Attach_helpers.safe_unplug rpc session_id vbd;
                XenAPI.VBD.destroy rpc session_id vbd
            )
end

module type SERVER = sig
    val process : Smint.request -> Rpc.call -> Rpc.response
end

let make_local _ =
    (module Server(Builtin_impl) : SERVER)

let make_remote host path =
	let open Xmlrpc_client in
    (module Server(Storage_proxy.Proxy(struct let rpc call = XMLRPC_protocol.rpc ~srcstr:"smapiv2" ~dststr:"smapiv1" ~transport:(TCP(host, 8080)) ~http:(xmlrpc ~version:"1.0" path) call end)) : SERVER)

let bind ~__context ~pbd =
    (* Start the VM if necessary, record its uuid *)
    let driver = System_domains.storage_driver_domain_of_pbd ~__context ~pbd in
    if Db.VM.get_power_state ~__context ~self:driver = `Halted then begin
        info "PBD %s driver domain %s is offline: starting" (Ref.string_of pbd) (Ref.string_of driver);
		try
			Helpers.call_api_functions ~__context
				(fun rpc session_id -> XenAPI.VM.start rpc session_id driver false false)
		with (Api_errors.Server_error(code, params)) when code = Api_errors.vm_bad_power_state ->
			error "Caught VM_BAD_POWER_STATE [ %s ]" (String.concat "; " params);
			(* ignore for now *)
    end;
	let uuid = Db.VM.get_uuid ~__context ~self:driver in
    let ip_of driver =
        (* Find the VIF on the Host internal management network *)
        let vifs = Db.VM.get_VIFs ~__context ~self:driver in
        let hin = Helpers.get_host_internal_management_network ~__context in
        let ip =
            let vif =
                try
                    List.find (fun vif -> Db.VIF.get_network ~__context ~self:vif = hin) vifs
                with Not_found -> failwith (Printf.sprintf "PBD %s driver domain %s has no VIF on host internal management network" (Ref.string_of pbd) (Ref.string_of driver)) in
            match Xapi_udhcpd.get_ip ~__context vif with
                | Some (a, b, c, d) -> Printf.sprintf "%d.%d.%d.%d" a b c d
                | None -> failwith (Printf.sprintf "PBD %s driver domain %s has no IP on the host internal management network" (Ref.string_of pbd) (Ref.string_of driver)) in

        info "PBD %s driver domain uuid:%s ip:%s" (Ref.string_of pbd) uuid ip;
        if not(System_domains.wait_for (System_domains.pingable ip))
        then failwith (Printf.sprintf "PBD %s driver domain %s is not responding to IP ping" (Ref.string_of pbd) (Ref.string_of driver));
        if not(System_domains.wait_for (System_domains.queryable ip 8080))
        then failwith (Printf.sprintf "PBD %s driver domain %s is not responding to XMLRPC query" (Ref.string_of pbd) (Ref.string_of driver));
        ip in
    let sr = Db.PBD.get_SR ~__context ~self:pbd in
    let path = Constants.path [ Constants._services; Constants._SM; Db.SR.get_type ~__context ~self:sr ] in

    let dom0 = Helpers.get_domain_zero ~__context in
    let module Impl = (val (if driver = dom0 then make_local path else make_remote (ip_of driver) path): SERVER) in
    let sr = Db.SR.get_uuid ~__context ~self:(Db.PBD.get_SR ~__context ~self:pbd) in
    info "SR %s will be implemented by %s in VM %s" sr path (Ref.string_of driver);
    Storage_mux.register sr (Impl.process (Some path)) uuid

let unbind ~__context ~pbd =
        let sr = Db.SR.get_uuid ~__context ~self:(Db.PBD.get_SR ~__context ~self:pbd) in
        Storage_mux.unregister sr

let rpc call = Storage_mux.Server.process None call

module Client = Client(struct let rpc = rpc end)

let print_delta d =
	debug "Received update: %s" (Jsonrpc.to_string (Storage_interface.Dynamic.rpc_of_id d))

let event_wait dbg p =
	let finished = ref false in
	let event_id = ref "" in
	while not !finished do
		debug "Calling UPDATES.get %s %s 30" dbg !event_id;
		let deltas, next_id = Client.UPDATES.get dbg !event_id (Some 30) in
		List.iter (fun d -> print_delta d) deltas;
		event_id := next_id;
		List.iter (fun d -> if p d then finished := true) deltas;
	done

let task_ended dbg id =
	match (Client.TASK.stat dbg id).Task.state with
		| Task.Completed _
		| Task.Failed _ -> true
		| Task.Pending _ -> false

let success_task dbg id =
	let t = Client.TASK.stat dbg id in
	Client.TASK.destroy dbg id;
	match t.Task.state with
	| Task.Completed _ -> t
	| Task.Failed x -> raise (exn_of_exnty (Exception.exnty_of_rpc x))
	| Task.Pending _ -> failwith "task pending"

let wait_for_task dbg id =
	debug "Waiting for task id=%s to finish" id;
	let finished = function
		| Dynamic.Task id' ->
			id = id' && (task_ended dbg id)
		| _ ->
			false in 
	event_wait dbg finished;
	id

let vdi_of_task dbg t =
	match t.Task.state with
		| Task.Completed { Task.result = Some Vdi_info v } -> v
		| Task.Completed _ -> failwith "Runtime type error in vdi_of_task"
		| _ -> failwith "Task not completed"

let mirror_of_task dbg t =
	match t.Task.state with
		| Task.Completed { Task.result = Some Mirror_id i } -> i
		| Task.Completed _ -> failwith "Runtime type error in mirror_of_task"
		| _ -> failwith "Task not complete"

let progress_map_tbl = Hashtbl.create 10
let mirror_task_tbl = Hashtbl.create 10
let progress_map_m = Mutex.create ()

let add_to_progress_map f id = Mutex.execute progress_map_m (fun () -> Hashtbl.add progress_map_tbl id f); id
let remove_from_progress_map id = Mutex.execute progress_map_m (fun () -> Hashtbl.remove progress_map_tbl id); id
let get_progress_map id = Mutex.execute progress_map_m (fun () -> try Hashtbl.find progress_map_tbl id with _ -> (fun x -> x))

let register_mirror __context vdi = 
	let task = Context.get_task_id __context in
	debug "Registering mirror of vdi %s with task %s" vdi (Ref.string_of task);
	Mutex.execute progress_map_m (fun () -> Hashtbl.add mirror_task_tbl vdi task); vdi
let unregister_mirror vdi = Mutex.execute progress_map_m (fun () -> Hashtbl.remove mirror_task_tbl vdi); vdi
let get_mirror_task vdi = Mutex.execute progress_map_m (fun () -> Hashtbl.find mirror_task_tbl vdi)

exception Not_an_sm_task
let wrap id = TaskHelper.Sm id
let unwrap x = match x with | TaskHelper.Sm id -> id | _ -> raise Not_an_sm_task
let register_task __context id = TaskHelper.register_task __context (wrap id) |> unwrap
let unregister_task __context id = TaskHelper.unregister_task __context (wrap id) |> unwrap

let update_task ~__context id =
	try
		let self = TaskHelper.id_to_task_exn (TaskHelper.Sm id) in (* throws Not_found *)
		let dbg = Context.string_of_task __context in
		let task_t = Client.TASK.stat dbg id in
		let map = get_progress_map id in
		match task_t.Task.state with
			| Task.Pending x ->
				Db.Task.set_progress ~__context ~self ~value:(map x)
			| _ -> ()
	with Not_found ->
		(* Since this is called on all tasks, possibly after the task has been
		   destroyed, it's safe to ignore a Not_found exception here. *)
		()
	| e ->
		error "storage event: Caught %s while updating task" (Printexc.to_string e)

let update_mirror ~__context id =
	try 
		let dbg = Context.string_of_task __context in 
		let m = Client.DATA.MIRROR.stat dbg id in
		if m.Mirror.failed 
		then 
			debug "Mirror %s has failed" id;
			let task = get_mirror_task m.Mirror.source_vdi in
			debug "Mirror associated with task: %s" (Ref.string_of task);
			(* Just to get a nice error message *)
			Db.Task.remove_from_other_config ~__context ~self:task ~key:"mirror_failed";
			Db.Task.add_to_other_config ~__context ~self:task ~key:"mirror_failed" ~value:m.Mirror.source_vdi;
			Helpers.call_api_functions ~__context
				(fun rpc session_id -> XenAPI.Task.cancel rpc session_id task)
	with 
		| Not_found -> 
			debug "Couldn't find mirror id: %s" id
		| Does_not_exist _ -> ()
		| e -> 
			error "storage event: Caught %s while updating mirror" (Printexc.to_string e)
				
let rec events_watch ~__context from =
	let dbg = Context.string_of_task __context in
	let events, next = Client.UPDATES.get dbg from None in
	let open Dynamic in
	List.iter
		(function
			| Task id ->
				debug "sm event on Task %s" id;
				update_task ~__context id
			| Vdi vdi -> 
				debug "sm event on VDI %s: ignoring" vdi
			| Dp dp ->
				debug "sm event on DP %s: ignoring" dp
			| Mirror id ->
				debug "sm event on mirror: %s" id;
				update_mirror ~__context id
		) events;
	events_watch ~__context next

let transform_storage_exn f =
	try
		f ()
	with
		| Backend_error(code, params) ->
			error "Re-raising as %s [ %s ]" code (String.concat "; " params);
			raise (Api_errors.Server_error(code, params))
		| Api_errors.Server_error(code, params) as e -> raise e
		| e ->
			error "Re-raising as INTERNAL_ERROR [ %s ]" (Printexc.to_string e);
			raise (Api_errors.Server_error(Api_errors.internal_error, [ Printexc.to_string e ]))

let events_from_sm () =
	ignore(Thread.create (fun () -> 
		Server_helpers.exec_with_new_task "sm_events"
			(fun __context ->
				while true do
					try
						events_watch ~__context "";
					with e ->
						error "event thread caught: %s" (Printexc.to_string e);
						Thread.delay 10.
				done
			)) ())

let start () =
	let open Storage_impl.Local_domain_socket in
	start Xapi_globs.storage_unix_domain_socket Storage_mux.Server.process


(** [datapath_of_vbd domid userdevice] returns the name of the datapath which corresponds
    to device [userdevice] on domain [domid] *)
let datapath_of_vbd ~domid ~device =
	Printf.sprintf "vbd/%d/%s" domid device

let of_vbd ~__context ~vbd ~domid =
	let vdi = Db.VBD.get_VDI ~__context ~self:vbd in
	let location = Db.VDI.get_location ~__context ~self:vdi in
	let sr = Db.VDI.get_SR ~__context ~self:vdi in
	let userdevice = Db.VBD.get_userdevice ~__context ~self:vbd in
	let hvm = Helpers.will_boot_hvm ~__context ~self:(Db.VBD.get_VM ~__context ~self:vbd) in
	let dbg = Context.get_task_id __context in
	let device_number = Device_number.of_string hvm userdevice in
	let device = Device_number.to_linux_device device_number in
	let dp = datapath_of_vbd ~domid ~device in
	rpc, (Ref.string_of dbg), dp, (Db.SR.get_uuid ~__context ~self:sr), location

(** [is_attached __context vbd] returns true if the [vbd] has an attached
    or activated datapath. *)
let is_attached ~__context ~vbd ~domid  =
	transform_storage_exn
		(fun () ->
			let rpc, dbg, dp, sr, vdi = of_vbd ~__context ~vbd ~domid in
			let open Vdi_automaton in
			let module C = Storage_interface.Client(struct let rpc = rpc end) in
			try 
				let x = C.VDI.stat ~dbg ~sr ~vdi () in
				x.superstate <> Detached
			with 
				| e -> error "Unable to query state of VDI: %s, %s" vdi (Printexc.to_string e); false
		)

(** [on_vdi __context vbd domid f] calls [f rpc dp sr vdi] which is
    useful for executing Storage_interface.Client.VDI functions  *)
let on_vdi ~__context ~vbd ~domid f =
	let rpc, dbg, dp, sr, vdi = of_vbd ~__context ~vbd ~domid in
	let module C = Storage_interface.Client(struct let rpc = rpc end) in
	let dp = C.DP.create dbg dp in
	transform_storage_exn
		(fun () ->
			f rpc dbg dp sr vdi
		)

let reset ~__context ~vm =
	let dbg = Context.get_task_id __context in
	transform_storage_exn
		(fun () ->
			Opt.iter
				(fun pbd ->
					let sr = Db.SR.get_uuid ~__context ~self:(Db.PBD.get_SR ~__context ~self:pbd) in
					info "Resetting all state associated with SR: %s" sr;
					Client.SR.reset (Ref.string_of dbg) sr;
					Db.PBD.set_currently_attached ~__context ~self:pbd ~value:false;
				) (System_domains.pbd_of_vm ~__context ~vm)
		)

(** [attach_and_activate __context vbd domid f] calls [f attach_info] where
    [attach_info] is the result of attaching a VDI which is also activated.
    This should be used everywhere except the migrate code, where we want fine-grained
    control of the ordering of attach/activate/deactivate/detach *)
let attach_and_activate ~__context ~vbd ~domid ~hvm f =
	transform_storage_exn
		(fun () ->
			let read_write = Db.VBD.get_mode ~__context ~self:vbd = `RW in
			let result = on_vdi ~__context ~vbd ~domid
				(fun rpc dbg dp sr vdi ->
					let module C = Storage_interface.Client(struct let rpc = rpc end) in
					let attach_info = C.VDI.attach dbg dp sr vdi read_write in
					C.VDI.activate dbg dp sr vdi;
					f attach_info
				) in
			Qemu_blkfront.create ~__context ~self:vbd ~read_write hvm;
			result
		)

(** [deactivate_and_detach __context vbd domid] idempotent function which ensures
    that any attached or activated VDI gets properly deactivated and detached. *)
let deactivate_and_detach ~__context ~vbd ~domid ~unplug_frontends =
	transform_storage_exn
		(fun () ->
			(* Remove the qemu frontend first: this will not pass the deactivate/detach
			   through to the backend so an SM backend failure won't cause us to leak
			   a VBD. *)
			if unplug_frontends
			then Qemu_blkfront.destroy ~__context ~self:vbd;
			(* It suffices to destroy the datapath: any attached or activated VDIs will be
			   automatically detached and deactivated. *)
			on_vdi ~__context ~vbd ~domid
				(fun rpc dbg dp sr vdi ->
					let module C = Storage_interface.Client(struct let rpc = rpc end) in
					C.DP.destroy dbg dp false
				)
		)


let diagnostics ~__context =
	Client.DP.diagnostics ()

let dp_destroy ~__context dp allow_leak =
	transform_storage_exn
		(fun () ->
			let dbg = Context.get_task_id __context in
			Client.DP.destroy (Ref.string_of dbg) dp allow_leak
		)

(* Set my PBD.currently_attached fields in the Pool database to match the local one *)
let resynchronise_pbds ~__context ~pbds =
	let dbg = Context.get_task_id __context in
	let srs = Client.SR.list (Ref.string_of dbg) in
	debug "Currently-attached SRs: [ %s ]" (String.concat "; " srs);
	List.iter
		(fun self ->
			let sr = Db.SR.get_uuid ~__context ~self:(Db.PBD.get_SR ~__context ~self) in
			let value = List.mem sr srs in
			debug "Setting PBD %s currently_attached <- %b" (Ref.string_of self) value;
			if value then bind ~__context ~pbd:self;
			Db.PBD.set_currently_attached ~__context ~self ~value
		) pbds

(* -------------------------------------------------------------------------------- *)
(* The following functions are symptoms of a broken interface with the SM layer.
   They should be removed, by enhancing the SM layer. *)

(* This is a layering violation. The layers are:
     xapi: has a pool-wide view
     storage_impl: has a host-wide view of SRs and VDIs
     SM: has a SR-wide viep
   Unfortunately the SM is storing some of its critical state (VDI-host locks) in the xapi
   metadata rather than on the backend storage. The xapi metadata is generally not authoritative
   and must be synchronised against the state of the world. Therefore we must synchronise the
   xapi view with the storage_impl view here. *)
let refresh_local_vdi_activations ~__context =
	let all_vdi_recs = Db.VDI.get_all_records ~__context in
	let localhost = Helpers.get_localhost ~__context in
	let all_hosts = Db.Host.get_all ~__context in

	let key host = Printf.sprintf "host_%s" (Ref.string_of host) in
	let hosts_of vdi_t =
		let prefix = "host_" in
		let ks = List.map fst vdi_t.API.vDI_sm_config in
		let ks = List.filter (String.startswith prefix) ks in
		let ks = List.map (fun k -> String.sub k (String.length prefix) (String.length k - (String.length prefix))) ks in
		List.map Ref.of_string ks in

	(* If this VDI is currently locked to this host, remove the lock.
	   If this VDI is currently locked to a non-existent host (note host references
	   change across pool join), remove the lock. *)
	let unlock_vdi (vdi_ref, vdi_rec) = 
		(* VDI is already unlocked is the common case: avoid eggregious logspam *)
		let hosts = hosts_of vdi_rec in
		let i_locked_it = List.mem localhost hosts in
		let all = List.fold_left (&&) true in
		let someone_leaked_it = all (List.map (fun h -> not(List.mem h hosts)) all_hosts) in
		if i_locked_it || someone_leaked_it then begin
			info "Unlocking VDI %s (because %s)" (Ref.string_of vdi_ref)
				(if i_locked_it then "I locked it and then restarted" else "it was leaked (pool join?)");
			try
				List.iter (fun h -> Db.VDI.remove_from_sm_config ~__context ~self:vdi_ref ~key:(key h)) hosts
			with e ->
				error "Failed to unlock VDI %s: %s" (Ref.string_of vdi_ref) (ExnHelper.string_of_exn e)
		end in
	let open Vdi_automaton in
	(* Lock this VDI to this host *)
	let lock_vdi (vdi_ref, vdi_rec) ro_rw = 
		info "Locking VDI %s" (Ref.string_of vdi_ref);
		if not(List.mem_assoc (key localhost) vdi_rec.API.vDI_sm_config) then begin
			try
				Db.VDI.add_to_sm_config ~__context ~self:vdi_ref ~key:(key localhost) ~value:(string_of_ro_rw ro_rw)
			with e ->
				error "Failed to lock VDI %s: %s" (Ref.string_of vdi_ref) (ExnHelper.string_of_exn e)
		end in
	let remember key ro_rw = 
		(* The module above contains a hashtable of R/O vs R/W-ness *)
		Mutex.execute Builtin_impl.VDI.vdi_read_write_m
			(fun () -> Hashtbl.replace Builtin_impl.VDI.vdi_read_write key (ro_rw = RW)) in

	let dbg = Ref.string_of (Context.get_task_id __context) in
	let srs = Client.SR.list dbg in
	List.iter 
		(fun (vdi_ref, vdi_rec) ->
			let sr = Db.SR.get_uuid ~__context ~self:vdi_rec.API.vDI_SR in
			let vdi = vdi_rec.API.vDI_location in
			if List.mem sr srs
			then
				try
					let x = Client.VDI.stat ~dbg ~sr ~vdi () in
					match x.superstate with 
						| Activated RO ->
							lock_vdi (vdi_ref, vdi_rec) RO;
							remember (sr, vdi) RO
						| Activated RW -> 
							lock_vdi (vdi_ref, vdi_rec) RW;
							remember (sr, vdi) RW
						| Attached RO -> 
							unlock_vdi (vdi_ref, vdi_rec);
							remember (sr, vdi) RO
						| Attached RW -> 
							unlock_vdi (vdi_ref, vdi_rec);
							remember (sr, vdi) RW
						| Detached -> 
							unlock_vdi (vdi_ref, vdi_rec)
				with
					| e -> error "Unable to query state of VDI: %s, %s" vdi (Printexc.to_string e)
			else unlock_vdi (vdi_ref, vdi_rec)
		) all_vdi_recs

(* This is a symptom of the ordering-sensitivity of the SM backend: it is not possible
   to upgrade RO -> RW or downgrade RW -> RO on the fly.
   One possible fix is to always attach RW and enforce read/only-ness at the VBD-level.
   However we would need to fix the LVHD "attach provisioning mode". *)
let vbd_attach_order ~__context vbds = 
	(* return RW devices first since the storage layer can't upgrade a
	   'RO attach' into a 'RW attach' *)
	let rw, ro = List.partition (fun self -> Db.VBD.get_mode ~__context ~self = `RW) vbds in
	rw @ ro

let vbd_detach_order ~__context vbds = List.rev (vbd_attach_order ~__context vbds)

(* This is because the current backends want SR.attached <=> PBD.currently_attached=true.
   It would be better not to plug in the PBD, so that other API calls will be blocked. *)
let destroy_sr ~__context ~sr =
	transform_storage_exn
		(fun () ->
			let pbd, pbd_t = Sm.get_my_pbd_for_sr __context sr in
			bind ~__context ~pbd;
			let dbg = Ref.string_of (Context.get_task_id __context) in
			Client.SR.attach dbg (Db.SR.get_uuid ~__context ~self:sr) pbd_t.API.pBD_device_config;
			(* The current backends expect the PBD to be temporarily set to currently_attached = true *)
			Db.PBD.set_currently_attached ~__context ~self:pbd ~value:true;
			Pervasiveext.finally (fun () ->
				Client.SR.destroy dbg (Db.SR.get_uuid ~__context ~self:sr))
				(fun () -> 
					(* All PBDs are clearly currently_attached = false now *)
					Db.PBD.set_currently_attached ~__context ~self:pbd ~value:false);
			unbind ~__context ~pbd
		)

let task_cancel ~__context ~self =
	try
		let id = TaskHelper.task_to_id_exn self |> unwrap in
		let dbg = Context.string_of_task __context in
		info "storage_access: TASK.cancel %s" id;
		Client.TASK.cancel dbg id |> ignore;
		true
	with 
		| Not_found -> false
		| Not_an_sm_task -> false
