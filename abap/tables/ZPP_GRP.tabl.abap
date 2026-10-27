@EndUserText.label : 'PP prediction: group comparison'
@AbapCatalog.enhancement.category : #NOT_EXTENSIBLE
@AbapCatalog.tableCategory : #TRANSPARENT
@AbapCatalog.deliveryClass : #A
@AbapCatalog.dataMaintenance : #RESTRICTED
define table zpp_grp {
  key mandt         : abap.clnt not null;
  key dimension     : abap.char(30) not null;
  key grp           : abap.char(40) not null;
  group_desc        : abap.char(60);
  order_cnt         : abap.int4;
  value_share       : abap.dec(17,5);
  variance_pct      : abap.dec(17,5);
  oth_var_pct       : abap.dec(17,5);
  diff_pp           : abap.dec(17,5);
  var_signif        : abap.char(3);
  excess_value      : abap.dec(17,5);
  scrap_rate        : abap.dec(17,5);
  oth_scrap_rate    : abap.dec(17,5);
  scrap_diff_pct    : abap.dec(17,5);
  scrap_signif      : abap.char(3);
  finding           : abap.string(0);
  calc_ts           : abap.dec(15,0);
}
