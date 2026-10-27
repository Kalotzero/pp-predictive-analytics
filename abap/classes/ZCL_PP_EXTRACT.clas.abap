"! Production data extract for predictive analytics, as a service class.
"! Same CSV layout as report ZPP_PRED_EXTRACT (orders, components, wrong movements),
"! but returned as strings (no GUI), for the REST handler ZCL_PP_REST.
"! Selection: finished orders (AFKO-GETRI in a date window) and, for a delta, only
"! the orders with new material documents / confirmations / order changes since a time.
CLASS zcl_pp_extract DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    TYPES: tt_werks TYPE RANGE OF aufk-werks,
           BEGIN OF ty_result,
             orders     TYPE string,
             components TYPE string,
             wrongmvt   TYPE string,
             order_cnt  TYPE i,
             last_order TYPE string,
             more       TYPE i,
           END OF ty_result.

    "! One page of orders (sorted by order number, after iv_after, max iv_max orders).
    "! iv_since_date initial = all finished orders of the window (full load).
    METHODS get_delta
      IMPORTING iv_from          TYPE d
                iv_to            TYPE d
                iv_since_date    TYPE d OPTIONAL
                iv_since_time    TYPE t OPTIONAL
                it_werks         TYPE tt_werks OPTIONAL
                iv_after         TYPE aufnr OPTIONAL
                iv_max           TYPE i DEFAULT 300
                iv_lang          TYPE spras DEFAULT 'E'
      RETURNING VALUE(rs_result) TYPE ty_result.

  PRIVATE SECTION.
    CONSTANTS c_sep TYPE c LENGTH 1 VALUE ';'.

    TYPES: ty_num TYPE p LENGTH 16 DECIMALS 5,
           tt_aufnr TYPE STANDARD TABLE OF aufnr WITH EMPTY KEY,

           BEGIN OF ty_order,
             aufnr TYPE afko-aufnr,
             werks TYPE aufk-werks,
             auart TYPE aufk-auart,
             dispo TYPE afko-dispo,
             fevor TYPE afko-fevor,
             gstrp TYPE afko-gstrp,
             gltrp TYPE afko-gltrp,
             getri TYPE afko-getri,
             matnr TYPE afpo-matnr,
             psmng TYPE afpo-psmng,
             wemng TYPE afpo-wemng,
             amein TYPE afpo-amein,
             matkl TYPE mara-matkl,
             maktx TYPE makt-maktx,
           END OF ty_order,

           BEGIN OF ty_conf,
             aufnr TYPE afru-aufnr,
             arbid TYPE afru-arbid,
             isdd  TYPE afru-isdd,
             isdz  TYPE afru-isdz,
             iedd  TYPE afru-iedd,
             iedz  TYPE afru-iedz,
             ism01 TYPE afru-ism01,
             ism02 TYPE afru-ism02,
             ism03 TYPE afru-ism03,
             ile01 TYPE afru-ile01,
           END OF ty_conf,

           BEGIN OF ty_csum,
             aufnr  TYPE afru-aufnr,
             arbid  TYPE afru-arbid,
             start  TYPE c LENGTH 14,
             finish TYPE c LENGTH 14,
             setup  TYPE ty_num,
             mach   TYPE ty_num,
             labor  TYPE ty_num,
             unit   TYPE afru-ile01,
             cnt    TYPE i,
           END OF ty_csum,

           BEGIN OF ty_comp,
             aufnr   TYPE resb-aufnr,
             matnr   TYPE resb-matnr,
             kind    TYPE c LENGTH 3,
             werks   TYPE resb-werks,
             rspos   TYPE resb-rspos,
             meins   TYPE resb-meins,
             fmeng   TYPE resb-fmeng,
             in_plan TYPE abap_bool,
             planned TYPE ty_num,
             actual  TYPE ty_num,
             unres   TYPE ty_num,
           END OF ty_comp,
           tt_comp TYPE HASHED TABLE OF ty_comp WITH UNIQUE KEY aufnr matnr kind.

    DATA: mt_aufnr TYPE RANGE OF aufnr,
          mv_lang  TYPE spras,
          mt_wc    TYPE HASHED TABLE OF crhd WITH UNIQUE KEY objty objid.

    METHODS select_orders
      IMPORTING iv_from          TYPE d
                iv_to            TYPE d
                iv_since_date    TYPE d
                iv_since_time    TYPE t
                it_werks         TYPE tt_werks
                iv_after         TYPE aufnr
                iv_limit         TYPE i
      RETURNING VALUE(rt_aufnr)  TYPE tt_aufnr.

    METHODS extract_orders     RETURNING VALUE(rv_csv) TYPE string.
    METHODS extract_components RETURNING VALUE(rv_csv) TYPE string.
    METHODS extract_wrong      RETURNING VALUE(rv_csv) TYPE string.

    METHODS join_lines
      IMPORTING it_lines      TYPE string_table
      RETURNING VALUE(rv_out) TYPE string.
    METHODS t
      IMPORTING iv_val        TYPE simple
      RETURNING VALUE(rv_out) TYPE string.
    METHODS n
      IMPORTING iv_val        TYPE ty_num
      RETURNING VALUE(rv_out) TYPE string.
    METHODS dt
      IMPORTING iv_val        TYPE d
      RETURNING VALUE(rv_out) TYPE string.
    METHODS ts
      IMPORTING iv_val        TYPE csequence
      RETURNING VALUE(rv_out) TYPE string.
    METHODS ext
      IMPORTING iv_val        TYPE simple
      RETURNING VALUE(rv_out) TYPE string.
