#!/usr/bin/env bash
set -e

BACKUP_PATH=/u01/backups/$(date +'%Y-%m-%d')

function backup-db-postgres {
  container="$(jq -r '.')"
  container_name="$(echo "${container}" | jq -r '.Name' | sed 's|^/||')"
  env="$(echo "${container}" | jq -r '.Config.Env' | jq -r 'map(capture("^(?<key>.+?)=(?<value>.+?)$")) | from_entries')"
  docker_args="$(echo "${env}" | jq -r '"-e PGPASSWORD=\"\(.POSTGRES_PASSWORD)\""')"
  args="$(echo "${env}" | jq -r '"-U \(.POSTGRES_USER) -d \(.POSTGRES_DB)"')"
  docker exec ${docker_args} ${container_name} pg_dump -Fc ${args} > ${1}.db
}

function backup-db {
  container="$(jq -r '.')"
  container_name="$(echo "${container}" | jq -r '.Name' | sed 's|^/||')"
  if ! [ -z "$(docker exec "${container_name}" which postgres)" ]; then
    echo "${container}" | backup-db-postgres "${@}"
  else
    echo "Error: Not support DB"
    exit 1
  fi
}

function backup-redis {
  container="$(jq -r '.')"
  container_name="$(echo "${container}" | jq -r '.Name' | sed 's|^/||')"
  if [ -z "$(docker exec "${container_name}" which redis-cli)" ]; then
    echo "Error: Not support Redis"
    exit 1
  fi
  if [ $(echo 'SAVE' | docker exec -i "${container_name}" redis-cli) != OK ]; then
    echo "Error: Redis dump failed"
    exit 1
  fi
  docker exec "${container_name}" cat dump.rdb > ${1}.rdb
}

echo "--- Starting backup ---"
for item in $(docker ps --format '{{ .Names }}'); do
  container="$(docker inspect "${item}" | jq -r '.[]')"
  stack_name="$(echo "${container}" | jq -r '.Config.Labels."com.docker.stack.namespace"')"
  service_full_name="$(echo "${container}" | jq -r '.Config.Labels."com.docker.swarm.service.name"')"
  service_name=$(echo "${service_full_name}" | sed "s/^${stack_name}_//")
  path="${BACKUP_PATH}/${stack_name}/${service_name}"
  backup_to="${path}/$(date +'%Y-%m-%d-%H%M%S')"
  mkdir -p "${path}"
  start_time=$(date +'%s')
  printf "${service_full_name} ... "
  if ! [ -z "$(ls ${path})" ]; then
    echo "Backuped !"
    continue
  fi
  if [[ ${service_name} =~ ^db- ]]; then
    echo "${container}" | backup-db "${backup_to}"
  elif [ ${service_name} == redis ] || [[ ${service_name} =~ ^redis- ]]; then
      echo "${container}" | backup-redis "${backup_to}"
  else
    rmdir "${path}"
    if [ -z "$(ls $(dirname ${path}))" ]; then
      rmdir $(dirname ${path})
    fi
    echo "Skiped !"
    continue
  fi
  end_time=$(date +'%s')
  delta_time=$(echo "${end_time} - ${start_time}" | bc)
  echo "${delta_time}s"
done
echo "--- Done backup ---"

tar -czf /tmp/db-backup.tgz "${BACKUP_PATH}" 2>>/dev/null
cp /tmp/db-backup.tgz /mnt/backups/$(basename ${BACKUP_PATH}).tgz
echo "Copy to NFS OK !"
status=$(cat /tmp/db-backup.tgz | curl -T - -s -w '%{http_code}' https://storage.elofun.net/myidv2-backup-$(basename ${BACKUP_PATH}).tgz)
if [ ${status} == 201 ]; then
  echo "Upload Created !"
elif [ ${status} == 204 ]; then
  echo "Upload OK !"
else
  echo "Error: Upload failed with code ${status}"
  exit 1
fi
rm /tmp/db-backup.tgz
echo "--- Done upload ---"
