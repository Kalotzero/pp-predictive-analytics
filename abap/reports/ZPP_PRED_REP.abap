*&---------------------------------------------------------------------*
*& Report ZPP_PRED_REP
*&---------------------------------------------------------------------*
*& Production analysis (raw-material consumption vs recipe, scrap) for users.
*& Reads the results that the Python service stores in the Z tables
*&   ZPP_ORD   production orders with status and explanation
*&   ZPP_COMP  planned vs actual per component
*&   ZPP_GRP   comparison of product groups, lines, shifts ...
*&   ZPP_DRV   what drives raw-material variance and scrap
*& Nothing is calculated here and no PC / Python is needed.
*& Click an order -> CO03, a material/component -> MM03.
*& Double-click an Explanation cell -> full text in a popup.
*&---------------------------------------------------------------------*
REPORT zpp_pred_rep.

DATA: gv_werks TYPE werks_d,
      gv_date  TYPE dats,
      gv_aufnr TYPE aufnr,
      gv_matnr TYPE matnr.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE gv_t2.
  SELECTION-SCREEN BEGIN OF LINE.
    PARAMETERS r_ord RADIOBUTTON GROUP v DEFAULT 'X'.
    SELECTION-SCREEN COMMENT 4(76) c_ord FOR FIELD r_ord.
  SELECTION-SCREEN END OF LINE.
  SELECTION-SCREEN BEGIN OF LINE.
    PARAMETERS r_comp RADIOBUTTON GROUP v.
    SELECTION-SCREEN COMMENT 4(76) c_comp FOR FIELD r_comp.
  SELECTION-SCREEN END OF LINE.
  SELECTION-SCREEN BEGIN OF LINE.
    PARAMETERS r_grp RADIOBUTTON GROUP v.
    SELECTION-SCREEN COMMENT 4(76) c_grp FOR FIELD r_grp.
  SELECTION-SCREEN END OF LINE.
  SELECTION-SCREEN BEGIN OF LINE.
    PARAMETERS r_drv RADIOBUTTON GROUP v.
    SELECTION-SCREEN COMMENT 4(76) c_drv FOR FIELD r_drv.
  SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b2.

SELECTION-SCREEN BEGIN OF BLOCK b3 WITH FRAME TITLE gv_t3.
  SELECTION-SCREEN COMMENT /1(79) c_d3.
  SELECT-OPTIONS: s_werks FOR gv_werks,
                  s_date  FOR gv_date,
                  s_aufnr FOR gv_aufnr,
                  s_matnr FOR gv_matnr.
  SELECTION-SCREEN BEGIN OF LINE.
    PARAMETERS p_only AS CHECKBOX DEFAULT ' '.
    SELECTION-SCREEN COMMENT 4(76) c_only FOR FIELD p_only.
  SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b3.

