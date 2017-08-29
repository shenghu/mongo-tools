#!/bin/bash
# set -x

if [ $# = 0 ]
then
 echo "Usage: $0 shard_number"
 echo "  shard_number - Number of shard nodes"
 exit 0
fi

SHARD_NUM=$1
NAME_PREFIX=mongo-shards-

# Image to be run
IMAGE=mongo

# Specify a directory on host (outside of container) to store db data.
# Comment it out if you dont't want to store data outside of container.
# EXTERNAL_DATA_DIRECTORY="${HOME}/data/db-${CONTAINER_NAME}"

if [ -z "${EXTERNAL_DATA_DIRECTORY}" ]; then
  VOLUME_OPTION=
else
  mkdir -p "${EXTERNAL_DATA_DIRECTORY}"
  VOLUME_OPTION="-v ${EXTERNAL_DATA_DIRECTORY}:/data/db"
fi

# Comment it out if you don't want to run container in user defined network. 
NETWORK=mongo-shards-cluster

if [ -z "${NETWORK}" ]; then
  NETWORK_OPTION=
else
  if [[ -z `docker network ls | grep ${NETWORK}` ]]; then
    docker network create ${NETWORK}
  fi
  NETWORK_OPTION="--net=${NETWORK}"
fi

# Setup config server
echo
echo Setup config server... 

CONFIG_SVR_NAME="${NAME_PREFIX}cfg"
CONFIG_SVR_PORT=27020
CONFIG_SVR_REPLICASET=rs0

echo Remove existing container for ${CONFIG_SVR_NAME}

docker ps | grep ${CONFIG_SVR_NAME} > /dev/null
if [ $? -eq 0 ]
then
  docker container stop ${CONFIG_SVR_NAME}
fi

docker ps -a | grep ${CONFIG_SVR_NAME} > /dev/null
if [ $? -eq 0 ]
then
  docker container rm ${CONFIG_SVR_NAME}
fi

echo Run container ${CONFIG_SVR_NAMECONFIG_SVR_NAME}
docker run -h ${CONFIG_SVR_NAME} -d -p ${CONFIG_SVR_PORT}:27017 ${NETWORK_OPTION} --name ${CONFIG_SVR_NAME} ${IMAGE} mongod --port 27017 --configsvr --replSet ${CONFIG_SVR_REPLICASET}

docker cp initReplSet.js ${CONFIG_SVR_NAME}:/tmp/
sleep 2
docker exec ${CONFIG_SVR_NAME} mongo --port 27017 /tmp/initReplSet.js 

# Setup mongos server
echo 
echo Setup mongos server...

MONGOS_NAME="${NAME_PREFIX}mongos"
MONGOS_PORT=$(( 1 + CONFIG_SVR_PORT ))

echo Remove existing container for ${MONGOS_NAME}
docker ps | grep ${MONGOS_NAME} > /dev/null
if [ $? -eq 0 ]
then 
  docker container stop ${MONGOS_NAME}
fi

docker ps -a | grep ${MONGOS_NAME} > /dev/null
if [ $? -eq 0 ]
then
  docker container rm ${MONGOS_NAME}
fi

echo Run container ${MONGOS_NAME}
docker run -h ${MONGOS_NAME} -d -p ${MONGOS_PORT}:27017 ${NETWORK_OPTION} --name ${MONGOS_NAME} ${IMAGE} mongos --port 27017 -configdb ${CONFIG_SVR_REPLICASET}/${CONFIG_SVR_NAME}:27017    

# Setup shard servers
echo 
echo Setup shard servers...

ADD_SHARDS_JS="_addShards.js"
rm ${ADD_SHARDS_JS} 

for (( index=1; index<=$SHARD_NUM; index++ ))
do
  echo $index
  
  SHARD_PORT=$(( index + 5 + CONFIG_SVR_PORT ))
  SHARD_NAME=${NAME_PREFIX}${index}
  SHARD_REPLICASET=rs${index}
  
  echo Remove existing container for ${SHARD_NAME}
  docker ps | grep ${SHARD_NAME} > /dev/null
  if [ $? -eq 0 ]
  then 
    docker container stop ${SHARD_NAME}
  fi

  docker ps -a | grep ${SHARD_NAME} > /dev/null
  if [ $? -eq 0 ]
  then
    docker container rm ${SHARD_NAME}
  fi

  echo Run container ${SHARD_NAME}
  docker run -h ${SHARD_NAME} -d -p ${SHARD_PORT}:27017 ${NETWORK_OPTION} --name ${SHARD_NAME} ${IMAGE} mongod --port 27017 --shardsvr --replSet ${SHARD_REPLICASET}

  echo Initiate replica set ${SHARD_REPLICASET}
  docker cp initReplSet.js ${SHARD_NAME}:/tmp/
  sleep 2
  docker exec ${SHARD_NAME} mongo --port 27017 /tmp/initReplSet.js

  echo "sh.addShard(\"${SHARD_REPLICASET}/${SHARD_NAME}:27017\");" >> ${ADD_SHARDS_JS}
done

echo 
echo Add shards to mongos
docker cp ${ADD_SHARDS_JS} ${MONGOS_NAME}:/tmp/
docker exec -t ${MONGOS_NAME} mongo --port 27017 /tmp/${ADD_SHARDS_JS}

# Show running containers
docker container ls

