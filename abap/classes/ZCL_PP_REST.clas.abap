CLASS zcl_pp_rest DEFINITION
  PUBLIC
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_http_extension.

  PRIVATE SECTION.
    TYPES: BEGIN OF ty_in,
             run_id     TYPE string,
             run_mode   TYPE string,
             orders     TYPE STANDARD TABLE OF zpp_ord  WITH DEFAULT KEY,
             components TYPE STANDARD TABLE OF zpp_comp WITH DEFAULT KEY,
             groups     TYPE STANDARD TABLE OF zpp_grp  WITH DEFAULT KEY,
             drivers    TYPE STANDARD TABLE OF zpp_drv  WITH DEFAULT KEY,
           END OF ty_in,
           BEGIN OF ty_out.
             INCLUDE TYPE zcl_pp_extract=>ty_result.
    TYPES:   server_time TYPE string,
           END OF ty_out,
           BEGIN OF ty_ack,
             ok         TYPE abap_bool,
             orders     TYPE i,
             components TYPE i,
             groups     TYPE i,
             drivers    TYPE i,
           END OF ty_ack,
           BEGIN OF ty_err,
             ok    TYPE abap_bool,
             error TYPE string,
           END OF ty_err,
           BEGIN OF ty_ping,
             ok          TYPE abap_bool,
             server_time TYPE string,
             client      TYPE string,
             system      TYPE string,
           END OF ty_ping.

    METHODS get_delta
      IMPORTING io_server TYPE REF TO if_http_server.
    METHODS post_results
      IMPORTING io_server TYPE REF TO if_http_server.
    METHODS reply
      IMPORTING io_server TYPE REF TO if_http_server
                iv_code   TYPE i
                iv_json   TYPE string.
    METHODS error
      IMPORTING io_server TYPE REF TO if_http_server
                iv_code   TYPE i
                iv_text   TYPE string.
    METHODS authorized
      IMPORTING iv_actvt        TYPE activ_auth
      RETURNING VALUE(rv_ok)    TYPE abap_bool.
    METHODS now
      RETURNING VALUE(rv_ts) TYPE string.
    METHODS to_date
      IMPORTING iv_text        TYPE string
      RETURNING VALUE(rv_date) TYPE d.
    METHODS matnr_in
      IMPORTING iv_in         TYPE matnr
      RETURNING VALUE(rv_out) TYPE matnr.
ENDCLASS.



