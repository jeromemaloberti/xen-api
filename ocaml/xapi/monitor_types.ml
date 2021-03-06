(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
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
(** Some records for easy passing around of monitor types.
 * @group Performance Monitoring
 *)

type vcpu = {
  vcpu_sumcpus: float;
  vcpu_vcpus: float array;
  vcpu_rawvcpus: Xenctrl.vcpuinfo array;
  vcpu_cputime: int64;
}

type memory = {
  memory_mem: int64;
}

type vif = {
  vif_n: int;
  vif_name: string;
  vif_tx: float;
  vif_rx: float;
  vif_raw_tx: int64;
  vif_raw_rx: int64;
  vif_raw_tx_err: int64;
  vif_raw_rx_err: int64;
}

type vbd = {
  vbd_device_id: int;
  vbd_io_read: float;
  vbd_io_write: float;
  vbd_raw_io_read: int64;
  vbd_raw_io_write: int64;
}

type pcpus = {
  pcpus_usage: float array;
}

type pif = {
  pif_name: string;
  pif_tx: float;
  pif_rx: float;
  pif_raw_tx: int64;
  pif_raw_rx: int64;
  pif_carrier: bool;
  pif_speed: int;
  pif_duplex: Network_interface.duplex;
  pif_pci_bus_path: string;
  pif_vendor_id: string;
  pif_device_id: string;
}

type host_stats = {
  timestamp: float;
  host_ref: [ `host ] Ref.t;
  total_kib: int64;
  free_kib: int64;

  pifs : pif list;              (* host pif metrics *)
  pcpus : pcpus;                (* host pcpu usage metrics *)
  vbds : (string * vbd) list;   (* domain uuid * vbd stats list *)
  vifs : (string * vif) list;   (* domain uuid * vif stats list *)
  vcpus : (string * vcpu) list; (* domain uuid to vcpus stats assoc list *)
  mem : (string * memory) list; (* domain uuid to memory stats assoc list *)
  registered : string list;     (* registered domain uuids *)
}
