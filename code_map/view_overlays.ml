(*s: view_overlays.ml *)
(*s: Facebook copyright *)
(* Yoann Padioleau
 * 
 * Copyright (C) 2010-2012 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 * 
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
(*e: Facebook copyright *)
open Common
(* floats are the norm in graphics *)
open Common2.ArithFloatInfix

open Model2
module F = Figures
module T = Treemap
module CairoH = Cairo_helpers
module M = Model2
module Flag = Flag_visual
module Controller = Controller2
module Style = Style2

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* This module mainly modifies the dw.overlay cairo surface. It also
 * triggers the refresh_da which triggers itself the expose event
 * which triggers the View2.assemble_layers composition of dw.pm with
 * dw.overlay.
 *)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let readable_txt_for_label txt current_root =
  let readable_txt = 
    if current_root =$= txt (* when we are fully zoomed on one file *)
    then "root"
    else Common.readable ~root:current_root txt 
  in
  if String.length readable_txt > 25
  then 
    let dirs = Filename.dirname readable_txt +> Common.split "/" in
    let file = Filename.basename readable_txt in
    spf "%s/.../%s" (List.hd dirs) file
  else readable_txt

let with_overlay dw f =
  let cr_overlay = Cairo.create dw.overlay in
  View_mainmap.zoom_pan_scale_map cr_overlay dw;
  f cr_overlay

(*****************************************************************************)
(* The overlays *)
(*****************************************************************************)

(* ---------------------------------------------------------------------- *)
(* The current filename *)
(* ---------------------------------------------------------------------- *)
(*s: draw_label_overlay *)
(* assumes cr_overlay has not been zoom_pan_scale *)
let draw_label_overlay ~cr_overlay ~x ~y txt =

  Cairo.select_font_face cr_overlay "serif" 
    Cairo.FONT_SLANT_NORMAL Cairo.FONT_WEIGHT_NORMAL;
  Cairo.set_font_size cr_overlay Style2.font_size_filename_cursor;
      
  let extent = CairoH.text_extents cr_overlay txt in
  let tw = extent.Cairo.text_width in
  let th = extent.Cairo.text_height in

  let refx = x - tw / 2. in
  let refy = y in

  CairoH.fill_rectangle ~cr:cr_overlay 
    ~x:(refx + extent.Cairo.x_bearing) ~y:(refy + extent.Cairo.y_bearing)
    ~w:tw ~h:(th * 1.2)
    ~color:"black"
    ~alpha:0.5
    ();

  Cairo.move_to cr_overlay refx refy;
  Cairo.set_source_rgba cr_overlay 1. 1. 1.    1.0;
  CairoH.show_text cr_overlay txt;
  ()
(*e: draw_label_overlay *)

(* ---------------------------------------------------------------------- *)
(* The current rectangles *)
(* ---------------------------------------------------------------------- *)

(*s: draw_rectangle_overlay *)
let draw_englobing_rectangles_overlay ~dw (r, middle, r_englobing) =
 with_overlay dw (fun cr_overlay ->
  CairoH.draw_rectangle_figure 
    ~cr:cr_overlay ~color:"white" r.T.tr_rect;
  CairoH.draw_rectangle_figure
    ~cr:cr_overlay ~color:"blue" r_englobing.T.tr_rect;

  Draw_labels.draw_treemap_rectangle_label_maybe 
    ~cr:cr_overlay ~color:(Some "red") ~zoom:1.0 r_englobing;

  middle +> Common.index_list_1 +> List.iter (fun (r, i) ->
    let color = 
      match i with
      | 1 -> "grey70"
      | 2 -> "grey40"
      | _ -> spf "grey%d" (max 1 (50 -.. (i *.. 10)))
    in
    CairoH.draw_rectangle_figure
      ~cr:cr_overlay ~color r.T.tr_rect;
    Draw_labels.draw_treemap_rectangle_label_maybe 
      ~cr:cr_overlay ~color:(Some color) ~zoom:1.0 r;
  );
 )
(*e: draw_rectangle_overlay *)

(* ---------------------------------------------------------------------- *)
(* Uses and users macrolevel *)
(* ---------------------------------------------------------------------- *)
let draw_uses_users_files ~dw r =
 with_overlay dw (fun cr_overlay ->
   let file = r.T.tr_label in
   let uses_rect, users_rect = M.deps_rect_of_file file dw in
   uses_rect +> List.iter (fun r ->
     CairoH.draw_rectangle_figure ~cr:cr_overlay ~color:"green" r.T.tr_rect;
   );
   users_rect +> List.iter (fun r ->
     CairoH.draw_rectangle_figure ~cr:cr_overlay ~color:"red" r.T.tr_rect;
   )
 )

(* ---------------------------------------------------------------------- *)
(* Uses and users microlevel *)
(* ---------------------------------------------------------------------- *)
let draw_magnify_line_overlay_maybe ?honor_color dw line microlevel =
  with_overlay dw (fun cr_overlay ->
    let font_size = microlevel.layout.lfont_size in
    let font_size_real = CairoH.user_to_device_font_size cr_overlay font_size in

    (* todo: put in style *)
    if font_size_real < 5.
    then Draw_microlevel.draw_magnify_line 
      ?honor_color cr_overlay line microlevel
  )