CLASS zcl_pp_rest IMPLEMENTATION.

  METHOD authorized.
    AUTHORITY-CHECK OBJECT 'S_TABU_NAM'
      ID 'ACTVT' FIELD iv_actvt
      ID 'TABLE' FIELD 'ZPP_ORD'.
    rv_ok = xsdbool( sy-subrc = 0 ).
  ENDMETHOD.


  METHOD if_http_extension~handle_request.
    DATA(lv_action) = to_lower( server->request->get_form_field( 'action' ) ).
    DATA(lv_method) = server->request->get_method( ).

    TRY.
        CASE lv_action.
          WHEN 'ping'.
            reply( io_server = server
                   iv_code   = 200
                   iv_json   = /ui2/cl_json=>serialize(
                                 data        = VALUE ty_ping( ok = abap_true server_time = now( )
                                                              client = sy-mandt system = sy-sysid )
                                 pretty_name = /ui2/cl_json=>pretty_mode-low_case ) ).
          WHEN 'delta'.
            IF authorized( '03' ) = abap_false.
              error( io_server = server iv_code = 403 iv_text = `not authorized (S_TABU_NAM display ZPP_ORD)` ).
            ELSEIF lv_method <> 'GET'.
              error( io_server = server iv_code = 405 iv_text = `use GET` ).
            ELSE.
              get_delta( server ).
            ENDIF.
          WHEN 'results'.
            IF authorized( '02' ) = abap_false.
              error( io_server = server iv_code = 403 iv_text = `not authorized (S_TABU_NAM change ZPP_ORD)` ).
            ELSEIF lv_method <> 'POST'.
              error( io_server = server iv_code = 405 iv_text = `use POST` ).
            ELSE.
              post_results( server ).
            ENDIF.
          WHEN OTHERS.
            error( io_server = server iv_code = 400 iv_text = `unknown action, use ping, delta or results` ).
        ENDCASE.
      CATCH cx_root INTO DATA(lx).
        ROLLBACK WORK.
        error( io_server = server iv_code = 500 iv_text = lx->get_text( ) ).
    ENDTRY.
  ENDMETHOD.

  METHOD get_delta.
    DATA: lt_werks TYPE zcl_pp_extract=>tt_werks,
          lv_since_d TYPE d,
          lv_since_t TYPE t,
          lv_max   TYPE i.

    DATA(lo_req)   = io_server->request.
    DATA(lv_from)  = lo_req->get_form_field( 'from' ).
    DATA(lv_to)    = lo_req->get_form_field( 'to' ).
    DATA(lv_since) = lo_req->get_form_field( 'since' ).
    DATA(lv_plant) = lo_req->get_form_field( 'plant' ).
    DATA(lv_after) = lo_req->get_form_field( 'after' ).
    DATA(lv_maxs)  = lo_req->get_form_field( 'max' ).

    DATA(lv_from_d) = COND d( WHEN lv_from IS INITIAL THEN sy-datum - 730 ELSE to_date( lv_from ) ).
    DATA(lv_to_d)   = COND d( WHEN lv_to IS INITIAL THEN sy-datum ELSE to_date( lv_to ) ).
    IF lv_from_d IS INITIAL OR lv_to_d IS INITIAL.
      error( io_server = io_server iv_code = 400 iv_text = `from/to must be YYYYMMDD` ).
      RETURN.
    ENDIF.

    IF lv_since IS NOT INITIAL.
      IF strlen( lv_since ) <> 14 OR lv_since CN '0123456789'.
        error( io_server = io_server iv_code = 400 iv_text = `since must be YYYYMMDDHHMMSS` ).
        RETURN.
      ENDIF.
      lv_since_d = lv_since(8).
      lv_since_t = lv_since+8(6).
    ENDIF.

    IF lv_plant IS NOT INITIAL.
      SPLIT lv_plant AT ',' INTO TABLE DATA(lt_p).
      lt_werks = VALUE #( FOR p IN lt_p ( sign = 'I' option = 'EQ' low = condense( p ) ) ).
    ENDIF.

    lv_max = 300.
    IF lv_maxs IS NOT INITIAL AND lv_maxs CO '0123456789'.
      lv_max = nmin( val1 = CONV i( lv_maxs ) val2 = 1000 ).
      lv_max = nmax( val1 = lv_max val2 = 1 ).
    ENDIF.

    DATA(lv_after_n) = CONV aufnr( |{ lv_after ALPHA = IN }| ).
    DATA(lv_time)    = now( ).

    DATA(ls_res) = NEW zcl_pp_extract( )->get_delta( iv_from       = lv_from_d
                                                        iv_to         = lv_to_d
                                                        iv_since_date = lv_since_d
                                                        iv_since_time = lv_since_t
                                                        it_werks      = lt_werks
                                                        iv_after      = lv_after_n
                                                        iv_max        = lv_max ).
    DATA ls_out TYPE ty_out.
    MOVE-CORRESPONDING ls_res TO ls_out.
    ls_out-server_time = lv_time.

    reply( io_server = io_server
           iv_code   = 200
           iv_json   = /ui2/cl_json=>serialize( data        = ls_out
                                                pretty_name = /ui2/cl_json=>pretty_mode-low_case ) ).
  ENDMETHOD.

  METHOD post_results.
    DATA: ls_in   TYPE ty_in,
          lv_ts   TYPE timestamp,
          lt_nr   TYPE SORTED TABLE OF aufnr WITH UNIQUE KEY table_line,
          lv_line TYPE n LENGTH 4,
          lv_prev TYPE aufnr.

    DATA(lv_body) = io_server->request->get_cdata( ).
    IF lv_body IS INITIAL.
      error( io_server = io_server iv_code = 400 iv_text = `empty body` ).
      RETURN.
    ENDIF.

    /ui2/cl_json=>deserialize( EXPORTING json        = lv_body
                                         pretty_name = /ui2/cl_json=>pretty_mode-low_case
                               CHANGING  data        = ls_in ).

    GET TIME STAMP FIELD lv_ts.

    LOOP AT ls_in-orders ASSIGNING FIELD-SYMBOL(<o>).
      <o>-aufnr   = |{ <o>-aufnr ALPHA = IN }|.
      <o>-matnr   = matnr_in( <o>-matnr ).
      <o>-calc_ts = lv_ts.
      INSERT <o>-aufnr INTO TABLE lt_nr.
    ENDLOOP.

    SORT ls_in-components STABLE BY aufnr.
    LOOP AT ls_in-components ASSIGNING FIELD-SYMBOL(<c>).
      <c>-aufnr      = |{ <c>-aufnr ALPHA = IN }|.
      <c>-matnr      = matnr_in( <c>-matnr ).
      <c>-comp_matnr = matnr_in( <c>-comp_matnr ).
      <c>-calc_ts    = lv_ts.
      IF <c>-aufnr <> lv_prev.
        lv_prev = <c>-aufnr.
        CLEAR lv_line.
      ENDIF.
      lv_line = lv_line + 1.
      <c>-line = lv_line.
    ENDLOOP.

    " replace the stored component lines of the orders in this request
    LOOP AT lt_nr ASSIGNING FIELD-SYMBOL(<nr>).
      DELETE FROM zpp_comp WHERE aufnr = @<nr>.
    ENDLOOP.
    IF ls_in-orders IS NOT INITIAL.
      MODIFY zpp_ord FROM TABLE @ls_in-orders.
    ENDIF.
    IF ls_in-components IS NOT INITIAL.
      MODIFY zpp_comp FROM TABLE @ls_in-components.
    ENDIF.

    IF ls_in-groups IS NOT INITIAL.
      LOOP AT ls_in-groups ASSIGNING FIELD-SYMBOL(<g>).
        <g>-calc_ts = lv_ts.
      ENDLOOP.
      DELETE FROM zpp_grp.
      MODIFY zpp_grp FROM TABLE @ls_in-groups.
    ENDIF.

    IF ls_in-drivers IS NOT INITIAL.
      LOOP AT ls_in-drivers ASSIGNING FIELD-SYMBOL(<d>).
        <d>-calc_ts = lv_ts.
      ENDLOOP.
      DELETE FROM zpp_drv.
      MODIFY zpp_drv FROM TABLE @ls_in-drivers.
    ENDIF.

    DATA(ls_log) = VALUE zpp_runlog( run_id    = COND #( WHEN ls_in-run_id IS INITIAL THEN now( ) ELSE ls_in-run_id )
                                        run_ts    = lv_ts
                                        run_mode  = ls_in-run_mode
                                        order_cnt = lines( ls_in-orders )
                                        comp_cnt  = lines( ls_in-components )
                                        status    = 'OK'
                                        message   = |groups { lines( ls_in-groups ) }, drivers { lines( ls_in-drivers ) }|
                                        uname     = sy-uname ).
    MODIFY zpp_runlog FROM @ls_log.

    COMMIT WORK.

    reply( io_server = io_server
           iv_code   = 200
           iv_json   = /ui2/cl_json=>serialize(
                         data        = VALUE ty_ack( ok         = abap_true
                                                     orders     = lines( ls_in-orders )
                                                     components = lines( ls_in-components )
                                                     groups     = lines( ls_in-groups )
                                                     drivers    = lines( ls_in-drivers ) )
                         pretty_name = /ui2/cl_json=>pretty_mode-low_case ) ).
  ENDMETHOD.

  METHOD reply.
    io_server->response->set_header_field( name = 'Cache-Control' value = 'no-store' ).
    io_server->response->set_content_type( 'application/json; charset=utf-8' ).
    io_server->response->set_cdata( iv_json ).
    io_server->response->set_status( code = iv_code reason = SWITCH #( iv_code WHEN 200 THEN 'OK' ELSE 'Error' ) ).
  ENDMETHOD.

  METHOD error.
    reply( io_server = io_server
           iv_code   = iv_code
           iv_json   = /ui2/cl_json=>serialize( data        = VALUE ty_err( ok = abap_false error = iv_text )
                                                pretty_name = /ui2/cl_json=>pretty_mode-low_case ) ).
  ENDMETHOD.

  METHOD now.
    rv_ts = |{ sy-datum }{ sy-uzeit }|.
  ENDMETHOD.

  METHOD to_date.
    IF strlen( iv_text ) = 8 AND iv_text CO '0123456789'.
      DATA(lv_d) = CONV d( iv_text ).
      CALL FUNCTION 'DATE_CHECK_PLAUSIBILITY'
        EXPORTING  date                      = lv_d
        EXCEPTIONS plausibility_check_failed = 1
                   OTHERS                    = 2.
      IF sy-subrc = 0.
        rv_date = lv_d.
      ENDIF.
    ENDIF.
  ENDMETHOD.

  METHOD matnr_in.
    CALL FUNCTION 'CONVERSION_EXIT_MATN1_INPUT'
      EXPORTING  input        = iv_in
      IMPORTING  output       = rv_out
      EXCEPTIONS length_error = 1
                 OTHERS       = 2.
    IF sy-subrc <> 0.
      rv_out = iv_in.
    ENDIF.
  ENDMETHOD.

ENDCLASS.
