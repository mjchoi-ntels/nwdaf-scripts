# If oc available use oc, otherwise use kubectl
CMD=oc
if ! command -v $CMD &> /dev/null
then
    CMD=kubectl
fi

CLICKHOUSE_PODS=$($CMD get pod -n nwdaf -l app.kubernetes.io/component=clickhouse -o name)

for pod in $CLICKHOUSE_PODS;
do
  # Drop 3g kafka table
  $CMD exec -it $pod -c clickhouse -n nwdaf -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf --query="DROP TABLE conn_kafka_source_ipmdn_3g"'
  # Create 3g kafka table
  echo "
CREATE TABLE conn_kafka_source_ipmdn_3g
(
    _user_name String,
    _nas_ip_address String,
    _service_type UInt8,
    _framed_protocol UInt8,
    _framed_ip_address String,
    _framed_ipv6_prefix String,
    _called_station_id String,
    _calling_station_id String,
    _calling_station_id_usernm String,
    _calling_station_id_min String,
    _nas_identifier String,
    _acct_status_type UInt8,
    _acct_input_octets UInt64,
    _acct_output_octets UInt64,
    _acct_session_id String,
    _acct_session_time UInt64,
    _acct_input_packets UInt64,
    _acct_output_packets UInt64,
    _acct_terminate_cause UInt8,
    _event_timestamp String,
    _nas_port_type UInt8,
    _acct_input_gigawords UInt32,
    _acct_output_gigawords UInt32,
    _3gpp_imsi String,
    _3gpp_charging_id String,
    _3gpp_pdp_type UInt8,
    _3gpp_charging_gateway_address String,
    _3gpp_gprs_negotiated_qos_profile String,
    _3gpp_sgsn_address String,
    _3gpp_ggsn_address String,
    _3gpp_imsi_mcc_mnc String,
    _3gpp_ggsn_mcc_mnc String,
    _3gpp_nsapi String,
    _3gpp_selection_mode String,
    _3gpp_charging_characteristics String,
    _3gpp_sgsn_mcc_mnc String,
    _3gpp_imeisv String,
    _3gpp_rat_type UInt8,
    _3gpp_user_location_info String,
    _3gpp_user_location_info_location_type String,
    _3gpp_ms_timezone String
)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'kafka-kafka-bootstrap.strimzi-kafka.svc.cluster.local:9092',
         kafka_topic_list = 'ipmdn-nwdaf-3g',
         kafka_group_name = 'nwdaf-clickhouse',
         kafka_format = 'CSV',
         kafka_num_consumers = 4,
         kafka_thread_per_consumer = 1,
         kafka_max_block_size = 100000,
         kafka_skip_broken_messages = 100000,
         kafka_poll_max_batch_size = 100000,
         kafka_poll_timeout_ms = 500,
         kafka_flush_interval_ms = 5000;" | $CMD exec -i $pod -c clickhouse -n nwdaf -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf'
  echo "Recreated 3G Kafka Table [$pod]"

  # Drop 4g kafka table
  $CMD exec -it $pod -c clickhouse -n nwdaf -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf --query="DROP TABLE conn_kafka_source_ipmdn_4g"'
  # Create 4g kafka table
  echo "
CREATE TABLE conn_kafka_source_ipmdn_4g
(
    _user_name String,
    _nas_ip_address String,
    _service_type UInt8,
    _framed_protocol UInt8,
    _framed_ip_address String,
    _framed_ipv6_prefix String,
    _called_station_id String,
    _calling_station_id String,
    _calling_station_id_usernm String,
    _calling_station_id_min String,
    _nas_identifier String,
    _acct_status_type UInt8,
    _acct_input_octets UInt64,
    _acct_output_octets UInt64,
    _acct_session_id String,
    _acct_session_time UInt64,
    _acct_input_packets UInt64,
    _acct_output_packets UInt64,
    _acct_terminate_cause UInt8,
    _event_timestamp String,
    _nas_port_type UInt8,
    _acct_input_gigawords UInt32,
    _acct_output_gigawords UInt32,
    _3gpp_imsi String,
    _3gpp_charging_id String,
    _3gpp_pdp_type UInt8,
    _3gpp_charging_gateway_address String,
    _3gpp_gprs_negotiated_qos_profile String,
    _3gpp_sgsn_address String,
    _3gpp_ggsn_address String,
    _3gpp_imsi_mcc_mnc String,
    _3gpp_ggsn_mcc_mnc String,
    _3gpp_nsapi String,
    _3gpp_selection_mode String,
    _3gpp_charging_characteristics String,
    _3gpp_sgsn_mcc_mnc String,
    _3gpp_imeisv String,
    _3gpp_rat_type UInt8,
    _3gpp_user_location_info String,
    _3gpp_user_location_info_location_type String,
    _3gpp_ms_timezone String
)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'kafka-kafka-bootstrap.strimzi-kafka.svc.cluster.local:9092',
         kafka_topic_list = 'ipmdn-nwdaf-4g',
         kafka_group_name = 'nwdaf-clickhouse',
         kafka_format = 'CSV',
         kafka_num_consumers = 8,
         kafka_thread_per_consumer = 1,
         kafka_max_block_size = 400000,
         kafka_skip_broken_messages = 400000,
         kafka_poll_max_batch_size = 400000,
         kafka_poll_timeout_ms = 500,
         kafka_flush_interval_ms = 5000;" | $CMD exec -i $pod -c clickhouse -n nwdaf -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf'
  echo "Recreated 4G Kafka Table [$pod]"

  # Drop 5g kafka table
  $CMD exec -it $pod -c clickhouse -n nwdaf -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf --query="DROP TABLE conn_kafka_source_ipmdn_5g"'
  # Create 5g kafka table