let draw_uses_users_entities ~dw n =
 with_overlay dw (fun cr_overlay ->
   let uses, users = deps_of_node_clipped n dw  in
   uses +> List.iter (fun (_n2, line, microlevel) ->
     let rectangle = microlevel.line_to_rectangle line in
     CairoH.draw_rectangle_figure ~cr:cr_overlay ~color:"green" rectangle;
   );
   users +> List.iter (fun (_n2, line, microlevel) ->
     let rectangle = microlevel.line_to_rectangle line in
     CairoH.draw_rectangle_figure ~cr:cr_overlay ~color:"red" rectangle;
     
     let lines_used = M.lines_where_used_node n line microlevel in
     lines_used +> List.iter (fun line ->
       let rectangle = microlevel.line_to_rectangle line in
       CairoH.draw_rectangle_figure ~cr:cr_overlay ~color:"purple" rectangle;

       draw_magnify_line_overlay_maybe ~honor_color:false dw line microlevel;
     );
   );
 )

(* ---------------------------------------------------------------------- *)
(* The selected rectangles *)
(* ---------------------------------------------------------------------- *)

(*s: draw_searched_rectangles *)
let draw_searched_rectangles ~dw =
 with_overlay dw (fun cr_overlay ->
  dw.current_searched_rectangles +> List.iter (fun r ->
    CairoH.draw_rectangle_figure ~cr:cr_overlay ~color:"yellow" r.T.tr_rect
  );
  (* 
   * would also like to draw not matching rectangles
   * bug the following code is too slow on huge treemaps. 
   * Probably because it is doing lots of drawing and alpha
   * computation.
   *
   * old:
   * let color = Some "grey3" in
   * Draw.draw_treemap_rectangle ~cr:cr_overlay 
   * ~color ~alpha:0.3
   * r
   *)
 )
(*e: draw_searched_rectangles *)

(*s: zoomed_surface_of_rectangle *)
(*e: zoomed_surface_of_rectangle *)

(*****************************************************************************)
(* Assembling overlays *)
(*****************************************************************************)

(*s: motion_refresher *)
let motion_refresher ev dw =
  let cr_overlay = Cairo.create dw.overlay in
  CairoH.clear cr_overlay;

  (* some similarity with View_mainmap.button_action handler *)
  let x, y = GdkEvent.Motion.x ev, GdkEvent.Motion.y ev in
  let pt = { Cairo. x = x; y = y } in
  let user = View_mainmap.with_map dw (fun cr -> Cairo.device_to_user cr pt) in
  let r_opt = M.find_rectangle_at_user_point dw user in

  r_opt +> Common.do_option (fun (r, middle, r_englobing) ->
    let line_opt, entity_opt =
      if Hashtbl.mem dw.microlevel r
      then
        let microlevel = Hashtbl.find dw.microlevel r in
        let line = microlevel.point_to_line user in
        let entity_opt = M.find_def_entity_at_line_opt line r dw in
        Some line, entity_opt
      else None, None
    in

    let statusbar_txt = 
      r.T.tr_label ^
      (match line_opt with None -> "" | Some (Line i) -> spf ":%d" i) ^
      (match entity_opt with None -> "" | Some n -> 
        " (" ^ Graph_code.string_of_node n ^ ")"
      )
    in
    !Controller._statusbar_addtext statusbar_txt;

    (match line_opt with
    | None ->
        let label_txt = readable_txt_for_label r.T.tr_label dw.current_root in
        draw_label_overlay ~cr_overlay ~x ~y label_txt
    | Some line ->
        let microlevel = Hashtbl.find dw.microlevel r in
        draw_magnify_line_overlay_maybe ~honor_color:true dw line microlevel
    );

    draw_englobing_rectangles_overlay ~dw (r, middle, r_englobing);
    draw_uses_users_files ~dw r;

    (match line_opt, entity_opt with
    | Some line, Some n ->
      let microlevel = Hashtbl.find dw.microlevel r in
      let rectangle = microlevel.line_to_rectangle line in
      with_overlay dw (fun cr ->
        CairoH.draw_rectangle_figure ~cr ~color:"white" rectangle
      );
      draw_uses_users_entities ~dw n;
    | _ -> ()
    );
     
    if dw.dw_settings.draw_searched_rectangles;
    then draw_searched_rectangles ~dw;
    
    Controller.current_r := Some r;
  );
  !Controller._refresh_da ();
  false


let motion_notify _da dw ev =
  !Controller.current_motion_refresher +> Common.do_option GMain.Idle.remove;
  let dw = !dw in
  let x, y = GdkEvent.Motion.x ev, GdkEvent.Motion.y ev in
  pr2 (spf "motion: %f, %f" x y);

  Controller.current_motion_refresher := 
    Some (Gui.gmain_idle_add ~prio:100 (fun () -> motion_refresher ev dw));
  true
(*e: motion_refresher *)

(*s: idle *)
(*e: idle *)

(*e: view_overlays.ml *)
