#!/bin/bash

# Initialization
IP=127.0.0.1
INSTALLPATH=/data/monitors/loki/
PORT=3100

helpinfo () {
    printf "Usage:  bash loki_init.sh [OPTIONS]\n\n"
    printf "Auto install loki and register it into systemd\n\n"
    printf "Options:\n"
    printf "%-2s%-12s %s\n" "" "-h, --help" "Show help"
    printf "%-2s%-12s %s\n" "" "-i, --ip" "Listen host ip of loki, (default \"127.0.0.1\")"
    printf "%-2s%-12s %s\n" "" "-p, --port" "Port of loki service (default \"3100\")"
    printf "%-6s%-8s %s\n" "" "--path" "Location of loki install path, (default \"/data/monitors/loki/\")"
    printf "%-2s%-12s %s\n" "" "-u, --url" "Url of loki package"
}

# Parse args
SHORTOPTS="h,u:i::p::"
LONGOPTS="help,url:,ip::,path::,port::"
ARGS=$(getopt --options $SHORTOPTS --longoptions $LONGOPTS -- "$@" )

if [ $? != 0 ] ; then echo "Parse error! Terminating..." >&2 ; exit 1 ; fi

eval set -- "$ARGS"

while true ; do
     case "$1" in
          -h|--help) helpinfo ; exit ;;
          -u|--url) URL="$2" ; shift 2 ;;
          -i|--ip) IP="$2"; shift 2 ;;
          -p|--port) PORT="$2" ; shift 2 ;;
          --path) INSTALLPATH="$2" ; shift 2 ;;
          --) shift ; break ;;
          *) echo "Args error!" ; exit 1 ;;
     esac
done

# Make path and download binary package
mkdir -p /downloads
mkdir -p /data
mkdir -p $INSTALLPATH
curl $URL -o /downloads/loki.tar.gz
# tar xzvf /downloads/loki.tar.gz -C $INSTALLPATH
unzip /downloads/loki.tar.gz -d $INSTALLPATH
INSTALLPATH=$(find $INSTALLPATH -name "loki*" -size +1M | sed "s/\/loki[^\/].*$//g")

# Create wal path
mkdir -p $INSTALLPATH/wal

# Create config file
cat << EOF > $INSTALLPATH/config.yaml
auth_enabled: false
server:
  http_listen_port: $PORT
  grpc_listen_port: 0
ingester:
  lifecycler:
    address: $IP
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
    final_sleep: 0s
  chunk_idle_period: 5m
  chunk_retain_period: 30s
  max_transfer_retries: 0
  wal:
    dir: $INSTALLPATH/wal
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v12
      index:
        prefix: index_
        period: 24h
storage_config:
  tsdb_shipper:
    active_index_directory: $INSTALLPATH/tsdb-index
    cache_location: $INSTALLPATH/tsdb-cache
    index_gateway_client:
    cache_ttl: 24h
    shared_store: filesystem
  filesystem:
    directory: $INSTALLPATH/chunks
query_scheduler:
  max_outstanding_requests_per_tenant: 32768
querier:
  max_concurrent: 16
limits_config:
  enforce_metric_name: false
  reject_old_samples: true
  reject_old_samples_max_age: 72h
  ingestion_rate_mb: 32
  ingestion_burst_size_mb: 64
  max_entries_limit_per_query: 0
  retention_period: 72h
chunk_store_config:
  max_look_back_period: 72h
table_manager:
  retention_deletes_enabled: true
  retention_period: 72h
compactor: 
  working_directory: $INSTALLPATH/compactor
  shared_store: filesystem
  retention_enabled: true
  compaction_interval:  10m
  retention_delete_delay: 2h
  retention_delete_worker_count: 150
analytics:
  reporting_enabled: false
EOF

# Create user and config systemd file
useradd -rs /bin/false loki
chown -R loki:loki $INSTALLPATH
cat << EOF > /lib/systemd/system/loki.service
[Unit]
Description=Loki
Wants=network-online.target
After=network-online.target

[Service]
User=loki
Group=loki
Type=simple
ExecStart=$INSTALLPATH/loki-linux-amd64 -config.file=$INSTALLPATH/config.yaml &>> $INSTALLPATH/logs
ExecReload=/bin/kill -s HUP
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
systemctl daemon-reload
systemctl enable loki
systemctl restart loki
systemctl status loki
