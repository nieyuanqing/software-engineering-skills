SET default_transaction_read_only = on;
SELECT c.table_name || chr(9) || c.column_name || chr(9) ||
  CASE
    WHEN c.data_type = 'character varying' AND c.character_maximum_length IS NOT NULL
      THEN 'character varying(' || c.character_maximum_length || ')'
    WHEN c.data_type = 'numeric' AND c.numeric_precision IS NOT NULL
      THEN 'numeric(' || c.numeric_precision || ',' || coalesce(c.numeric_scale, 0) || ')'
    ELSE c.data_type
  END || chr(9) || upper(c.is_nullable) || chr(9) || coalesce(c.column_default, '')
FROM information_schema.columns c
WHERE c.table_schema = :'schema'
ORDER BY c.table_name, c.column_name;
