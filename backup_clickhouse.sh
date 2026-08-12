# If oc available use oc, otherwise use kubectl
CMD=oc
if ! command -v $CMD &> /dev/null
then
    CMD=kubectl
fi

BASE_PATH="."
if [ -n "$1" ]; then
  BASE_PATH="$1"
fi

DB_LIST="nwdaf ai"

CURRENT=$(date +%Y%m%d_%H%M%S)

for db in $DB_LIST; do
  OUT=${BASE_PATH}/clickhouse_schema_${db}_${CURRENT}.sql
  echo $OUT

  echo "
SELECT concat('SHOW CREATE TABLE ', database, '.', name)
FROM system.tables
WHERE database = '${db}' AND name NOT LIKE '.inner.%' AND name NOT LIKE '_tmp_%'" | \
    $CMD exec -i -n nwdaf sts/clickhouse-shard0 -c clickhouse -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD}' | \
      while read q; do
        echo $q
        echo "$q FORMAT LineAsString" | \
          $CMD exec -i -n nwdaf sts/clickhouse-shard0 -c clickhouse -- bash -c 'clickhouse-client --password ${CLICKHOUSE_ADMIN_PASSWORD}' | \
          perl -0777 -pe 's/\n+\z/;\n\n/' >> "$OUT"
      done
  echo ""
done