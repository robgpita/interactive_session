#!/bin/bash
# change permissions of run directly so we can execute all files
chmod 777 * -Rf
# Need to move files from utils directory to avoid updating the sparse checkout
mv utils/error.html .
mv utils/service.json .

source inputs.sh
source lib.sh
checkInputParameters

export job_number=$(basename ${PWD})
echo "export job_number=${job_number}" >> inputs.sh

# Obtain the service_name from any section of the XML
service_name=$(cat inputs.sh | grep service_name | cut -d'=' -f2 | tr -d '"')
export service_name=${service_name}
echo "export service_name=${service_name}" >> inputs.sh

# export the users env file (for some reason not all systems are getting these upon execution)
while read LINE; do export "$LINE"; done < ~/.env

# Initialize service.html to prevent error from showing when you click in the eye icon
cp service.html.template service.html

echo
echo "JOB NUMBER:  ${job_number}"
echo "USER:        ${PW_USER}"
echo "DATE:        $(date)"
echo "DIRECTORY:   ${PWD}"
echo "COMMAND:     $0"
# Very useful to rerun a workflow with the exact same code version!
#commit_hash=$(git --git-dir=clone/.git log --pretty=format:'%h' -n 1)
#echo "COMMIT HASH: ${commit_hash}"
echo

export PW_JOB_PATH=$(pwd | sed "s|${HOME}||g")
echo "export PW_JOB_PATH=${PW_JOB_PATH}" >> inputs.sh

sed -i "s/__job_number__/${job_number}/g" inputs.sh
sed -i "s/__USER__/${PW_USER}/g" inputs.sh

# GER OPEN PORT FOR TUNNEL
getOpenPort

if [[ "$openPort" == "" ]]; then
    displayErrorMessage "ERROR - cannot find open port..."
    exit 1
fi
export openPort=${openPort}
echo "export openPort=${openPort}" >> inputs.sh

export USER_CONTAINER_HOST="usercontainer"
echo "export USER_CONTAINER_HOST=${USER_CONTAINER_HOST}" >> inputs.sh

source /pw/.miniconda3/etc/profile.d/conda.sh
conda activate

# LOAD PLATFORM-SPECIFIC ENVIRONMENT:
env_sh=platforms/${PARSL_CLIENT_HOST}/env.sh
if ! [ -f "${env_sh}" ]; then
    env_sh=platforms/default/env.sh
fi
source ${env_sh}

if ! [ -f "${CONDA_PYTHON_EXE}" ]; then
    echo "WARNING: Environment variable CONDA_PYTHON_EXE is pointing to a missing file ${CONDA_PYTHON_EXE}!"
    echo "         Modifying its value: export CONDA_PYTHON_EXE=$(which python3)"
    # Wont work unless it has requests...
    export CONDA_PYTHON_EXE=$(which python3)
fi

echo "Interactive Session Port: $openPort"

#  CONTROLLER INFO
host_resource_name=$(echo ${host_resource_name} | sed "s/_//g" |  tr '[:upper:]' '[:lower:]')
if [[ ${host_resource_name} == "userworkspace" ]]; then
    # Unless the user workspace has PBS or SLURM installed the only supported scheduler type is LOCAL
    export host_jobschedulertype="LOCAL"
    echo "export host_jobschedulertype=LOCAL" >> inputs.sh
else
    # GET HOST INFORMATION FROM API
    getRemoteHostInfoFromAPI
fi

sed -i "s|__host_resource_workdir__|${host_resource_workdir}|g" inputs.sh

# SET chdir
export chdir=${host_resource_workdir}${PW_JOB_PATH}
echo "export chdir=${chdir}" >> inputs.sh

# RUN IN CONTROLLER, SLURM PARTITION OR PBS QUEUE?
if [[ ${host_jobschedulertype} == "CONTROLLER" ]]; then
    echo "Submitting ssh job to ${controller}"
    session_wrapper_dir=controller
elif [[ ${host_jobschedulertype} == "LOCAL" ]]; then
    echo "Submitting ssh job to user container"
    session_wrapper_dir=local
else
    echo "Submitting ${host_jobschedulertype} job to ${controller}"
    session_wrapper_dir=partition

    # Get scheduler directives from input form (see this function in lib.sh)
    form_sched_directives=$(getSchedulerDirectivesFromInputForm)

    # Get scheduler directives enforced by PW:
    # Set job name, log paths and run directory
    if [[ ${host_jobschedulertype} == "SLURM" ]]; then
        pw_sched_directives=";--job-name=session-${job_number};--chdir=${chdir};--output=session-${job_number}.out"
    elif [[ ${host_jobschedulertype} == "PBS" ]]; then
        # PBS needs a queue to be specified!
        if [ -z "${_sch__d_q___}" ]; then
            is_queue_defined=$(echo ${host_scheduler_directives} | tr ';' '\n' | grep -e '-q___')
            if [ -z "${is_queue_defined}" ]; then
                displayErrorMessage "ERROR: PBS needs a queue to be defined! - exiting workflow"
                exit 1
            fi
        fi
        pw_sched_directives=";-N___session-${job_number};-o___${chdir}/session-${job_number}.out;-e___${chdir}/session-${job_number}.out;-S___/bin/bash"
    fi

    # Merge all directives in single param
    export scheduler_directives="${host_scheduler_directives};${form_sched_directives};${pw_sched_directives}"
    echo "export scheduler_directives=${scheduler_directived}"
fi

# SERVICE URL

echo "Generating session html"
source ${service_name}/url.sh
echo "export FORWARDPATH=${FORWARDPATH}" >> inputs.sh
echo "export IPADDRESS=${IPADDRESS}" >> inputs.sh
cp service.html.template service.html_

# FIXME: Move this to <service-name>/url.sh
if [[ "${service_name}" == "nicedcv" ]]; then
    URL="\"/sme/${openPort}/${URLEND}"
    sed -i "s|.*URL.*|    \"URL\": \"/sme\",|" service.json
else
    URL="\"/me/${openPort}/${URLEND}"
    sed -i "s|.*URL.*|    \"URL\": \"/me\",|" service.json
fi
sed -i "s|__URL__|${URL}|g" service.html_
# JSON values cannot contain quotes "
#URL_JSON=$(echo ${URL} | sed 's|\"|\\\\\"|g')
#sed -i "s|.*URL.*|    \"URL\": \"${URL_JSON}\",|" service.json
sed -i "s|.*PORT.*|    \"PORT\": \"${openPort}\",|" service.json
SLUG=$(echo ${URLEND} | sed 's|\"|\\\\\"|g')
sed -i "s|.*SLUG.*|    \"SLUG\": \"${SLUG}\",|" service.json

mv service.html_ service.html
echo

# RUNNING SESSION WRAPPER
if ! [ -f "${session_wrapper_dir}/session_wrapper.sh" ]; then
    displayErrorMessage "ERROR: File ${session_wrapper_dir}/session_wrapper.sh was not found --> Exiting workflow"
    exit 1
fi

bash ${session_wrapper_dir}/session_wrapper.sh 

if [ -f "kill.sh" ]; then
    # Only run if file exists. The kill.sh file is moved to _kill.sh after execution.
    # This is done to prevent the file form running twice which would generate errors.
    # We don't want kill.sh to change the status to cancelled!
    sed -i  "s/.*sed -i.*//" kill.sh  
    bash kill.sh
fi

exit 0