*----------------------------------------------------------------------*
CLASS lcl_app DEFINITION FINAL.
  PUBLIC SECTION.
    TYPES: ty_qty TYPE p LENGTH 13 DECIMALS 3,
           ty_val TYPE p LENGTH 15 DECIMALS 2,
           ty_pct TYPE p LENGTH 7 DECIMALS 2,
           ty_txt TYPE c LENGTH 255,
           ty_expl TYPE c LENGTH 1000,

           BEGIN OF ty_order,
             light              TYPE c LENGTH 1,
             order_no           TYPE aufnr,
             status             TYPE c LENGTH 10,
             plant              TYPE werks_d,
             material           TYPE matnr,
             material_desc      TYPE maktx,
             material_group     TYPE matkl,
             order_type         TYPE aufart,
             work_center        TYPE arbpl,
             shift              TYPE c LENGTH 20,
             prod_supervisor    TYPE c LENGTH 3,
             actual_finish      TYPE dats,
             target_qty         TYPE ty_qty,
             delivered_qty      TYPE ty_qty,
             unit               TYPE meins,
             own_issued_qty     TYPE ty_qty,
             planned_value      TYPE ty_val,
             actual_value       TYPE ty_val,
             excess_value       TYPE ty_val,
             currency           TYPE waers,
             variance_pct       TYPE ty_pct,
             components         TYPE i,
             flagged_components TYPE i,
             unplanned_components TYPE i,
             scrap_qty          TYPE ty_qty,
             scrap_unit         TYPE meins,
             scrap_rate         TYPE ty_pct,
             scrap_flag         TYPE c LENGTH 12,
             explanation        TYPE ty_expl,
           END OF ty_order,

           BEGIN OF ty_comp,
             light                TYPE c LENGTH 1,
             order_no             TYPE aufnr,
             item                 TYPE c LENGTH 4,
             flag                 TYPE c LENGTH 12,
             plant                TYPE werks_d,
             material             TYPE matnr,
             material_group       TYPE matkl,
             work_center          TYPE arbpl,
             shift                TYPE c LENGTH 20,
             actual_finish        TYPE dats,
             component            TYPE matnr,
             component_desc       TYPE maktx,
             component_group      TYPE matkl,
             in_plan              TYPE c LENGTH 1,
             planned_qty          TYPE ty_qty,
             planned_for_actual   TYPE ty_qty,
             actual_qty           TYPE ty_qty,
             actual_without_reservation TYPE ty_qty,
             unit                 TYPE meins,
             variance_qty         TYPE ty_qty,
             variance_pct         TYPE ty_pct,
             typical_variance_pct TYPE ty_pct,
             z_score              TYPE ty_pct,
             excess_value         TYPE ty_val,
             currency             TYPE waers,
             explanation          TYPE ty_expl,
           END OF ty_comp,

           BEGIN OF ty_group,
             light                TYPE c LENGTH 1,
             dimension            TYPE c LENGTH 30,
             group_name           TYPE c LENGTH 40,
             group_desc           TYPE c LENGTH 60,
             orders               TYPE i,
             value_share          TYPE ty_pct,
             variance_pct         TYPE ty_pct,
             others_variance_pct  TYPE ty_pct,
             difference_pp        TYPE ty_pct,
             variance_significant TYPE c LENGTH 3,
             excess_value         TYPE ty_val,
             scrap_rate           TYPE ty_pct,
             others_scrap_rate    TYPE ty_pct,
             scrap_difference_pct TYPE ty_pct,
             scrap_significant    TYPE c LENGTH 3,
             finding              TYPE ty_txt,
           END OF ty_group,

           BEGIN OF ty_driver,
             target         TYPE c LENGTH 30,
             rank_no        TYPE i,
             driver         TYPE c LENGTH 30,
             meaning        TYPE c LENGTH 60,
             importance_pct TYPE ty_pct,
             model_r2       TYPE p LENGTH 5 DECIMALS 3,
           END OF ty_driver.

    METHODS run.

  PRIVATE SECTION.
    DATA: mt_order  TYPE STANDARD TABLE OF ty_order WITH EMPTY KEY,
          mt_comp   TYPE STANDARD TABLE OF ty_comp WITH EMPTY KEY,
          mt_group  TYPE STANDARD TABLE OF ty_group WITH EMPTY KEY,
          mt_driver TYPE STANDARD TABLE OF ty_driver WITH EMPTY KEY,
          mo_alv    TYPE REF TO cl_salv_table,
          mv_info   TYPE string.

    METHODS read_orders.
    METHODS read_comps.
    METHODS read_groups.
    METHODS read_drivers.

    METHODS pct
      IMPORTING iv_ratio      TYPE numeric
      RETURNING VALUE(rv_pct) TYPE ty_pct.

    METHODS last_calc
      IMPORTING iv_ts          TYPE timestamp
      RETURNING VALUE(rv_text) TYPE string.

    METHODS display
      CHANGING ct_data TYPE STANDARD TABLE.

    METHODS set_texts.

    METHODS col_text
      IMPORTING iv_col  TYPE lvc_fname
                iv_text TYPE string.

    METHODS on_link_click FOR EVENT link_click OF cl_salv_events_table
      IMPORTING row column.

    METHODS on_double_click FOR EVENT double_click OF cl_salv_events_table
      IMPORTING row column.
ENDCLASS.

*----------------------------------------------------------------------*
CLASS lcl_app IMPLEMENTATION.

  METHOD run.
    CASE abap_true.
      WHEN r_ord.
        read_orders( ).
        SORT mt_order BY excess_value DESCENDING.
        display( CHANGING ct_data = mt_order ).
      WHEN r_comp.
        read_comps( ).
        SORT mt_comp BY excess_value DESCENDING.
        display( CHANGING ct_data = mt_comp ).
      WHEN r_grp.
        read_groups( ).
        display( CHANGING ct_data = mt_group ).
      WHEN r_drv.
        read_drivers( ).
        display( CHANGING ct_data = mt_driver ).
    ENDCASE.
  ENDMETHOD.

