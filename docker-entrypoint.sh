#!/bin/sh

if [ "$1" = 'redis-cluster' ]; then
    # Allow passing in cluster IP by argument or environmental variable
    IP="${2:-$IP}"

    if [ -z "$IP" ]; then # If IP is unset then discover it
        IP=$(hostname -I)
    fi

    echo " -- IP Before trim: '$IP'"
    IP=$(echo ${IP}) # trim whitespaces
    echo " -- IP Before split: '$IP'"
    IP=${IP%% *} # use the first ip
    echo " -- IP After trim: '$IP'"

    if [ -z "$INITIAL_PORT" ]; then # Default to port 7000
      INITIAL_PORT=7000
    fi

    if [ -z "$MASTERS" ]; then # Default to 3 masters
      MASTERS=3
    fi

    if [ -z "$SLAVES_PER_MASTER" ]; then # Default to 1 slave for each master
      SLAVES_PER_MASTER=1
    fi

    if [ -z "$BIND_ADDRESS" ]; then # Default to any IPv4 address
      BIND_ADDRESS=0.0.0.0
    fi

    max_port=$(($INITIAL_PORT + $MASTERS * ( $SLAVES_PER_MASTER  + 1 ) - 1))
    first_standalone=$(($max_port + 1))
    if [ "$STANDALONE" = "true" ]; then
      STANDALONE=2
    fi
    if [ ! -z "$STANDALONE" ]; then
      max_port=$(($max_port + $STANDALONE))
    fi

    for port in $(seq $INITIAL_PORT $max_port); do
      mkdir -p /redis-conf/${port}
      mkdir -p /redis-data/${port}

      if [ -e /redis-data/${port}/nodes.conf ]; then
        rm /redis-data/${port}/nodes.conf
      fi

      if [ -e /redis-data/${port}/dump.rdb ]; then
        rm /redis-data/${port}/dump.rdb
      fi

      if [ -e /redis-data/${port}/appendonly.aof ]; then
        rm /redis-data/${port}/appendonly.aof
      fi

      if [ "$port" -lt "$first_standalone" ]; then
        PORT=${port} BIND_ADDRESS=${BIND_ADDRESS} REDIS_TLS_CERT_FILE=${REDIS_TLS_CERT_FILE} REDIS_TLS_KEY_FILE=${REDIS_TLS_KEY_FILE} REDIS_TLS_CA_FILE=${REDIS_TLS_CA_FILE} envsubst < /redis-conf/redis-cluster.tmpl > /redis-conf/${port}/redis.conf
        nodes="$nodes $IP:$port"
      else
        PORT=${port} BIND_ADDRESS=${BIND_ADDRESS} envsubst < /redis-conf/redis.tmpl > /redis-conf/${port}/redis.conf
      fi

      if [ "$port" -lt $(($INITIAL_PORT + $MASTERS)) ]; then
        if [ "$SENTINEL" = "true" ]; then
          PORT=${port} SENTINEL_PORT=$((port - 2000)) envsubst < /redis-conf/sentinel.tmpl > /redis-conf/sentinel-${port}.conf
          cat /redis-conf/sentinel-${port}.conf
        fi
      fi

      # If environment variable REDIS_DEFAULT_PASSWORD had a value when container was built,
      # append default-user.tmpl to the redis.conf file for this node
      if [ -z "${DEFAULT_PASSWORD}" ]; then
        echo "Starting without user 'default' password"
      else
        echo "Starting with user 'default' password set"
        DEFAULT_PASSWORD=${DEFAULT_PASSWORD} envsubst < /redis-conf/default-user.tmpl >> /redis-conf/${port}/redis.conf
      fi

      # If environment USER_NAME has a value when container was built,
      # append custom-user.tmpl to the redis.conf file for this node
      if [ -z "${USER_NAME}" ]; then
        echo "Starting without custom user"
      else
        echo "Starting with custom user ${USER_NAME}"
        USER_NAME=${USER_NAME} USER_PASSWORD=${USER_PASSWORD} envsubst < /redis-conf/custom-user.tmpl >> /redis-conf/${port}/redis.conf
      fi

    done

    bash /generate-supervisor-conf.sh $INITIAL_PORT $max_port > /etc/supervisor/supervisord.conf

    supervisord -c /etc/supervisor/supervisord.conf
    sleep 3

    #
    ## Check the version of redis-cli and if we run on a redis server below 5.0
    ## If it is below 5.0 then we use the redis-trib.rb to build the cluster
    #
    /redis/src/redis-cli --version | grep -E "redis-cli 3.0|redis-cli 3.2|redis-cli 4.0"

    if [ $? -eq 0 ]
    then
      echo "Using old redis-trib.rb to create the cluster"
      echo "yes" | eval ruby /redis/src/redis-trib.rb create --replicas "$SLAVES_PER_MASTER" "$nodes"
    else
      echo "Using redis-cli to create the cluster"
      # If default user has a required password, it is necessary to pass the password as -a
      # in order for the cluster nodes to be able to authenticate to the cluster.
      if [ -z "${DEFAULT_PASSWORD}" ]; then
        echo "yes" | eval /redis/src/redis-cli  --cluster create --cluster-replicas "$SLAVES_PER_MASTER" "$nodes"
      else
        echo "yes" | eval /redis/src/redis-cli --tls  --cluster create --cluster-replicas "$SLAVES_PER_MASTER" "$nodes" -a "${DEFAULT_PASSWORD}" --tls --cert $REDIS_TLS_CERT_FILE --key $REDIS_TLS_KEY_FILE --cacert $REDIS_TLS_CA_FILE
      fi
    fi

    if [ "$SENTINEL" = "true" ]; then
      for port in $(seq $INITIAL_PORT $(($INITIAL_PORT + $MASTERS))); do
        redis-sentinel /redis-conf/sentinel-${port}.conf &
      done
    fi

    tail -f /var/log/supervisor/redis*.log
else
  exec "$@"
fi
