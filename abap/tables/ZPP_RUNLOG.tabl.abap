@EndUserText.label : 'PP prediction: run log'
@AbapCatalog.enhancement.category : #NOT_EXTENSIBLE
@AbapCatalog.tableCategory : #TRANSPARENT
@AbapCatalog.deliveryClass : #A
@AbapCatalog.dataMaintenance : #RESTRICTED
define table zpp_runlog {
  key mandt         : abap.clnt not null;
  key run_id        : abap.char(30) not null;
  run_ts            : abap.dec(15,0);
  run_mode          : abap.char(10);
  order_cnt         : abap.int4;
  comp_cnt          : abap.int4;
  status            : abap.char(10);
  message           : abap.char(200);
  uname             : abap.char(12);
}
