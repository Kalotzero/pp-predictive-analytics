*&---------------------------------------------------------------------*
*& Report zpp_bom_qty_check
*&---------------------------------------------------------------------*
*& Read-only check of production BOMs (usage 1) for implausible
*& component quantities (wrong quantity or unit in the BOM).
*& Reads MAST, STKO, STAS, STPO, MAKT only - changes nothing.
*&
*& A BOM item is listed when
*&  A) component unit = BOM base unit and the quantity is more than
*&     FACTOR x the BOM base quantity (e.g. 35,000 KG cement in a BOM
*&     with base quantity 100 KG),
*&  B) the quantity per base quantity is more than FACTOR x the median
*&     of the same component/unit in the same plant (min. 5 BOMs), or
*&  C) the quantity is above the absolute limit (if given).
*& Fixed-quantity items (STPO-FMENG) are ignored for A and B.
*&---------------------------------------------------------------------*
REPORT zpp_bom_qty_check.

DATA gv_werks TYPE mast-werks.
DATA gv_matnr TYPE mast-matnr.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE t_b1.
SELECT-OPTIONS s_werks FOR gv_werks.
SELECT-OPTIONS s_matnr FOR gv_matnr.
PARAMETERS p_stlan TYPE mast-stlan DEFAULT '1'.
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE t_b2.
PARAMETERS p_fac TYPE i DEFAULT 50.
PARAMETERS p_abs TYPE p LENGTH 13 DECIMALS 0 DEFAULT 0.
PARAMETERS p_all AS CHECKBOX DEFAULT ' '.
SELECTION-SCREEN END OF BLOCK b2.

CLASS lcl_report DEFINITION FINAL.
  PUBLIC SECTION.
    METHODS run.
  PRIVATE SECTION.
    TYPES ty_ratio TYPE p LENGTH 16 DECIMALS 6.
    TYPES:
      BEGIN OF ty_item,
        werks TYPE mast-werks,
        matnr TYPE mast-matnr,
        stlal TYPE mast-stlal,
        stlnr TYPE mast-stlnr,
        stlkn TYPE stpo-stlkn,
        idnrk TYPE stpo-idnrk,
        menge TYPE stpo-menge,
        meins TYPE stpo-meins,
        fmeng TYPE stpo-fmeng,
        bmeng TYPE stko-bmeng,
        bmein TYPE stko-bmein,
        stlst TYPE stko-stlst,
        datuv TYPE stko-datuv,
        ratio TYPE ty_ratio,
      END OF ty_item,
      BEGIN OF ty_out,
        werks    TYPE mast-werks,
        matnr    TYPE mast-matnr,
        maktx    TYPE makt-maktx,
        stlal    TYPE mast-stlal,
        stlnr    TYPE mast-stlnr,
        stlkn    TYPE stpo-stlkn,
        idnrk    TYPE stpo-idnrk,
        comp_txt TYPE makt-maktx,
        menge    TYPE stpo-menge,
        meins    TYPE stpo-meins,
        bmeng    TYPE stko-bmeng,
        bmein    TYPE stko-bmein,
        ratio    TYPE ty_ratio,
        med      TYPE ty_ratio,
        factor   TYPE p LENGTH 12 DECIMALS 1,
        reason   TYPE c LENGTH 40,
        stlst    TYPE stko-stlst,
        datuv    TYPE stko-datuv,
      END OF ty_out.
    TYPES:
      BEGIN OF ty_stko,
        stlnr TYPE stko-stlnr,
        stlal TYPE stko-stlal,
        datuv TYPE stko-datuv,
        bmein TYPE stko-bmein,
        bmeng TYPE stko-bmeng,
        stlst TYPE stko-stlst,
        loekz TYPE stko-loekz,
      END OF ty_stko,
      BEGIN OF ty_stas,
        stlnr TYPE stas-stlnr,
        stlal TYPE stas-stlal,
        stlkn TYPE stas-stlkn,
        datuv TYPE stas-datuv,
        lkenz TYPE stas-lkenz,
      END OF ty_stas,
      BEGIN OF ty_stpo,
        stlnr TYPE stpo-stlnr,
        stlkn TYPE stpo-stlkn,
        stpoz TYPE stpo-stpoz,
        datuv TYPE stpo-datuv,
        idnrk TYPE stpo-idnrk,
        menge TYPE stpo-menge,
        meins TYPE stpo-meins,
        fmeng TYPE stpo-fmeng,
        lkenz TYPE stpo-lkenz,
      END OF ty_stpo,
      BEGIN OF ty_med,
        werks TYPE mast-werks,
        idnrk TYPE stpo-idnrk,
        meins TYPE stpo-meins,
        med   TYPE ty_ratio,
        cnt   TYPE i,
      END OF ty_med.
    DATA mt_item TYPE STANDARD TABLE OF ty_item WITH EMPTY KEY.
    DATA mt_out  TYPE STANDARD TABLE OF ty_out WITH EMPTY KEY.
    METHODS select_data.
    METHODS evaluate.
    METHODS add_texts.
    METHODS show.