*----------------------------------------------------------------------*
  " ratio from Python (0.052) -> percent (5.20), limited so that it always fits
  METHOD pct.
    DATA(lv) = CONV decfloat34( iv_ratio ) * 100.
    rv_pct = nmax( val1 = nmin( val1 = lv val2 = CONV decfloat34( '99999' ) )
                   val2 = CONV decfloat34( '-99999' ) ).
  ENDMETHOD.

  METHOD last_calc.
    DATA: lv_d TYPE d,
          lv_t TYPE t.
    IF iv_ts IS INITIAL.
      rv_text = `no data yet`.
      RETURN.
    ENDIF.
    CONVERT TIME STAMP iv_ts TIME ZONE sy-zonlo INTO DATE lv_d TIME lv_t.
    rv_text = |last calculation { lv_d DATE = USER } { lv_t TIME = USER }|.
  ENDMETHOD.

*----------------------------------------------------------------------*
  METHOD read_orders.
    SELECT * FROM zpp_ord
      WHERE werks       IN @s_werks
        AND finish_date IN @s_date
        AND aufnr       IN @s_aufnr
        AND matnr       IN @s_matnr
      INTO TABLE @DATA(lt_db).

    DATA lv_max TYPE timestamp.
    LOOP AT lt_db ASSIGNING FIELD-SYMBOL(<d>).
      lv_max = nmax( val1 = lv_max val2 = <d>-calc_ts ).
      IF p_only = abap_true AND <d>-status <> 'RED'.
        CONTINUE.
      ENDIF.
      INSERT VALUE #(
        light                = SWITCH char1( <d>-status WHEN 'RED' THEN '1' WHEN 'YELLOW' THEN '2' ELSE '3' )
        order_no             = <d>-aufnr
        status               = <d>-status
        plant                = <d>-werks
        material             = <d>-matnr
        material_desc        = <d>-maktx
        material_group       = <d>-matkl
        order_type           = <d>-auart
        work_center          = <d>-arbpl
        shift                = <d>-shift
        prod_supervisor      = <d>-fevor
        actual_finish        = <d>-finish_date
        target_qty           = <d>-target_qty
        delivered_qty        = <d>-deliv_qty
        unit                 = <d>-meins
        own_issued_qty       = <d>-own_issued_qty
        planned_value        = <d>-plan_value
        actual_value         = <d>-act_value
        excess_value         = <d>-excess_value
        currency             = <d>-waers
        variance_pct         = pct( <d>-variance_pct )
        components           = <d>-comp_cnt
        flagged_components   = <d>-flag_cnt
        unplanned_components = <d>-unplan_cnt
        scrap_qty            = <d>-scrap_qty
        scrap_unit           = <d>-scrap_unit
        scrap_rate           = pct( <d>-scrap_rate )
        scrap_flag           = <d>-scrap_flag
        explanation          = <d>-explanation ) INTO TABLE mt_order.
    ENDLOOP.
    mv_info = last_calc( lv_max ).
  ENDMETHOD.

*----------------------------------------------------------------------*
  METHOD read_comps.
    SELECT * FROM zpp_comp
      WHERE werks       IN @s_werks
        AND finish_date IN @s_date
        AND aufnr       IN @s_aufnr
        AND matnr       IN @s_matnr
      INTO TABLE @DATA(lt_db).

    DATA lv_max TYPE timestamp.
    LOOP AT lt_db ASSIGNING FIELD-SYMBOL(<d>).
      lv_max = nmax( val1 = lv_max val2 = <d>-calc_ts ).
      IF p_only = abap_true AND <d>-flag IS INITIAL.
        CONTINUE.
      ENDIF.
      INSERT VALUE #(
        light                = SWITCH char1( <d>-flag WHEN 'OVER' OR 'WRONG MVT' THEN '1'
                                                      WHEN 'UNDER' OR 'NOT ISSUED' OR 'UNPLANNED' OR 'UNIT CHECK' THEN '2'
                                                      ELSE '3' )
        order_no             = <d>-aufnr
        item                 = <d>-item
        flag                 = <d>-flag
        plant                = <d>-werks
        material             = <d>-matnr
        material_group       = <d>-matkl
        work_center          = <d>-arbpl
        shift                = <d>-shift
        actual_finish        = <d>-finish_date
        component            = <d>-comp_matnr
        component_desc       = <d>-comp_desc
        component_group      = <d>-comp_matkl
        in_plan              = <d>-in_plan
        planned_qty          = <d>-plan_qty
        planned_for_actual   = <d>-plan_for_act
        actual_qty           = <d>-act_qty
        actual_without_reservation = <d>-act_nores_qty
        unit                 = <d>-meins
        variance_qty         = <d>-var_qty
        variance_pct         = pct( <d>-variance_pct )
        typical_variance_pct = pct( <d>-typ_var_pct )
        z_score              = <d>-z_score
        excess_value         = <d>-excess_value
        currency             = <d>-waers
        explanation          = <d>-explanation ) INTO TABLE mt_comp.
    ENDLOOP.
    mv_info = last_calc( lv_max ).
  ENDMETHOD.

