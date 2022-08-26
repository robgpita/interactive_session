#!/bin/bash
echo
echo Arguments:
echo $@
echo

source lib.sh

parseArgs $@
sshcmd="ssh -o StrictHostKeyChecking=no ${controller}"


# CREATE KILL FILE:
# - NEEDS TO BE MADE BEFORE RUNNING SESSION SCRIPT!
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
echo "echo Finished running ${kill_sh}" >> ${kill_sh}
chmod 777 ${kill_sh}


# TUNNEL COMMAND:
if [[ "$USERMODE" == "k8s" ]];then
    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
    # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
    TUNNELCMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost \"ssh -J ${controller} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -L 0.0.0.0:$openPort:localhost:$servicePort "'$(hostname)'"\""
else
    TUNNELCMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -R 0.0.0.0:$openPort:localhost:$servicePort localhost"
fi

# Initiallize session batch file:
echo "Generating session script"
session_sh=/pw/jobs/${job_number}/session.sh
echo "#!/bin/bash" > ${session_sh}

if ! [ -z ${chdir} ] && ! [[ "${chdir}" == "default" ]]; then
    echo "cd ${chdir}" >> ${session_sh}
fi

cat >> ${session_sh} <<HERE

echo
echo Starting interactive session - sessionPort: $servicePort tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo

# These are not workflow parameters but need to be available to the service on the remote node!
FORWARDPATH=${FORWARDPATH}
IPADDRESS=${IPADDRESS}
openPort=${openPort}

# Create a port tunnel from the allocated compute node to the user container (or user node in some cases)
screen_bin=\$(which screen 2> /dev/null)
if [ -z "\${screen_bin}" ]; then
    PRE_TUNNELCMD=""
    POST_TUNNELCMD=" &"
else
    PRE_TUNNELCMD="screen -d -m "
    POST_TUNNELCMD=""
fi
echo "Running blocking ssh command..."
# run this in a screen so the blocking tunnel cleans up properly
echo "\${PRE_TUNNELCMD} ${TUNNELCMD} \${POST_TUNNELCMD}"
\${PRE_TUNNELCMD} ${TUNNELCMD} \${POST_TUNNELCMD}
echo "Exit code: \$?"
# start the app
# nc -kl --no-shutdown $servicePort
echo "Starting session..."

HERE

# Add application-specific code
if [ -f "${start_service_sh}" ]; then
    cat ${start_service_sh} >> ${session_sh}
fi

chmod 777 ${session_sh}

echo
echo "Submitting ssh job (wait for node to become available before connecting)..."
echo "$sshcmd 'bash -s' < ${session_sh} &> /pw/jobs/${job_number}/session-${job_number}.out"
echo
$sshcmd 'bash -s' < ${session_sh} &> /pw/jobs/${job_number}/session-${job_number}.out

