@EndUserText.label : 'PP prediction: component result per order'
@AbapCatalog.enhancement.category : #NOT_EXTENSIBLE
@AbapCatalog.tableCategory : #TRANSPARENT
@AbapCatalog.deliveryClass : #A
@AbapCatalog.dataMaintenance : #RESTRICTED
define table zpp_comp {
  key mandt         : abap.clnt not null;
  key aufnr         : aufnr not null;
  key line          : abap.numc(4) not null;
  item              : abap.char(4);
  flag              : abap.char(12);
  werks             : werks_d;
  matnr             : matnr;
  matkl             : matkl;
  arbpl             : abap.char(8);
  shift             : abap.char(20);
  finish_date       : abap.dats;
  comp_matnr        : matnr;
  comp_desc         : abap.char(40);
  comp_matkl        : matkl;
  in_plan           : abap.char(1);
  plan_qty          : abap.dec(17,5);
  plan_for_act      : abap.dec(17,5);
  act_qty           : abap.dec(17,5);
  act_nores_qty     : abap.dec(17,5);
  meins             : abap.unit(3);
  var_qty           : abap.dec(17,5);
  variance_pct      : abap.dec(17,5);
  typ_var_pct       : abap.dec(17,5);
  z_score           : abap.dec(17,5);
  excess_value      : abap.dec(17,5);
  waers             : abap.cuky(5);
  explanation       : abap.string(0);
  calc_ts           : abap.dec(15,0);
}
