# Following these instructions
# https://docs.qgis.org/3.28/en/docs/server_manual/containerized_deployment.html
set -x
# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

sudo service docker start

#####################
# START QGIS SERVER #
#####################
echo "Starting QGIS server"

if [[ ${service_use_gpus} == "true" ]]; then
    gpu_flag="--gpus all"
else
    gpu_flag=""
fi


if [[ ${service_project_file} == "default" ]]; then
    mkdir -p data
    wget "https://gitlab.com/Oslandia/qgis/docker-qgis/-/raw/cc1798074d4a66a472721352f3984bb318777a5a/qgis-exec/data/osm.qgs?inline=false" -O data/osm.qgs
    service_project_file=$(pwd)/data/osm.qgs
fi

project_dir=$(dirname ${service_project_file})
project_file=$(basename ${service_project_file})

sudo docker network create qgis
sudo docker run ${gpu_flag} -d --rm --name qgis-server ${service_mount_directories} --net=qgis --hostname=qgis-server \
    -v ${project_dir}:/data:ro -p 5555:5555 \
    -e "QGIS_PROJECT_FILE=${project_file}" \
    ${service_docker_repo}


echo "sudo docker stop qgis-server" >> cancel.sh
echo "sudo docker rm qgis-server" >> cancel.sh

# Print logs
sudo docker logs qgis-server

#######################
# START NGINX WRAPPER #
#######################

echo "Starting nginx wrapper on service port ${servicePort}"

# Write config file
cat >> config.conf <<HERE
server {
  listen 80;
  server_name _;
  location / {
    root  /usr/share/nginx/html;
    index index.html index.htm;
  }
  location /qgis-server {
    proxy_buffers 16 16k;
    proxy_buffer_size 16k;
    gzip off;
    include fastcgi_params;
    fastcgi_pass qgis-server:5555;
  }
}
HERE

echo "Running docker container nginx"
container_name="nginx-${servicePort}"
# Remove container when job is canceled
echo "sudo docker stop ${container_name}" >> cancel.sh
echo "sudo docker rm ${container_name}" >> cancel.sh
# Start container
sudo docker run -d --rm --name ${container_name} --net=qgis --hostname=nginx \
              -v $(pwd)/nginx.conf:/etc/nginx/conf.d/default.conf:ro -p ${servicePort}:80 \
              nginxinc/nginx-unprivileged
# Print logs
sudo docker logs ${container_name}

# Notify platform that service is ready
${sshusercontainer} ${pw_job_dir}/utils/notify.sh

sleep 9999