echo "
CREATE TABLE conn_kafka_source_ipmdn_5g
(
    _user_name String,
    _nas_ip_address String,
    _service_type UInt8,
    _framed_protocol UInt8,
    _framed_ip_address String,
    _framed_ipv6_prefix String,
    _called_station_id String,
    _calling_station_id String,
    _calling_station_id_usernm String,
    _calling_station_id_min String,
    _nas_identifier String,
    _acct_status_type UInt8,
    _acct_input_octets UInt64,
    _acct_output_octets UInt64,
    _acct_session_id String,
    _acct_session_time UInt64,
    _acct_input_packets UInt64,
    _acct_output_packets UInt64,
    _acct_terminate_cause UInt8,
    _event_timestamp String,
    _nas_port_type UInt8,
    _acct_input_gigawords UInt32,
    _acct_output_gigawords UInt32,
    _3gpp_imsi String,
    _3gpp_charging_id String,
    _3gpp_pdp_type UInt8,
    _3gpp_charging_gateway_address String,
    _3gpp_gprs_negotiated_qos_profile String,
    _3gpp_sgsn_address String,
    _3gpp_ggsn_address String,
    _3gpp_imsi_mcc_mnc String,
    _3gpp_ggsn_mcc_mnc String,
    _3gpp_nsapi String,
    _3gpp_selection_mode String,
    _3gpp_charging_characteristics String,
    _3gpp_sgsn_mcc_mnc String,
    _3gpp_imeisv String,
    _3gpp_rat_type UInt8,
    _3gpp_user_location_info String,
    _3gpp_user_location_info_location_type String,
    _3gpp_ms_timezone String
)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'kafka-kafka-bootstrap.strimzi-kafka.svc.cluster.local:9092',
         kafka_topic_list = 'ipmdn-nwdaf-5g',
         kafka_group_name = 'nwdaf-clickhouse',
         kafka_format = 'CSV',
         kafka_num_consumers = 8,
         kafka_thread_per_consumer = 1,
         kafka_max_block_size = 400000,
         kafka_skip_broken_messages = 400000,
         kafka_poll_max_batch_size = 400000,
         kafka_poll_timeout_ms = 500,
         kafka_flush_interval_ms = 5000;" | $CMD exec -i $pod -c clickhouse -n nwdaf -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf'
  echo "Recreated 5G Kafka Table [$pod]"
done

echo "Modify TTL"
echo "ALTER TABLE t_window_mdn_cell ON CLUSTER default MODIFY TTL partition_time + toIntervalHour(2);" | $CMD exec -i sts/clickhouse-local-shard0 -c clickhouse -n nwdaf -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d nwdaf'

echo "Create ai.cell_usage_infer"
echo "
CREATE TABLE cell_usage_infer ON CLUSTER default
(
    enb_cell_id String,
    cell_type String,
    freq_type String,
    window_start DateTime,
    window_end DateTime,
    total_user_count Nullable(Float32),
    heavy_user_count Nullable(Float32),
    medium2_user_count Nullable(Float32),
    medium1_user_count Nullable(Float32),
    light_user_count Nullable(Float32),
    total_user_usage Nullable(Float32),
    heavy_user_usage Nullable(Float32),
    medium2_user_usage Nullable(Float32),
    medium1_user_usage Nullable(Float32),
    light_user_usage Nullable(Float32),
    duration Nullable(Float32),
    iot_user_count Nullable(Float32),
    iot_user_usage Nullable(Float32),
    bps_mean Nullable(Float32),
    bps_std Nullable(Float32),
    bps_max Nullable(Float32),
    top_1_user_usage_share Nullable(Float32),
    fraction_for_20pct_usage Nullable(Float32),
    fraction_for_50pct_usage Nullable(Float32),
    fraction_for_80pct_usage Nullable(Float32)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toStartOfDay(window_end)
ORDER BY (enb_cell_id, window_end)
TTL toStartOfDay(window_end) + toIntervalDay(15);" | $CMD exec -i sts/clickhouse-local-shard0 -c clickhouse -n nwdaf -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d ai'

echo "Create ai.cell_usage_infer_5m"
echo "
CREATE TABLE cell_usage_infer_5m ON CLUSTER default
(
    enb_cell_id String,
    cell_type String,
    freq_type String,
    window_start DateTime,
    window_end DateTime,
    total_user_count Nullable(Float32),
    heavy_user_count Nullable(Float32),
    medium2_user_count Nullable(Float32),
    medium1_user_count Nullable(Float32),
    light_user_count Nullable(Float32),
    total_user_usage Nullable(Float32),
    heavy_user_usage Nullable(Float32),
    medium2_user_usage Nullable(Float32),
    medium1_user_usage Nullable(Float32),
    light_user_usage Nullable(Float32),
    duration Nullable(Float32),
    iot_user_count Nullable(Float32),
    iot_user_usage Nullable(Float32),
    bps_mean Nullable(Float32),
    bps_std Nullable(Float32),
    bps_max Nullable(Float32),
    top_1_user_usage_share Nullable(Float32),
    fraction_for_20pct_usage Nullable(Float32),
    fraction_for_50pct_usage Nullable(Float32),
    fraction_for_80pct_usage Nullable(Float32),
    prb_usage_rate Nullable(Float32)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toStartOfDay(window_end)
ORDER BY (enb_cell_id, window_end)
TTL toStartOfDay(window_end) + toIntervalDay(15);" | $CMD exec -i sts/clickhouse-local-shard0 -c clickhouse -n nwdaf -- bash -c 'clickhouse client --password ${CLICKHOUSE_ADMIN_PASSWORD} -d ai'