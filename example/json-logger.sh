#!/bin/sh

count=0
while true; do
    count=$((count + 1))

    if [ $((count % 4)) -eq 1 ]; then
        echo '{"time":"'$(date -Iseconds)'","level":"INFO","msg":"Service heartbeat","component":"json-service","count":'$count',"status":"healthy"}'
    elif [ $((count % 4)) -eq 2 ]; then
        echo '{"timestamp":"'$(date -Iseconds)'","level":"DEBUG","message":"Debug information","service_id":"json-logger","iteration":'$count',"memory_usage":"12MB"}'
    elif [ $((count % 4)) -eq 3 ]; then
        echo '{"time":"'$(date -Iseconds)'","severity":"WARN","msg":"Warning condition detected","alert_id":"W001","count":'$count',"threshold":75}'
    else
        echo '{"ts":"'$(date -Iseconds)'","level":"ERROR","message":"Simulated error condition","error_code":"E500","retry_count":'$count',"recoverable":true}'
    fi

    sleep 3
done
