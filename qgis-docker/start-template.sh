# Following these instructions
# https://docs.qgis.org/3.28/en/docs/server_manual/containerized_deployment.html
set -x
# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

sudo service docker start

qgis_port=$(findAvailablePort)
echo "rm /tmp/${qgis_port}.port.used" >> cancel.sh

######################
# Build docker image #
######################
# Write config file
cat >> Dockerfile <<HERE
FROM debian:bullseye-slim

ENV LANG=en_EN.UTF-8


RUN apt-get update \\
    && apt-get install --no-install-recommends --no-install-suggests --allow-unauthenticated -y \\
        gnupg \\
        ca-certificates \\
        wget \\
        locales \\
    && localedef -i en_US -f UTF-8 en_US.UTF-8 \\
    # Add the current key for package downloading
    # Please refer to QGIS install documentation (https://www.qgis.org/fr/site/forusers/alldownloads.html#debian-ubuntu)
    && mkdir -m755 -p /etc/apt/keyrings \\
    && wget -O /etc/apt/keyrings/qgis-archive-keyring.gpg https://download.qgis.org/downloads/qgis-archive-keyring.gpg \\
    # Add repository for latest version of qgis-server
    # Please refer to QGIS repositories documentation if you want other version (https://qgis.org/en/site/forusers/alldownloads.html#repositories)
    && echo "deb [signed-by=/etc/apt/keyrings/qgis-archive-keyring.gpg] https://qgis.org/debian bullseye main" | tee /etc/apt/sources.list.d/qgis.list \\
    && apt-get update \\
    && apt-get install --no-install-recommends --no-install-suggests --allow-unauthenticated -y \\
        qgis-server \\
        spawn-fcgi \\
        xauth \\
        xvfb \\
    && apt-get remove --purge -y \\
        gnupg \\
        wget \\
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m qgis

ENV TINI_VERSION v0.19.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini

ENV QGIS_PREFIX_PATH /usr
ENV QGIS_SERVER_LOG_STDERR 1
ENV QGIS_SERVER_LOG_LEVEL 2

COPY cmd.sh /home/qgis/cmd.sh
RUN chmod -R 777 /home/qgis/cmd.sh
RUN chown qgis:qgis /home/qgis/cmd.sh

USER qgis
WORKDIR /home/qgis

ENTRYPOINT ["/tini", "--"]

CMD ["/home/qgis/cmd.sh"]
HERE

cat >> cmd.sh <<HERE
#!/bin/bash

[[ $DEBUG == "1" ]] && env

exec /usr/bin/xvfb-run --auto-servernum --server-num=1 /usr/bin/spawn-fcgi -p ${qgis_port} -n -d /home/qgis -- /usr/lib/cgi-bin/qgis_mapserv.fcgi
HERE

sudo docker build -f Dockerfile -t qgis-server ./

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
qgis_container_name=qgis-server-${qgis_port}

sudo docker network create qgis-${qgis_port}
sudo docker run ${gpu_flag} -d --rm --name ${qgis_container_name} ${service_mount_directories} --net=qgis --hostname=qgis-server \
    -v ${project_dir}:/data:ro -p ${qgis_port}:${qgis_port} \
    -e "QGIS_PROJECT_FILE=${project_file}" \
    qgis-server

echo "sudo docker network rm qgis-${qgis_port}" >> cancel.sh
echo "sudo docker stop ${qgis_container_name}" >> cancel.sh
echo "sudo docker rm ${qgis_container_name}" >> cancel.sh

# Print logs
sudo docker logs ${qgis_container_name}

#######################
# START NGINX WRAPPER #
#######################

echo "Starting nginx wrapper on service port ${servicePort}"

# Write config file
cat >> nginx.conf <<HERE
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
    fastcgi_pass qgis-server:${qgis_port};
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
              nginx:1.13
# Print logs
sudo docker logs ${container_name}

# Notify platform that service is ready
${sshusercontainer} ${pw_job_dir}/utils/notify.sh

sleep 9999