(* virt-sparsify
 * Copyright (C) 2011-2014 Red Hat Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *)

open Unix
open Printf

open Common_gettext.Gettext

module G = Guestfs

open Common_utils
open Cmdline

external statvfs_free_space : string -> int64 =
  "virt_sparsify_statvfs_free_space"

let () = Random.self_init ()

let main () =
  let indisk, outdisk, check_tmpdir, compress, convert, debug_gc,
    format, ignores, machine_readable,
    option, quiet, verbose, trace, zeroes =
    parse_cmdline () in

  (* Once we have got past argument parsing and start to create
   * temporary files (including the potentially massive overlay file), we
   * need to catch SIGINT (^C) and exit cleanly so the temporary file
   * goes away.  Note that we don't delete temporaries in the signal
   * handler.
   *)
  let do_sigint _ = exit 1 in
  Sys.set_signal Sys.sigint (Sys.Signal_handle do_sigint);

  (* What should the output format be?  If the user specified an
   * input format, use that, else detect it from the source image.
   *)
  let output_format =
    match convert with
    | Some fmt -> fmt           (* user specified output conversion *)
    | None ->
      match format with
      | Some fmt -> fmt    (* user specified input format, use that *)
      | None ->
        (* Don't know, so we must autodetect. *)
        match (new G.guestfs ())#disk_format indisk  with
        | "unknown" ->
          error (f_"cannot detect input disk format; use the --format parameter")
        | fmt -> fmt in

  (* Compression is not supported by raw output (RHBZ#852194). *)
  if output_format = "raw" && compress then
    error (f_"--compress cannot be used for raw output.  Remove this option or use --convert qcow2.");

  (* Get virtual size of the input disk. *)
  let virtual_size = (new G.guestfs ())#disk_virtual_size indisk in
  if not quiet then
    printf (f_"Input disk virtual size = %Ld bytes (%s)\n%!")
      virtual_size (human_size virtual_size);

  (* Check there is enough space in $TMPDIR. *)
  let tmpdir = Filename.temp_dir_name in

  let print_warning () =
    let free_space = statvfs_free_space tmpdir in
    let extra_needed = virtual_size -^ free_space in
    if extra_needed > 0L then (
      eprintf (f_"\

WARNING: There may not be enough free space on %s.
You may need to set TMPDIR to point to a directory with more free space.

Max needed: %s.  Free: %s.  May need another %s.

Note this is an overestimate.  If the guest disk is full of data
then not as much free space would be required.

You can ignore this warning or change it to a hard failure using the
--check-tmpdir=(ignore|continue|warn|fail) option.  See virt-sparsify(1).

%!")
        tmpdir (human_size virtual_size)
        (human_size free_space) (human_size extra_needed);
      true
    ) else false
  in

  (match check_tmpdir with
  | `Ignore -> ()
  | `Continue -> ignore (print_warning ())
  | `Warn ->
    if print_warning () then (
      eprintf "Press RETURN to continue or ^C to quit.\n%!";
      ignore (read_line ())
    );
  | `Fail ->
    if print_warning () then (
      eprintf "Exiting because --check-tmpdir=fail was set.\n%!";
      exit 2
    )
  );

  if not quiet then
    printf (f_"Create overlay file in %s to protect source disk ...\n%!") tmpdir;

  (* Create the temporary overlay file. *)
  let overlaydisk =
    let tmp = Filename.temp_file "sparsify" ".qcow2" in
    unlink_on_exit tmp;

    (* Create it with the indisk as the backing file. *)
    (* XXX Old code used to:
     * - detect if compat=1.1 was supported
     * - add lazy_refcounts option
     *)
    (new G.guestfs ())#disk_create
      ~backingfile:indisk ?backingformat:format ~compat:"1.1"
      tmp "qcow2" Int64.minus_one;

    tmp in

  if not quiet then
    printf (f_"Examine source disk ...\n%!");

  (* Connect to libguestfs. *)
  let g =
    let g = new G.guestfs () in
    if trace then g#set_trace true;
    if verbose then g#set_verbose true;

    (* Note that the temporary overlay disk is always qcow2 format. *)
    g#add_drive ~format:"qcow2" ~readonly:false ~cachemode:"unsafe" overlaydisk;

    if not quiet then Progress.set_up_progress_bar ~machine_readable g;
    g#launch ();

    g in

  (* Modify SIGINT handler (set first above) to cancel the handle. *)
  let do_sigint _ =
    g#user_cancel ();
    exit 1
  in
  Sys.set_signal Sys.sigint (Sys.Signal_handle do_sigint);

  (* Write zeroes for non-ignored filesystems that we are able to mount,
   * and selected swap partitions.
   *)
  let filesystems = g#list_filesystems () in
  let filesystems = List.map fst filesystems in
  let filesystems = List.sort compare filesystems in

  let is_ignored fs =
    let fs = g#canonical_device_name fs in
    List.exists (fun fs' -> fs = g#canonical_device_name fs') ignores
  in

  List.iter (
    fun fs ->
      if not (is_ignored fs) then (
        if List.mem fs zeroes then (
          if not quiet then
            printf (f_"Zeroing %s ...\n%!") fs;

          g#zero_device fs
        ) else (
          let mounted =
            try g#mount fs "/"; true
            with _ -> false in

          if mounted then (
            if not quiet then
              printf (f_"Fill free space in %s with zero ...\n%!") fs;

            g#zero_free_space "/"
          ) else (
            let is_linux_x86_swap =
              (* Look for the signature for Linux swap on i386.
               * Location depends on page size, so it definitely won't
               * work on non-x86 architectures (eg. on PPC, page size is
               * 64K).  Also this avoids hibernated swap space: in those,
               * the signature is moved to a different location.
               *)
              try g#pread_device fs 10 4086L = "SWAPSPACE2"
              with _ -> false in

            if is_linux_x86_swap then (
              if not quiet then
                printf (f_"Clearing Linux swap on %s ...\n%!") fs;

              (* Don't use mkswap.  Just preserve the header containing
               * the label, UUID and swap format version (libguestfs
               * mkswap may differ from guest's own).
               *)
              let header = g#pread_device fs 4096 0L in
              g#zero_device fs;
              if g#pwrite_device fs header 0L <> 4096 then
                error (f_"pwrite: short write restoring swap partition header")
            )
          )
        );

        g#umount_all ()
      )
  ) filesystems;

  (* Fill unused space in volume groups. *)
  let vgs = g#vgs () in
  let vgs = Array.to_list vgs in
  let vgs = List.sort compare vgs in
  List.iter (
    fun vg ->
      if not (List.mem vg ignores) then (
        let lvname = string_random8 () in
        let lvdev = "/dev/" ^ vg ^ "/" ^ lvname in

        let created =
          try g#lvcreate_free lvname vg 100; true
          with _ -> false in

        if created then (
          if not quiet then
            printf (f_"Fill free space in volgroup %s with zero ...\n%!") vg;

          g#zero_device lvdev;
          g#sync ();
          g#lvremove lvdev
        )
      )
  ) vgs;

  (* Don't need libguestfs now. *)
  g#shutdown ();
  g#close ();

  (* Modify SIGINT handler (set first above) to just exit. *)
  let do_sigint _ = exit 1 in
  Sys.set_signal Sys.sigint (Sys.Signal_handle do_sigint);

  (* Now run qemu-img convert which copies the overlay to the
   * destination and automatically does sparsification.
   *)
  if not quiet then
    printf (f_"Copy to destination and make sparse ...\n%!");

  let cmd =
    sprintf "qemu-img convert -f qcow2 -O %s%s%s %s %s"
      (Filename.quote output_format)
      (if compress then " -c" else "")
      (match option with
      | None -> ""
      | Some option -> " -o " ^ Filename.quote option)
      (Filename.quote overlaydisk) (Filename.quote outdisk) in
  if verbose then
    printf "%s\n%!" cmd;
  if Sys.command cmd <> 0 then
    error (f_"external command failed: %s") cmd;

  (* Finished. *)
  if not quiet then (
    print_newline ();
    wrap (s_"Sparsify operation completed with no errors.  Before deleting the old disk, carefully check that the target disk boots and works correctly.\n");
  );

  if debug_gc then
    Gc.compact ()

let () =
  try main ()
  with
  | Unix.Unix_error (code, fname, "") -> (* from a syscall *)
    eprintf (f_"%s: error: %s: %s\n") prog fname (Unix.error_message code);
    exit 1
  | Unix.Unix_error (code, fname, param) -> (* from a syscall *)
    eprintf (f_"%s: error: %s: %s: %s\n") prog fname (Unix.error_message code)
      param;
    exit 1
  | G.Error msg ->                      (* from libguestfs *)
    eprintf (f_"%s: libguestfs error: %s\n") prog msg;
    exit 1
  | Failure msg ->                      (* from failwith/failwithf *)
    eprintf (f_"%s: failure: %s\n") prog msg;
    exit 1
  | Invalid_argument msg ->             (* probably should never happen *)
    eprintf (f_"%s: internal error: invalid argument: %s\n") prog msg;
    exit 1
  | Assert_failure (file, line, char) -> (* should never happen *)
    eprintf (f_"%s: internal error: assertion failed at %s, line %d, char %d\n") prog file line char;
    exit 1
  | Not_found ->                        (* should never happen *)
    eprintf (f_"%s: internal error: Not_found exception was thrown\n") prog;
    exit 1
  | exn ->                              (* something not matched above *)
    eprintf (f_"%s: exception: %s\n") prog (Printexc.to_string exn);
    exit 1