*----------------------------------------------------------------------*
  METHOD read_groups.
    SELECT * FROM zpp_grp INTO TABLE @DATA(lt_db).

    DATA lv_max TYPE timestamp.
    LOOP AT lt_db ASSIGNING FIELD-SYMBOL(<d>).
      lv_max = nmax( val1 = lv_max val2 = <d>-calc_ts ).
      IF p_only = abap_true AND <d>-finding IS INITIAL.
        CONTINUE.
      ENDIF.
      INSERT VALUE #(
        light                = COND char1( WHEN <d>-finding IS NOT INITIAL THEN '2' ELSE '3' )
        dimension            = <d>-dimension
        group_name           = <d>-grp
        group_desc           = <d>-group_desc
        orders               = <d>-order_cnt
        value_share          = pct( <d>-value_share )
        variance_pct         = pct( <d>-variance_pct )
        others_variance_pct  = pct( <d>-oth_var_pct )
        difference_pp        = <d>-diff_pp
        variance_significant = <d>-var_signif
        excess_value         = <d>-excess_value
        scrap_rate           = pct( <d>-scrap_rate )
        others_scrap_rate    = pct( <d>-oth_scrap_rate )
        scrap_difference_pct = pct( <d>-scrap_diff_pct )
        scrap_significant    = <d>-scrap_signif
        finding              = <d>-finding ) INTO TABLE mt_group.
    ENDLOOP.
    mv_info = last_calc( lv_max ).
  ENDMETHOD.

*----------------------------------------------------------------------*
  METHOD read_drivers.
    SELECT * FROM zpp_drv INTO TABLE @DATA(lt_db).

    DATA lv_max TYPE timestamp.
    LOOP AT lt_db ASSIGNING FIELD-SYMBOL(<d>).
      lv_max = nmax( val1 = lv_max val2 = <d>-calc_ts ).
      INSERT VALUE #( target         = <d>-target
                      rank_no        = <d>-rank
                      driver         = <d>-driver
                      meaning        = <d>-meaning
                      importance_pct = <d>-importance_pct
                      model_r2       = <d>-model_r2 ) INTO TABLE mt_driver.
    ENDLOOP.
    mv_info = last_calc( lv_max ).
  ENDMETHOD.

