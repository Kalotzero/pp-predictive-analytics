@EndUserText.label : 'PP prediction: drivers of variance and scrap'
@AbapCatalog.enhancement.category : #NOT_EXTENSIBLE
@AbapCatalog.tableCategory : #TRANSPARENT
@AbapCatalog.deliveryClass : #A
@AbapCatalog.dataMaintenance : #RESTRICTED
define table zpp_drv {
  key mandt         : abap.clnt not null;
  key target        : abap.char(30) not null;
  key rank          : abap.numc(3) not null;
  driver            : abap.char(30);
  meaning           : abap.char(60);
  importance_pct    : abap.dec(17,5);
  model_r2          : abap.dec(17,5);
  calc_ts           : abap.dec(15,0);
}
