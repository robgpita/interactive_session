#!/bin/bash
sdir=$(dirname $0)
# For debugging
env > session_wrapper.env

sshcmd="ssh -o StrictHostKeyChecking=no ${controller}"

# create the script that will generate the session tunnel and run the interactive session app
# NOTE - in the below example there is an ~/.ssh/config definition of "localhost" control master that already points to the user container
#masterIp=$($sshcmd cat '~/.ssh/masterip')
masterIp=$($sshcmd hostname -I | cut -d' ' -f1) # Matthew: Master ip would usually be the internal ip
if [ -z ${masterIp} ]; then
    echo "ERROR: masterIP variable is empty. Command:"
    echo "$sshcmd hostname -I | cut -d' ' -f1"
    echo Exiting workflow
    exit 1
fi

# check if the user is on a new container 
env | grep -q PW_USERCONTAINER_VERSION
NEW_USERCONTAINER="$?"

# TUNNEL COMMAND:
if [[ "$USERMODE" == "k8s" || "$NEW_USERCONTAINER" == "0" ]];then
    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
    # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER_CONTAINER_HOST} \"ssh -J ${controller} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -L 0.0.0.0:$openPort:localhost:\$servicePort "'$(hostname)'"\""
else
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -R 0.0.0.0:$openPort:localhost:\$servicePort ${USER_CONTAINER_HOST}"
fi

# Initiallize session batch file:
echo "Generating session script"
export session_sh=/pw/jobs/${job_number}/session.sh
echo "#!/bin/bash" > ${session_sh}

if [[ ${jobschedulertype} == "SLURM" ]]; then
    directive_prefix="#SBATCH"
    submit_cmd="sbatch"
    delete_cmd="scancel"
    stat_cmd="squeue"
elif [[ ${jobschedulertype} == "PBS" ]]; then
    directive_prefix="#PBS"
    submit_cmd="qsub"
    delete_cmd="qdel"
    stat_cmd="qstat"
else
    echo "ERROR: jobschedulertype <${jobschedulertype}> must be SLURM or PBS"
    exit 1
fi

if ! [ -z ${scheduler_directives} ]; then
    for sched_dir in $(echo ${scheduler_directives} | sed "s|;| |g"); do
        # Script DEFAULT_JOB_FILE_TEMPLATE.sh converts spaces to '___'. Here we undo the transformation.
        echo "${directive_prefix} ${sched_dir}" | sed "s|___| |g" >> ${session_sh}
    done
fi

echo >> ${session_sh}

# ADD RUNTIME FIXES FOR EACH PLATFORM
if ! [ -z ${RUNTIME_FIXES} ]; then
    echo ${RUNTIME_FIXES} | tr ';' '\n' >> ${session_sh}
fi

# SET SESSIONS' REMOTE DIRECTORY
${sshcmd} mkdir -p ${chdir}
remote_session_dir=${chdir}

# ADD STREAMING
if [[ "${stream}" == "True" ]]; then
    # Don't really know the extension of the --pushpath. Can't controll with PBS (FIXME)
    stream_args="--host ${USER_CONTAINER_HOST} --pushpath /pw/jobs/${job_number}/session-${job_number}.o --pushfile session-${job_number}.out --delay 30 --masterIp ${masterIp}"
    stream_cmd="bash stream-${job_number}.sh ${stream_args} &"
    echo; echo "Streaming command:"; echo "${stream_cmd}"; echo
    echo ${stream_cmd} >> ${session_sh}
fi

# MAKE SURE CONTROLLER NODES HAVE SSH ACCESS TO COMPUTE NODES:
$sshcmd cp "~/.ssh/id_rsa.pub" ${remote_session_dir}

cat >> ${session_sh} <<HERE
# In some systems screen can't write to /var/run/screen
mkdir ${chdir}/.screen
chmod 700 ${chdir}/.screen
export SCREENDIR=${chdir}/.screen

cd ${chdir}
set -x