ENDCLASS.



CLASS zcl_pp_extract IMPLEMENTATION.

  METHOD get_delta.
    DATA(lt_a) = select_orders( iv_from       = iv_from
                                iv_to         = iv_to
                                iv_since_date = iv_since_date
                                iv_since_time = iv_since_time
                                it_werks      = it_werks
                                iv_after      = iv_after
                                iv_limit      = iv_max + 1 ).
    IF lines( lt_a ) > iv_max.
      rs_result-more = 1.
      DELETE lt_a FROM iv_max + 1.
    ENDIF.
    rs_result-order_cnt = lines( lt_a ).
    IF lt_a IS INITIAL.
      RETURN.
    ENDIF.

    rs_result-last_order = |{ lt_a[ lines( lt_a ) ] ALPHA = OUT }|.
    mt_aufnr = VALUE #( FOR a IN lt_a ( sign = 'I' option = 'EQ' low = a ) ).
    mv_lang  = iv_lang.

    rs_result-orders     = extract_orders( ).
    rs_result-components = extract_components( ).
    rs_result-wrongmvt   = extract_wrong( ).
  ENDMETHOD.

  METHOD select_orders.
    DATA: lt_chg TYPE SORTED TABLE OF aufnr WITH UNIQUE KEY table_line,
          lt_f   TYPE tt_aufnr.

    IF iv_since_date IS INITIAL.
      " full load: all finished orders of the window
      SELECT k~aufnr
        FROM afko AS k
        INNER JOIN aufk AS u ON u~aufnr = k~aufnr
        INNER JOIN afpo AS p ON p~aufnr = k~aufnr AND p~posnr = '0001'
        WHERE k~getri BETWEEN @iv_from AND @iv_to
          AND k~aufnr > @iv_after
          AND u~werks IN @it_werks
        ORDER BY k~aufnr
        INTO TABLE @rt_aufnr
        UP TO @iv_limit ROWS.
      RETURN.
    ENDIF.

    " delta: orders touched since iv_since_date / iv_since_time
    SELECT DISTINCT aufnr
      FROM matdoc
      WHERE ( cpudt > @iv_since_date OR ( cpudt = @iv_since_date AND cputm >= @iv_since_time ) )
        AND record_type = 'MDOC'
        AND aufnr <> @space
        AND bwart IN ('261', '262', '531', '532')
      INTO TABLE @DATA(lt_m).
    LOOP AT lt_m ASSIGNING FIELD-SYMBOL(<m>).
      INSERT <m>-aufnr INTO TABLE lt_chg.
    ENDLOOP.

    SELECT DISTINCT aufnr
      FROM afru
      WHERE ( ersda > @iv_since_date OR ( ersda = @iv_since_date AND erzet >= @iv_since_time ) )
      INTO TABLE @DATA(lt_c).
    LOOP AT lt_c ASSIGNING FIELD-SYMBOL(<c>).
      INSERT <c>-aufnr INTO TABLE lt_chg.
    ENDLOOP.

    " orders finished or changed since that date
    SELECT k~aufnr
      FROM afko AS k
      INNER JOIN aufk AS u ON u~aufnr = k~aufnr
      WHERE k~getri BETWEEN @iv_from AND @iv_to
        AND ( k~getri >= @iv_since_date OR u~aedat >= @iv_since_date )
      INTO TABLE @DATA(lt_o).
    LOOP AT lt_o ASSIGNING FIELD-SYMBOL(<o>).
      INSERT <o>-aufnr INTO TABLE lt_chg.
    ENDLOOP.

    IF lt_chg IS INITIAL.
      RETURN.
    ENDIF.

    SELECT k~aufnr
      FROM afko AS k
      INNER JOIN aufk AS u ON u~aufnr = k~aufnr
      INNER JOIN afpo AS p ON p~aufnr = k~aufnr AND p~posnr = '0001'
      FOR ALL ENTRIES IN @lt_chg
      WHERE k~aufnr = @lt_chg-table_line
        AND k~getri BETWEEN @iv_from AND @iv_to
        AND u~werks IN @it_werks
      INTO TABLE @lt_f.

    SORT lt_f.
    DELETE ADJACENT DUPLICATES FROM lt_f.
    DELETE lt_f WHERE table_line <= iv_after.
    IF lines( lt_f ) > iv_limit.
      DELETE lt_f FROM iv_limit + 1.
    ENDIF.
    rt_aufnr = lt_f.
  ENDMETHOD.

  METHOD extract_orders.
    DATA: lt_orders TYPE STANDARD TABLE OF ty_order WITH EMPTY KEY,
          lt_conf   TYPE STANDARD TABLE OF ty_conf WITH EMPTY KEY,
          lt_csum   TYPE HASHED TABLE OF ty_csum WITH UNIQUE KEY aufnr,
          lt_lines  TYPE string_table,
          lv_s      TYPE c LENGTH 14,
          lv_e      TYPE c LENGTH 14.

    SELECT k~aufnr, u~werks, u~auart, k~dispo, k~fevor, k~gstrp, k~gltrp, k~getri,
           p~matnr, p~psmng, p~wemng, p~amein, m~matkl, t~maktx
      FROM afko AS k
      INNER JOIN aufk AS u ON u~aufnr = k~aufnr
      INNER JOIN afpo AS p ON p~aufnr = k~aufnr AND p~posnr = '0001'
      INNER JOIN mara AS m ON m~matnr = p~matnr
      LEFT OUTER JOIN makt AS t ON t~matnr = p~matnr AND t~spras = @mv_lang
      WHERE k~aufnr IN @mt_aufnr
      INTO TABLE @lt_orders.

    IF lt_orders IS INITIAL.
      RETURN.
    ENDIF.

    " confirmations (reversed and reversal records excluded)
    SELECT a~aufnr, a~arbid, a~isdd, a~isdz, a~iedd, a~iedz, a~ism01, a~ism02, a~ism03, a~ile01
      FROM afru AS a
      WHERE a~aufnr IN @mt_aufnr
        AND a~stokz = @space
        AND a~stzhl = '00000000'
      INTO TABLE @lt_conf.

    LOOP AT lt_conf ASSIGNING FIELD-SYMBOL(<f>).
      lv_s = |{ <f>-isdd }{ <f>-isdz }|.
      lv_e = |{ <f>-iedd }{ <f>-iedz }|.
      READ TABLE lt_csum ASSIGNING FIELD-SYMBOL(<s>) WITH TABLE KEY aufnr = <f>-aufnr.
      IF sy-subrc <> 0.
        INSERT VALUE #( aufnr = <f>-aufnr arbid = <f>-arbid start = lv_s finish = lv_e
                        unit = <f>-ile01 ) INTO TABLE lt_csum ASSIGNING <s>.
      ENDIF.
      IF lv_s < <s>-start AND <f>-isdd IS NOT INITIAL.
        <s>-start = lv_s.
        <s>-arbid = <f>-arbid.
      ENDIF.
      IF lv_e > <s>-finish.
        <s>-finish = lv_e.
      ENDIF.
      <s>-setup = <s>-setup + <f>-ism01.
      <s>-mach  = <s>-mach + <f>-ism02.
      <s>-labor = <s>-labor + <f>-ism03.
      <s>-cnt   = <s>-cnt + 1.
    ENDLOOP.

    IF mt_wc IS INITIAL.
      SELECT * FROM crhd WHERE objty = 'A' INTO TABLE @mt_wc.
    ENDIF.

    APPEND |order;plant;order_type;mrp_controller;prod_supervisor;sched_start;sched_finish;| &&
           |actual_finish;material;material_desc;material_group;target_qty;delivered_qty;unit;| &&
           |work_center;conf_start;conf_finish;setup_time;machine_time;labor_time;time_unit;| &&
           |confirmations| TO lt_lines.

    LOOP AT lt_orders ASSIGNING FIELD-SYMBOL(<o>).
      DATA(lv_wc) = ``.
      DATA(lv_cs) = ``.
      DATA(lv_cf) = ``.
      DATA(lv_st) = ``.
      DATA(lv_mt) = ``.
      DATA(lv_lt) = ``.
      DATA(lv_un) = ``.
      DATA(lv_cn) = `0`.
      READ TABLE lt_csum ASSIGNING <s> WITH TABLE KEY aufnr = <o>-aufnr.
      IF sy-subrc = 0.
        READ TABLE mt_wc ASSIGNING FIELD-SYMBOL(<w>) WITH TABLE KEY objty = 'A' objid = <s>-arbid.
        IF sy-subrc = 0.
          lv_wc = t( <w>-arbpl ).
        ENDIF.
        lv_cs = ts( <s>-start ).
        lv_cf = ts( <s>-finish ).
        lv_st = n( <s>-setup ).
        lv_mt = n( <s>-mach ).
        lv_lt = n( <s>-labor ).
        lv_un = t( <s>-unit ).
        lv_cn = |{ <s>-cnt }|.
      ENDIF.

      APPEND ext( <o>-aufnr ) && c_sep && t( <o>-werks ) && c_sep && t( <o>-auart ) && c_sep &&
             t( <o>-dispo ) && c_sep && t( <o>-fevor ) && c_sep && dt( <o>-gstrp ) && c_sep &&
             dt( <o>-gltrp ) && c_sep && dt( <o>-getri ) && c_sep && ext( <o>-matnr ) && c_sep &&
             t( <o>-maktx ) && c_sep && t( <o>-matkl ) && c_sep &&
             n( CONV ty_num( <o>-psmng ) ) && c_sep && n( CONV ty_num( <o>-wemng ) ) && c_sep &&
             t( <o>-amein ) && c_sep && lv_wc && c_sep && lv_cs && c_sep && lv_cf && c_sep &&
             lv_st && c_sep && lv_mt && c_sep && lv_lt && c_sep && lv_un && c_sep && lv_cn
        TO lt_lines.
    ENDLOOP.

    rv_csv = join_lines( lt_lines ).
  ENDMETHOD.

  METHOD extract_components.
    TYPES: BEGIN OF ty_mat,
             matnr TYPE mara-matnr,
             werks TYPE resb-werks,
           END OF ty_mat,
           BEGIN OF ty_md,
             matnr TYPE mara-matnr,
             matkl TYPE mara-matkl,
             maktx TYPE makt-maktx,
           END OF ty_md,
           BEGIN OF ty_pr,
             matnr TYPE mbew-matnr,
             bwkey TYPE mbew-bwkey,
             vprsv TYPE mbew-vprsv,
             verpr TYPE mbew-verpr,
             stprs TYPE mbew-stprs,
             peinh TYPE mbew-peinh,
           END OF ty_pr,
           BEGIN OF ty_cur,
             bwkey TYPE t001k-bwkey,
             waers TYPE t001-waers,
           END OF ty_cur.

    DATA: lt_comp  TYPE tt_comp,
          lt_mat   TYPE SORTED TABLE OF ty_mat WITH UNIQUE KEY matnr werks,
          lt_md    TYPE HASHED TABLE OF ty_md WITH UNIQUE KEY matnr,
          lt_pr    TYPE HASHED TABLE OF ty_pr WITH UNIQUE KEY matnr bwkey,
          lt_cur   TYPE HASHED TABLE OF ty_cur WITH UNIQUE KEY bwkey,
          lt_lines TYPE string_table,
          lv_price TYPE ty_num,
          lv_qty   TYPE ty_num.

    " 1. plan: components of the production orders (order BOM)
    SELECT r~aufnr, r~rspos, r~werks, r~matnr, r~bwart, r~bdmng, r~meins, r~fmeng
      FROM resb AS r
      WHERE r~aufnr IN @mt_aufnr
        AND r~bwart IN ('261', '531')
      INTO TABLE @DATA(lt_resb).

    LOOP AT lt_resb ASSIGNING FIELD-SYMBOL(<r>).
      READ TABLE lt_comp ASSIGNING FIELD-SYMBOL(<c>)
           WITH TABLE KEY aufnr = <r>-aufnr matnr = <r>-matnr kind = <r>-bwart.
      IF sy-subrc <> 0.
        INSERT VALUE #( aufnr = <r>-aufnr matnr = <r>-matnr kind = <r>-bwart werks = <r>-werks
                        rspos = <r>-rspos meins = <r>-meins fmeng = <r>-fmeng in_plan = abap_true )
               INTO TABLE lt_comp ASSIGNING <c>.
      ENDIF.
      <c>-planned = <c>-planned + <r>-bdmng.
    ENDLOOP.
    FREE lt_resb.

    " 2. actual: material documents of the orders (incl. issues without reservation)
    SELECT d~aufnr, d~matnr, d~werks, d~bwart, d~meins, d~rsnum, SUM( d~menge ) AS menge
      FROM matdoc AS d
      WHERE d~aufnr IN @mt_aufnr
        AND d~record_type = 'MDOC'
        AND d~bwart IN ('261', '262', '531', '532')
      GROUP BY d~aufnr, d~matnr, d~werks, d~bwart, d~meins, d~rsnum
      INTO TABLE @DATA(lt_md_doc).

    LOOP AT lt_md_doc ASSIGNING FIELD-SYMBOL(<d>).
      DATA(lv_kind) = COND char3( WHEN <d>-bwart = '261' OR <d>-bwart = '262' THEN '261' ELSE '531' ).
      lv_qty = COND #( WHEN <d>-bwart = '262' OR <d>-bwart = '532' THEN - <d>-menge ELSE <d>-menge ).
      READ TABLE lt_comp ASSIGNING <c> WITH TABLE KEY aufnr = <d>-aufnr matnr = <d>-matnr kind = lv_kind.
      IF sy-subrc <> 0.
        INSERT VALUE #( aufnr = <d>-aufnr matnr = <d>-matnr kind = lv_kind werks = <d>-werks
                        meins = <d>-meins in_plan = abap_false )
               INTO TABLE lt_comp ASSIGNING <c>.
      ENDIF.
      <c>-actual = <c>-actual + lv_qty.
      IF <d>-rsnum IS INITIAL OR <d>-rsnum = '0000000000'.
        <c>-unres = <c>-unres + lv_qty.
      ENDIF.
    ENDLOOP.
    FREE lt_md_doc.

    IF lt_comp IS INITIAL.
      RETURN.
    ENDIF.

    " 3. master data: description, group, price, currency
    LOOP AT lt_comp ASSIGNING <c>.
      INSERT VALUE #( matnr = <c>-matnr werks = <c>-werks ) INTO TABLE lt_mat.
    ENDLOOP.
    SELECT m~matnr, m~matkl, t~maktx
      FROM mara AS m
      LEFT OUTER JOIN makt AS t ON t~matnr = m~matnr AND t~spras = @mv_lang
      FOR ALL ENTRIES IN @lt_mat
      WHERE m~matnr = @lt_mat-matnr
      INTO TABLE @lt_md.
    SELECT matnr, bwkey, vprsv, verpr, stprs, peinh
      FROM mbew
      FOR ALL ENTRIES IN @lt_mat
      WHERE matnr = @lt_mat-matnr
        AND bwkey = @lt_mat-werks
        AND bwtar = @space
      INTO TABLE @lt_pr.
    SELECT k~bwkey, c~waers
      FROM t001k AS k
      INNER JOIN t001 AS c ON c~bukrs = k~bukrs
      FOR ALL ENTRIES IN @lt_mat
      WHERE k~bwkey = @lt_mat-werks
      INTO TABLE @lt_cur.

    APPEND |order;item;plant;component;component_desc;component_group;movement_type;in_plan;| &&
           |planned_qty;actual_qty;actual_without_reservation;unit;fixed_qty;price_per_unit;currency|
      TO lt_lines.

    LOOP AT lt_comp ASSIGNING <c>.
      READ TABLE lt_md ASSIGNING FIELD-SYMBOL(<m>) WITH TABLE KEY matnr = <c>-matnr.
      READ TABLE lt_pr ASSIGNING FIELD-SYMBOL(<p>) WITH TABLE KEY matnr = <c>-matnr bwkey = <c>-werks.
      IF sy-subrc = 0 AND <p>-peinh > 0.
        lv_price = COND #( WHEN <p>-vprsv = 'S' THEN <p>-stprs ELSE <p>-verpr ) / <p>-peinh.
      ELSE.
        lv_price = 0.
      ENDIF.
      READ TABLE lt_cur ASSIGNING FIELD-SYMBOL(<w>) WITH TABLE KEY bwkey = <c>-werks.

      APPEND ext( <c>-aufnr ) && c_sep && t( <c>-rspos ) && c_sep && t( <c>-werks ) && c_sep &&
             ext( <c>-matnr ) && c_sep &&
             COND string( WHEN <m> IS ASSIGNED THEN t( <m>-maktx ) ) && c_sep &&
             COND string( WHEN <m> IS ASSIGNED THEN t( <m>-matkl ) ) && c_sep &&
             t( <c>-kind ) && c_sep && t( <c>-in_plan ) && c_sep &&
             n( <c>-planned ) && c_sep && n( <c>-actual ) && c_sep && n( <c>-unres ) && c_sep &&
             t( <c>-meins ) && c_sep && t( <c>-fmeng ) && c_sep && n( lv_price ) && c_sep &&
             COND string( WHEN <w> IS ASSIGNED THEN t( <w>-waers ) )
        TO lt_lines.
      UNASSIGN: <m>, <p>, <w>.
    ENDLOOP.

    rv_csv = join_lines( lt_lines ).
  ENDMETHOD.

  METHOD extract_wrong.
    DATA: lt_lines TYPE string_table,
          lv_qty   TYPE ty_num.

    SELECT d~aufnr, d~werks, d~matnr, d~bwart, d~mblnr, d~mjahr, d~zeile, d~budat, d~cpudt,
           d~usnam, d~menge, d~meins, d~lgort
      FROM matdoc AS d
      INNER JOIN afpo AS p ON p~aufnr = d~aufnr AND p~posnr = '0001' AND p~matnr = d~matnr
      WHERE d~aufnr IN @mt_aufnr
        AND d~record_type = 'MDOC'
        AND d~bwart IN ('261', '262')
      INTO TABLE @DATA(lt_w).

    APPEND |order;plant;material;movement_type;doc;year;item;posting_date;entry_date;user;qty;unit;| &&
           |storage_loc|
      TO lt_lines.

    LOOP AT lt_w ASSIGNING FIELD-SYMBOL(<w>).
      lv_qty = COND #( WHEN <w>-bwart = '262' THEN - <w>-menge ELSE <w>-menge ).
      APPEND ext( <w>-aufnr ) && c_sep && t( <w>-werks ) && c_sep && ext( <w>-matnr ) && c_sep &&
             t( <w>-bwart ) && c_sep && t( <w>-mblnr ) && c_sep && t( <w>-mjahr ) && c_sep &&
             t( <w>-zeile ) && c_sep && dt( <w>-budat ) && c_sep && dt( <w>-cpudt ) && c_sep &&
             t( <w>-usnam ) && c_sep && n( lv_qty ) && c_sep && t( <w>-meins ) && c_sep &&
             t( <w>-lgort )
        TO lt_lines.
    ENDLOOP.

    rv_csv = join_lines( lt_lines ).
  ENDMETHOD.

  METHOD join_lines.
    " header only = no data
    IF lines( it_lines ) < 2.
      RETURN.
    ENDIF.
    rv_out = concat_lines_of( table = it_lines sep = cl_abap_char_utilities=>newline ).
  ENDMETHOD.

  METHOD t.
    DATA(lv_s) = condense( val = CONV string( iv_val ) del = ` ` ).
    IF lv_s IS INITIAL.
      rv_out = ``.
    ELSE.
      lv_s = replace( val = lv_s sub = cl_abap_char_utilities=>newline with = ` ` occ = 0 ).
      rv_out = `"` && replace( val = lv_s sub = `"` with = `""` occ = 0 ) && `"`.
    ENDIF.
  ENDMETHOD.

  METHOD n.
    rv_out = |{ iv_val }|.
  ENDMETHOD.

  METHOD dt.
    IF iv_val IS INITIAL OR iv_val = '00000000'.
      rv_out = ``.
    ELSE.
      rv_out = |{ iv_val DATE = ISO }|.
    ENDIF.
  ENDMETHOD.

  METHOD ts.
    IF strlen( iv_val ) < 14 OR iv_val(8) = '00000000'.
      rv_out = ``.
    ELSE.
      rv_out = |{ iv_val(4) }-{ iv_val+4(2) }-{ iv_val+6(2) } { iv_val+8(2) }:{ iv_val+10(2) }:{ iv_val+12(2) }|.
    ENDIF.
  ENDMETHOD.

  METHOD ext.
    rv_out = t( |{ iv_val ALPHA = OUT }| ).
  ENDMETHOD.

ENDCLASS.