*----------------------------------------------------------------------*
  METHOD display.
    IF ct_data IS INITIAL.
      MESSAGE 'No data found for this selection' TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
    ENDIF.

    TRY.
        cl_salv_table=>factory( IMPORTING r_salv_table = mo_alv CHANGING t_table = ct_data ).
      CATCH cx_salv_msg INTO DATA(lx).
        MESSAGE lx TYPE 'E'.
    ENDTRY.

    mo_alv->get_functions( )->set_all( abap_true ).
    mo_alv->get_display_settings( )->set_striped_pattern( abap_true ).
    mo_alv->get_display_settings( )->set_list_header(
      CONV #( |{ lines( ct_data ) } rows - { mv_info }| ) ).

    DATA(lo_layout) = mo_alv->get_layout( ).
    lo_layout->set_key( VALUE #( report = sy-repid handle = COND #( WHEN r_ord = abap_true THEN 'ORD'
                                                                     WHEN r_comp = abap_true THEN 'CMP'
                                                                     WHEN r_grp = abap_true THEN 'GRP'
                                                                     ELSE 'DRV' ) ) ).
    lo_layout->set_save_restriction( if_salv_c_layout=>restrict_none ).
    lo_layout->set_default( abap_true ).

    DATA(lo_cols) = mo_alv->get_columns( ).
    lo_cols->set_optimize( abap_true ).
    TRY.
        lo_cols->set_exception_column( 'LIGHT' ).
      CATCH cx_salv_data_error ##NO_HANDLER.
    ENDTRY.

    set_texts( ).

    " hotspots: order -> CO03, material / component -> MM03
    LOOP AT VALUE string_table( ( `ORDER_NO` ) ( `MATERIAL` ) ( `COMPONENT` ) ) INTO DATA(lv_hot).
      TRY.
          CAST cl_salv_column_table( lo_cols->get_column( CONV #( lv_hot ) ) )->set_cell_type(
            if_salv_c_cell_type=>hotspot ).
        CATCH cx_salv_not_found ##NO_HANDLER.
      ENDTRY.
    ENDLOOP.
    SET HANDLER on_link_click FOR mo_alv->get_event( ).
    SET HANDLER on_double_click FOR mo_alv->get_event( ).

    " totals
    DATA(lo_agg) = mo_alv->get_aggregations( ).
    LOOP AT VALUE string_table( ( `EXCESS_VALUE` ) ( `PLANNED_VALUE` ) ( `ACTUAL_VALUE` ) ) INTO DATA(lv_sum).
      TRY.
          lo_agg->add_aggregation( columnname = CONV #( lv_sum ) aggregation = if_salv_c_aggregation=>total ).
        CATCH cx_salv_not_found cx_salv_data_error cx_salv_existing ##NO_HANDLER.
      ENDTRY.
    ENDLOOP.

    mo_alv->display( ).
  ENDMETHOD.

*----------------------------------------------------------------------*
  METHOD col_text.
    TRY.
        DATA(lo_col) = mo_alv->get_columns( )->get_column( iv_col ).
        lo_col->set_long_text( CONV #( iv_text ) ).
        lo_col->set_medium_text( CONV #( substring( val = iv_text len = nmin( val1 = 20 val2 = strlen( iv_text ) ) ) ) ).
        lo_col->set_short_text( CONV #( substring( val = iv_text len = nmin( val1 = 10 val2 = strlen( iv_text ) ) ) ) ).
      CATCH cx_salv_not_found ##NO_HANDLER.
    ENDTRY.
  ENDMETHOD.

  METHOD set_texts.
    TYPES: BEGIN OF ty_t,
             col  TYPE lvc_fname,
             text TYPE string,
           END OF ty_t.
    DATA lt_t TYPE STANDARD TABLE OF ty_t WITH EMPTY KEY.
    lt_t = VALUE #(
      ( col = 'LIGHT'                text = 'Status light' )
      ( col = 'ORDER_NO'             text = 'Order' )
      ( col = 'STATUS'               text = 'Status' )
      ( col = 'PLANT'                text = 'Plant' )
      ( col = 'MATERIAL'             text = 'Product' )
      ( col = 'MATERIAL_DESC'        text = 'Product description' )
      ( col = 'MATERIAL_GROUP'       text = 'Product group' )
      ( col = 'ORDER_TYPE'           text = 'Order type' )
      ( col = 'WORK_CENTER'          text = 'Work center / line' )
      ( col = 'SHIFT'                text = 'Shift' )
      ( col = 'PROD_SUPERVISOR'      text = 'Prod. supervisor' )
      ( col = 'ACTUAL_FINISH'        text = 'Actual finish' )
      ( col = 'TARGET_QTY'           text = 'Target qty' )
      ( col = 'DELIVERED_QTY'        text = 'Delivered qty' )
      ( col = 'UNIT'                 text = 'Unit' )
      ( col = 'OWN_ISSUED_QTY'       text = 'Own product issued (correction)' )
      ( col = 'PLANNED_VALUE'        text = 'Raw mat. planned value' )
      ( col = 'ACTUAL_VALUE'         text = 'Raw mat. actual value' )
      ( col = 'EXCESS_VALUE'         text = 'Excess value (actual-plan)' )
      ( col = 'CURRENCY'             text = 'Currency' )
      ( col = 'VARIANCE_PCT'         text = 'Variance vs recipe %' )
      ( col = 'COMPONENTS'           text = 'Components' )
      ( col = 'FLAGGED_COMPONENTS'   text = 'Flagged components' )
      ( col = 'UNPLANNED_COMPONENTS' text = 'Materials not in order BOM' )
      ( col = 'IN_PLAN'              text = 'In order BOM' )
      ( col = 'ACTUAL_WITHOUT_RESERVATION' text = 'Issued without reservation' )
      ( col = 'SCRAP_QTY'            text = 'Scrap qty (mvt 531)' )
      ( col = 'SCRAP_UNIT'           text = 'Scrap unit' )
      ( col = 'SCRAP_RATE'           text = 'Scrap rate %' )
      ( col = 'SCRAP_FLAG'           text = 'Scrap flag' )
      ( col = 'EXPLANATION'          text = 'Explanation' )
      ( col = 'ITEM'                 text = 'Item' )
      ( col = 'FLAG'                 text = 'Flag' )
      ( col = 'COMPONENT'            text = 'Component' )
      ( col = 'COMPONENT_DESC'       text = 'Component description' )
      ( col = 'COMPONENT_GROUP'      text = 'Component group' )
      ( col = 'PLANNED_QTY'          text = 'Planned qty (order)' )
      ( col = 'PLANNED_FOR_ACTUAL'   text = 'Planned for delivered qty' )
      ( col = 'ACTUAL_QTY'           text = 'Actual qty issued (MATDOC)' )
      ( col = 'VARIANCE_QTY'         text = 'Variance qty' )
      ( col = 'TYPICAL_VARIANCE_PCT' text = 'Usual variance %' )
      ( col = 'Z_SCORE'              text = 'How unusual (z-score)' )
      ( col = 'DIMENSION'            text = 'Compared by' )
      ( col = 'GROUP_NAME'           text = 'Group' )
      ( col = 'GROUP_DESC'           text = 'Group description' )
      ( col = 'ORDERS'               text = 'Orders' )
      ( col = 'VALUE_SHARE'          text = 'Share of raw mat. value %' )
      ( col = 'OTHERS_VARIANCE_PCT'  text = 'Others variance %' )
      ( col = 'DIFFERENCE_PP'        text = 'Difference (points)' )
      ( col = 'VARIANCE_SIGNIFICANT' text = 'Variance diff. significant' )
      ( col = 'OTHERS_SCRAP_RATE'    text = 'Others scrap rate %' )
      ( col = 'SCRAP_DIFFERENCE_PCT' text = 'Scrap difference %' )
      ( col = 'SCRAP_SIGNIFICANT'    text = 'Scrap diff. significant' )
      ( col = 'FINDING'              text = 'Finding' )
      ( col = 'TARGET'               text = 'What is explained' )
      ( col = 'RANK_NO'              text = 'Rank' )
      ( col = 'DRIVER'               text = 'Driver (field)' )
      ( col = 'MEANING'              text = 'Driver' )
      ( col = 'IMPORTANCE_PCT'       text = 'Importance %' )
      ( col = 'MODEL_R2'             text = 'Model fit R2 (0-1)' ) ).
    LOOP AT lt_t ASSIGNING FIELD-SYMBOL(<t>).
      col_text( iv_col = <t>-col iv_text = <t>-text ).
    ENDLOOP.
  ENDMETHOD.

*----------------------------------------------------------------------*
  METHOD on_link_click.
    FIELD-SYMBOLS <lt> TYPE STANDARD TABLE.
    CASE abap_true.
      WHEN r_ord.  ASSIGN mt_order TO <lt>.
      WHEN r_comp. ASSIGN mt_comp TO <lt>.
      WHEN OTHERS. RETURN.
    ENDCASE.
    READ TABLE <lt> INDEX row ASSIGNING FIELD-SYMBOL(<ls>).
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.
    ASSIGN COMPONENT column OF STRUCTURE <ls> TO FIELD-SYMBOL(<v>).
    IF sy-subrc <> 0 OR <v> IS INITIAL.
      RETURN.
    ENDIF.
    TRY.
        CASE column.
          WHEN 'ORDER_NO'.
            DATA(lv_aufnr) = CONV aufnr( <v> ).
            SET PARAMETER ID 'ANR' FIELD lv_aufnr.
            CALL TRANSACTION 'CO03' WITH AUTHORITY-CHECK AND SKIP FIRST SCREEN.
          WHEN 'MATERIAL' OR 'COMPONENT'.
            DATA(lv_matnr) = CONV matnr( <v> ).
            SET PARAMETER ID 'MAT' FIELD lv_matnr.
            CALL TRANSACTION 'MM03' WITH AUTHORITY-CHECK AND SKIP FIRST SCREEN.
        ENDCASE.
      CATCH cx_sy_authorization_error.
        MESSAGE 'No authorization for this transaction' TYPE 'S' DISPLAY LIKE 'E'.
    ENDTRY.
  ENDMETHOD.


*----------------------------------------------------------------------*
  " double-click on EXPLANATION: full text in a popup (the grid shows max. ~128 characters)
  METHOD on_double_click.
    IF column <> 'EXPLANATION'.
      RETURN.
    ENDIF.
    FIELD-SYMBOLS <lt> TYPE STANDARD TABLE.
    CASE abap_true.
      WHEN r_ord.  ASSIGN mt_order TO <lt>.
      WHEN r_comp. ASSIGN mt_comp TO <lt>.
      WHEN OTHERS. RETURN.
    ENDCASE.
    READ TABLE <lt> INDEX row ASSIGNING FIELD-SYMBOL(<ls>).
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.
    ASSIGN COMPONENT 'EXPLANATION' OF STRUCTURE <ls> TO FIELD-SYMBOL(<v>).
    IF sy-subrc <> 0 OR <v> IS INITIAL.
      RETURN.
    ENDIF.

    TYPES: BEGIN OF ty_line,
             line TYPE c LENGTH 110,
           END OF ty_line.
    DATA lt_lines TYPE STANDARD TABLE OF ty_line WITH EMPTY KEY.
    DATA(lv_text) = condense( CONV string( <v> ) ).
    SPLIT lv_text AT ` | ` INTO TABLE DATA(lt_parts).
    LOOP AT lt_parts INTO DATA(lv_part).
      DATA(lv_rest) = lv_part.
      WHILE strlen( lv_rest ) > 110.
        DATA(lv_p) = find( val = reverse( substring( val = lv_rest len = 110 ) ) sub = ` ` ).
        DATA(lv_cut) = COND i( WHEN lv_p >= 0 AND lv_p < 60 THEN 109 - lv_p ELSE 110 ).
        APPEND VALUE #( line = substring( val = lv_rest len = lv_cut ) ) TO lt_lines.
        lv_rest = condense( substring( val = lv_rest off = lv_cut ) ).
      ENDWHILE.
      APPEND VALUE #( line = lv_rest ) TO lt_lines.
      APPEND VALUE #( ) TO lt_lines.
    ENDLOOP.

    TRY.
        cl_salv_table=>factory( IMPORTING r_salv_table = DATA(lo_pop) CHANGING t_table = lt_lines ).
        DATA(lo_c) = lo_pop->get_columns( ).
        lo_c->set_headers_visible( abap_false ).
        lo_c->set_optimize( abap_true ).
        lo_pop->set_screen_popup( start_column = 8 end_column = 130
                                  start_line   = 4 end_line   = 24 ).
        lo_pop->display( ).
      CATCH cx_salv_msg ##NO_HANDLER.
    ENDTRY.
  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
INITIALIZATION.
  sy-title = 'Production analysis - raw material and scrap (results)'.

  gv_t2 = '1. What do you want to see?'.
  c_ord  = 'Production orders - status RED/YELLOW/GREEN, excess cost, explanation'.
  c_comp = 'Components - planned vs actual quantity per order and material, flags'.
  c_grp  = 'Group comparison - product groups, work centers, shifts, supervisors'.
  c_drv  = 'Drivers - what explains raw-material variance and scrap (ML importance)'.

  gv_t3 = '2. Filters (orders and components views)'.
  c_d3  = 'Empty = show everything. Filters apply to orders and components only.'.
  c_only = 'Only problems (orders: RED; components: flagged; groups: with finding)'.

  %_s_werks_%_app_%-text = 'Plant'.
  %_s_date_%_app_%-text  = 'Order actual finish date'.
  %_s_aufnr_%_app_%-text = 'Production order'.
  %_s_matnr_%_app_%-text = 'Product'.

  " default: last 90 days
  APPEND VALUE #( sign = 'I' option = 'BT' low = sy-datum - 90 high = sy-datum ) TO s_date.

START-OF-SELECTION.
  NEW lcl_app( )->run( ).
