
-define(TBALE,sql_config).

-record(sql_config,{
          tab,               %%表名
					next_id=0       %%next id,
				   }).