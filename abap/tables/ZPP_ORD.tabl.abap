@EndUserText.label : 'PP prediction: production order result'
@AbapCatalog.enhancement.category : #NOT_EXTENSIBLE
@AbapCatalog.tableCategory : #TRANSPARENT
@AbapCatalog.deliveryClass : #A
@AbapCatalog.dataMaintenance : #RESTRICTED
define table zpp_ord {
  key mandt         : abap.clnt not null;
  key aufnr         : aufnr not null;
  status            : abap.char(6);
  werks             : werks_d;
  matnr             : matnr;
  maktx             : abap.char(40);
  matkl             : matkl;
  auart             : aufart;
  arbpl             : abap.char(8);
  shift             : abap.char(20);
  fevor             : abap.char(3);
  finish_date       : abap.dats;
  target_qty        : abap.dec(17,5);
  deliv_qty         : abap.dec(17,5);
  meins             : abap.unit(3);
  own_issued_qty    : abap.dec(17,5);
  plan_value        : abap.dec(17,5);
  act_value         : abap.dec(17,5);
  excess_value      : abap.dec(17,5);
  waers             : abap.cuky(5);
  variance_pct      : abap.dec(17,5);
  comp_cnt          : abap.int4;
  flag_cnt          : abap.int4;
  unplan_cnt        : abap.int4;
  scrap_qty         : abap.dec(17,5);
  scrap_unit        : abap.unit(3);
  scrap_rate        : abap.dec(17,5);
  scrap_flag        : abap.char(12);
  explanation       : abap.string(0);
  calc_ts           : abap.dec(15,0);
}