# MAKE SURE CONTROLLER NODES HAVE SSH ACCESS TO COMPUTE NODES:
pubkey=\$(cat ~/.ssh/authorized_keys | grep \"\$(cat id_rsa.pub)\")
if [ -z "\${pubkey}" ]; then
    echo "Adding public key of controller node to compute node ~/.ssh/authorized_keys"
    cat id_rsa.pub >> ~/.ssh/authorized_keys
fi

if [ -f "${remote_sh}" ]; then
    echo "Running  ${remote_sh}"
    ${remote_sh}
fi

# These are not workflow parameters but need to be available to the service on the remote node!
NEW_USERCONTAINER=${NEW_USERCONTAINER}
FORWARDPATH=${FORWARDPATH}
IPADDRESS=${IPADDRESS}
openPort=${openPort}
masterIp=${masterIp}
USER_CONTAINER_HOST=${USER_CONTAINER_HOST}
controller=${controller}

# Find an available servicePort
minPort=6000
maxPort=9000
for port in \$(seq \${minPort} \${maxPort} | shuf); do
    out=\$(netstat -aln | grep LISTEN | grep \${port})
    if [ -z "\${out}" ]; then
        # To prevent multiple users from using the same available port --> Write file to reserve it
        portFile=/tmp/\${port}.port.used
        if ! [ -f "\${portFile}" ]; then
            touch \${portFile}
            export servicePort=\${port}
            break
        fi
    fi
done

if [ -z "\${servicePort}" ]; then
    echo "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
    exit 1
fi

echo
echo Starting interactive session - sessionPort: \$servicePort tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo

# Create a port tunnel from the allocated compute node to the user container (or user node in some cases)

# run this in a screen so the blocking tunnel cleans up properly
echo "Running blocking ssh command..."
screen_bin=\$(which screen 2> /dev/null)
if [ -z "\${screen_bin}" ]; then
    echo Screen not found. Attempting to install
    sudo -n yum install screen -y
fi

if [ -z "\${screen_bin}" ]; then
    echo "ERROR: screen is not installed in the system --> Exiting workflow"
    exit 1
    #echo "nohup ${TUNNELCMD} &"
    #nohup ${TUNNELCMD} &
    echo "${TUNNELCMD} &"
    ${TUNNELCMD} &
else
    echo "screen -d -m ${TUNNELCMD}"
    screen -d -m ${TUNNELCMD}
fi
echo "Exit code: \$?"
echo "Starting session..."
rm -f \${portFile}
HERE

# Add application-specific code
if [ -f "${start_service_sh}" ]; then
    cat ${start_service_sh} >> ${session_sh}
fi

# move the session file over
chmod 777 ${session_sh}
scp ${session_sh} ${controller}:${remote_session_dir}/session-${job_number}.sh
scp stream.sh ${controller}:${remote_session_dir}/stream-${job_number}.sh

echo
echo "Submitting slurm request (wait for node to become available before connecting)..."
echo
echo $sshcmd ${submit_cmd} ${remote_session_dir}/session-${job_number}.sh

sed -i 's/.*Job status.*/Job status: Submitted/' service.html

# Submit job and get job id
if [[ ${jobschedulertype} == "SLURM" ]]; then
    jobid=$($sshcmd ${submit_cmd} ${remote_session_dir}/session-${job_number}.sh | tail -1 | awk -F ' ' '{print $4}')
elif [[ ${jobschedulertype} == "PBS" ]]; then
    jobid=$($sshcmd ${submit_cmd} ${remote_session_dir}/session-${job_number}.sh)
fi

if [[ "${jobid}" == "" ]];then
    echo "ERROR submitting job - exiting the workflow"
    sed -i 's/.*Job status.*/Job status: Failed/' service.html
    exit 1
fi

# CREATE KILL FILE:
# - When the job is killed PW runs /pw/jobs/job-number/kill.sh
# Initialize kill.sh
kill_sh=/pw/jobs/${job_number}/kill.sh
echo "#!/bin/bash" > ${kill_sh}
echo "echo Running ${kill_sh}" >> ${kill_sh}

# Add application-specific code
# WARNING: if part runs in a different directory than bash command! --> Use absolute paths!!
if [ -f "${kill_service_sh}" ]; then
    echo "Adding kill server script: ${kill_service_sh}"
    echo "$sshcmd 'bash -s' < ${kill_service_sh}" >> ${kill_sh}
fi
echo $sshcmd ${delete_cmd} ${jobid} >> ${kill_sh}
echo "echo Finished running ${kill_sh}" >> ${kill_sh}
echo "sed -i 's/.*Job status.*/Job status: Cancelled/' /pw/jobs/${job_number}/service.html"  >> ${kill_sh}
chmod 777 ${kill_sh}

echo
echo "Submitted slurm job: ${jobid}"


# Job status file writen by remote script:
while true; do    
    # squeue won't give you status of jobs that are not running or waiting to run
    # qstat returns the status of all recent jobs
    job_status=$($sshcmd ${stat_cmd} | grep ${jobid} | awk '{print $5}')
    sed -i "s/.*Job status.*/Job status: ${job_status}/" service.html
    if [[ ${jobschedulertype} == "SLURM" ]]; then
        if [ -z ${job_status} ]; then
            job_status=$($sshcmd sacct -j ${jobid}  --format=state | tail -n1)
            sed -i "s/.*Job status.*/Job status: ${job_status}/" service.html
            break
        fi
    elif [[ ${jobschedulertype} == "PBS" ]]; then
        if [[ ${job_status} == "C" ]]; then
            break
        fi
    fi
    sleep 60
done