ENDCLASS.

CLASS lcl_report IMPLEMENTATION.

  METHOD run.
    select_data( ).
    IF mt_item IS INITIAL.
      MESSAGE 'No BOM items found for the selection' TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
    ENDIF.
    evaluate( ).
    IF mt_out IS INITIAL.
      MESSAGE 'No implausible BOM quantities found' TYPE 'S'.
      RETURN.
    ENDIF.
    add_texts( ).
    show( ).
  ENDMETHOD.

  METHOD select_data.
    SELECT matnr, werks, stlnr, stlal
      FROM mast
      WHERE stlan = @p_stlan AND werks IN @s_werks AND matnr IN @s_matnr
      INTO TABLE @DATA(lt_mast).
    IF lt_mast IS INITIAL.
      RETURN.
    ENDIF.

    " newest valid version of each alternative
    SELECT stlnr, stlal, datuv, bmein, bmeng, stlst, loekz
      FROM stko
      FOR ALL ENTRIES IN @lt_mast
      WHERE stlty = 'M' AND stlnr = @lt_mast-stlnr AND stlal = @lt_mast-stlal
        AND datuv <= @sy-datum
      INTO TABLE @DATA(lt_stko).
    SORT lt_stko BY stlnr ASCENDING stlal ASCENDING datuv DESCENDING.
    DELETE ADJACENT DUPLICATES FROM lt_stko COMPARING stlnr stlal.
    DELETE lt_stko WHERE loekz = 'X'.
    IF lt_stko IS INITIAL.
      RETURN.
    ENDIF.
    DATA lt_stko_s TYPE SORTED TABLE OF ty_stko WITH UNIQUE KEY stlnr stlal.
    lt_stko_s = CORRESPONDING #( lt_stko ).

    " items of each alternative (STAS), newest valid version, not deleted
    SELECT stlnr, stlal, stlkn, datuv, lkenz
      FROM stas
      FOR ALL ENTRIES IN @lt_stko
      WHERE stlty = 'M' AND stlnr = @lt_stko-stlnr AND stlal = @lt_stko-stlal
        AND datuv <= @sy-datum
      INTO TABLE @DATA(lt_stas).
    SORT lt_stas BY stlnr ASCENDING stlal ASCENDING stlkn ASCENDING datuv DESCENDING.
    DELETE ADJACENT DUPLICATES FROM lt_stas COMPARING stlnr stlal stlkn.
    DELETE lt_stas WHERE lkenz = 'X'.
    IF lt_stas IS INITIAL.
      RETURN.
    ENDIF.
    DATA lt_stas_s TYPE SORTED TABLE OF ty_stas WITH NON-UNIQUE KEY stlnr stlal.
    lt_stas_s = CORRESPONDING #( lt_stas ).

    " item data (STPO), newest valid version, not deleted, no text items
    SELECT stlnr, stlkn, stpoz, datuv, idnrk, menge, meins, fmeng, lkenz
      FROM stpo
      FOR ALL ENTRIES IN @lt_stas
      WHERE stlty = 'M' AND stlnr = @lt_stas-stlnr AND stlkn = @lt_stas-stlkn
        AND datuv <= @sy-datum AND postp <> 'T'
      INTO TABLE @DATA(lt_stpo).
    SORT lt_stpo BY stlnr ASCENDING stlkn ASCENDING datuv DESCENDING stpoz DESCENDING.
    DELETE ADJACENT DUPLICATES FROM lt_stpo COMPARING stlnr stlkn.
    DELETE lt_stpo WHERE lkenz = 'X' OR idnrk IS INITIAL.
    DATA lt_stpo_s TYPE SORTED TABLE OF ty_stpo WITH UNIQUE KEY stlnr stlkn.
    lt_stpo_s = CORRESPONDING #( lt_stpo ).

    LOOP AT lt_mast INTO DATA(ls_mast).
      READ TABLE lt_stko_s INTO DATA(ls_stko)
           WITH TABLE KEY stlnr = ls_mast-stlnr stlal = ls_mast-stlal.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      LOOP AT lt_stas_s INTO DATA(ls_stas)
           WHERE stlnr = ls_mast-stlnr AND stlal = ls_mast-stlal.
        READ TABLE lt_stpo_s INTO DATA(ls_stpo)
             WITH TABLE KEY stlnr = ls_stas-stlnr stlkn = ls_stas-stlkn.
        IF sy-subrc <> 0.
          CONTINUE.
        ENDIF.
        DATA(ls_item) = VALUE ty_item( werks = ls_mast-werks matnr = ls_mast-matnr
                                       stlal = ls_mast-stlal stlnr = ls_mast-stlnr
                                       stlkn = ls_stpo-stlkn idnrk = ls_stpo-idnrk
                                       menge = ls_stpo-menge meins = ls_stpo-meins
                                       fmeng = ls_stpo-fmeng bmeng = ls_stko-bmeng
                                       bmein = ls_stko-bmein stlst = ls_stko-stlst
                                       datuv = ls_stko-datuv ).
        IF ls_item-fmeng <> 'X' AND ls_item-bmeng > 0 AND ls_item-meins = ls_item-bmein
           AND ls_item-menge > 0.
          ls_item-ratio = ls_item-menge / ls_item-bmeng.
        ENDIF.
        APPEND ls_item TO mt_item.
      ENDLOOP.
    ENDLOOP.
  ENDMETHOD.

  METHOD evaluate.
    " median quantity per base quantity: same component + unit + plant
    DATA lt_r LIKE mt_item.
    lt_r = mt_item.
    DELETE lt_r WHERE ratio <= 0.
    SORT lt_r BY werks idnrk meins ratio.
    DATA lt_med TYPE HASHED TABLE OF ty_med WITH UNIQUE KEY werks idnrk meins.
    LOOP AT lt_r INTO DATA(ls_r)
         GROUP BY ( werks = ls_r-werks idnrk = ls_r-idnrk meins = ls_r-meins size = GROUP SIZE )
         INTO DATA(ls_g).
      IF ls_g-size < 5.
        CONTINUE.
      ENDIF.
      DATA lt_m TYPE STANDARD TABLE OF ty_ratio WITH EMPTY KEY.
      CLEAR lt_m.
      LOOP AT GROUP ls_g INTO DATA(ls_member).
        APPEND ls_member-ratio TO lt_m.
      ENDLOOP.
      INSERT VALUE ty_med( werks = ls_g-werks idnrk = ls_g-idnrk meins = ls_g-meins
                           med = lt_m[ ( lines( lt_m ) + 1 ) / 2 ] cnt = ls_g-size ) INTO TABLE lt_med.
    ENDLOOP.

    LOOP AT mt_item INTO DATA(ls_i).
      DATA(lv_reason) = ``.
      DATA(lv_factor) = CONV decfloat34( 0 ).
      DATA(lv_med) = CONV ty_ratio( 0 ).
      READ TABLE lt_med INTO DATA(ls_med)
           WITH TABLE KEY werks = ls_i-werks idnrk = ls_i-idnrk meins = ls_i-meins.
      IF sy-subrc = 0.
        lv_med = ls_med-med.
      ENDIF.
      IF ls_i-ratio > 0 AND ls_i-ratio > p_fac.
        lv_reason = |QTY > { p_fac } x BASE QTY|.
        lv_factor = ls_i-ratio.
      ENDIF.
      IF lv_med > 0 AND ls_i-ratio > lv_med * p_fac.
        lv_reason = COND #( WHEN lv_reason IS INITIAL THEN |QTY > { p_fac } x MEDIAN (n={ ls_med-cnt })|
                            ELSE lv_reason && | + MEDIAN| ).
        lv_factor = ls_i-ratio / lv_med.
      ENDIF.
      IF p_abs > 0 AND ls_i-menge > p_abs.
        lv_reason = COND #( WHEN lv_reason IS INITIAL THEN `QTY > ABSOLUTE LIMIT`
                            ELSE lv_reason && | + ABS| ).
        IF lv_factor = 0.
          lv_factor = ls_i-menge / p_abs.
        ENDIF.
      ENDIF.
      IF lv_reason IS INITIAL AND p_all = abap_false.
        CONTINUE.
      ENDIF.
      APPEND VALUE ty_out( werks = ls_i-werks matnr = ls_i-matnr stlal = ls_i-stlal
                           stlnr = ls_i-stlnr stlkn = ls_i-stlkn idnrk = ls_i-idnrk
                           menge = ls_i-menge meins = ls_i-meins bmeng = ls_i-bmeng
                           bmein = ls_i-bmein ratio = ls_i-ratio med = lv_med
                           factor = lv_factor reason = lv_reason
                           stlst = ls_i-stlst datuv = ls_i-datuv ) TO mt_out.
    ENDLOOP.
    SORT mt_out BY factor DESCENDING werks matnr.
  ENDMETHOD.

  METHOD add_texts.
    TYPES: BEGIN OF ty_mat, matnr TYPE makt-matnr, END OF ty_mat.
    DATA lt_mat TYPE SORTED TABLE OF ty_mat WITH UNIQUE KEY matnr.
    LOOP AT mt_out INTO DATA(ls_o).
      INSERT VALUE #( matnr = ls_o-matnr ) INTO TABLE lt_mat.
      INSERT VALUE #( matnr = ls_o-idnrk ) INTO TABLE lt_mat.
    ENDLOOP.
    SELECT matnr, maktx FROM makt
      FOR ALL ENTRIES IN @lt_mat
      WHERE matnr = @lt_mat-matnr AND spras = @sy-langu
      INTO TABLE @DATA(lt_makt).
    SORT lt_makt BY matnr.
    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<o>).
      READ TABLE lt_makt INTO DATA(ls_t) WITH KEY matnr = <o>-matnr BINARY SEARCH.
      IF sy-subrc = 0.
        <o>-maktx = ls_t-maktx.
      ENDIF.
      READ TABLE lt_makt INTO ls_t WITH KEY matnr = <o>-idnrk BINARY SEARCH.
      IF sy-subrc = 0.
        <o>-comp_txt = ls_t-maktx.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

  METHOD show.
    TRY.
        cl_salv_table=>factory( IMPORTING r_salv_table = DATA(lo_alv)
                                CHANGING  t_table      = mt_out ).
        lo_alv->get_functions( )->set_all( abap_true ).
        lo_alv->get_display_settings( )->set_list_header(
          |BOM check - { lines( mt_out ) } items with implausible quantity (factor { p_fac })| ).
        lo_alv->get_display_settings( )->set_striped_pattern( abap_true ).
        DATA(lo_cols) = lo_alv->get_columns( ).
        lo_cols->set_optimize( abap_true ).
        lo_cols->get_column( 'WERKS' )->set_short_text( 'Plant' ).
        lo_cols->get_column( 'MATNR' )->set_short_text( 'Product' ).
        lo_cols->get_column( 'MAKTX' )->set_short_text( 'Prod.text' ).
        lo_cols->get_column( 'STLAL' )->set_short_text( 'Alt' ).
        lo_cols->get_column( 'STLNR' )->set_short_text( 'BOM' ).
        lo_cols->get_column( 'STLKN' )->set_short_text( 'Node' ).
        lo_cols->get_column( 'IDNRK' )->set_short_text( 'Component' ).
        lo_cols->get_column( 'COMP_TXT' )->set_short_text( 'Comp.text' ).
        lo_cols->get_column( 'MENGE' )->set_short_text( 'Quantity' ).
        lo_cols->get_column( 'MEINS' )->set_short_text( 'Unit' ).
        lo_cols->get_column( 'BMENG' )->set_short_text( 'Base qty' ).
        lo_cols->get_column( 'BMEIN' )->set_short_text( 'Base unit' ).
        lo_cols->get_column( 'RATIO' )->set_short_text( 'Qty/Base' ).
        lo_cols->get_column( 'MED' )->set_short_text( 'Median' ).
        lo_cols->get_column( 'FACTOR' )->set_short_text( 'Factor' ).
        lo_cols->get_column( 'REASON' )->set_short_text( 'Reason' ).
        lo_cols->get_column( 'STLST' )->set_short_text( 'Status' ).
        lo_cols->get_column( 'DATUV' )->set_short_text( 'Valid from' ).
        lo_alv->display( ).
      CATCH cx_salv_msg cx_salv_not_found INTO DATA(lx).
        MESSAGE lx TYPE 'E'.
    ENDTRY.
  ENDMETHOD.

ENDCLASS.

INITIALIZATION.
  t_b1 = 'Selection'.
  t_b2 = 'Rules'.

START-OF-SELECTION.
  NEW lcl_report( )->run( ).
