#!/bin/sh

usage () {
    cat <<HELP_USAGE

    $0  [-c] [-a <ARTIFACTS DIR>]

    Run gating tests on test runners provisioned by linchpin and deployed with ansible,
    syncing artifacts to localhost.

   -c  Run configuration check.
   -a  Local host directory for fetching artifacts from test runner.
HELP_USAGE
}

CHECK_ONLY="no"
ARTIFACTS="/tmp/artifacts"

while getopts "ca:" opt; do
    case $opt in
        c)
            # Run only configuration check
            CHECK_ONLY="yes"
            ;;
        a)
            # Set up directory for fetching artifacts
            ARTIFACTS="${OPTARG}"
            ;;
        *)
            echo "Usage:"
            usage
            exit 1
            ;;
    esac
done

DEFAULT_CRED_FILENAME="clouds.yml"
CRED_DIR="${HOME}/.config/linchpin"
CRED_FILE_PATH=${CRED_DIR}/${DEFAULT_CRED_FILENAME}
TOPOLOGY_FILE_PATH="linchpin/topologies/gating-test.yml"
ANSIBLE_CFG_PATH="remote_config/ansible.cfg"

CHECK_RESULT=0


############################## Check the configuration

echo
echo "========= Dependencies are installed"
echo "linchpin and ansible are required to be installed."
echo "For linchpin installation instructions see:"
echo "https://linchpin.readthedocs.io/en/latest/installation.html"
echo

if ! type ansible &> /dev/null; then
    echo "=> FAILED: ansible package is not installed"
    CHECK_RESULT=1
else
    echo "=> OK: ansible is installed"
fi

if ! type linchpin &> /dev/null; then
    echo "=> FAILED: linchpin is not installed"
    CHECK_RESULT=1
else
    echo "=> OK: linchpin is installed"
fi


echo
echo "========= Linchpin cloud credentials configuration"
echo "The credentials file for linchpin provisioner should be in ${CRED_DIR}"
echo "The name of the file and the profile to be used is defined by"
echo "   resource_groups.credentials variables in the topology file"
echo "   (${TOPOLOGY_FILE_PATH})"
echo

config_changed=0
if [[ -f ${TOPOLOGY_FILE_PATH} ]]; then
    grep -q 'filename:.*'${DEFAULT_CRED_FILENAME} ${TOPOLOGY_FILE_PATH}
    config_changed=$?
fi

if [[ ${config_changed} -eq 0 ]]; then
    if [[ -f ${CRED_FILE_PATH} ]]; then
        echo "=> OK: ${CRED_FILE_PATH} exists"
    else
        echo "=> FAILED: ${CRED_FILE_PATH} does not exist"
        CHECK_RESULT=1
    fi
else
    echo "=> NOT CHECKING: seems like this has been configured in a different way"
fi


echo
echo "========== Deployment ssh key configuration"
echo "The ssh key used for deployment with ansible has to be defined by"
echo "private_key_file variable in ${ANSIBLE_CFG_PATH}"
echo "and match the key used for provisioning of the machines with linchpin"
echo "which is defined by resource_groups.resource_definitions.keypair variable"
echo "in topology file (${TOPOLOGY_FILE_PATH})."
echo


deployment_key_defined_line=$(grep 'private_key_file.*=.*[^\S]' ${ANSIBLE_CFG_PATH})
if [[ -n "${deployment_key_defined_line}" ]]; then
    echo "=> OK: ${ANSIBLE_CFG_PATH}: ${deployment_key_defined_line}"
else
    echo "=> FAILED: deployment ssh key not defined in ${ANSIBLE_CFG_PATH}"
    CHECK_RESULT=1
fi

linchpin_keypair=$(grep "keypair:" ${TOPOLOGY_FILE_PATH} | uniq)
echo "=> INFO: should be the same key as ${TOPOLOGY_FILE_PATH}: ${linchpin_keypair}"


if [[ ${CHECK_RESULT} -ne 0 ]]; then
echo
echo "=> Configuration check FAILED, see FAILED messages above."
echo
fi

if [[ ${CHECK_ONLY} == "yes" || ${CHECK_RESULT} -ne 0 ]]; then
    exit ${CHECK_RESULT}
fi


############################## Run the tests

set -x

### Clean the linchpin generated inventory
rm -rf linchpin/inventories/*.inventory

### Provision test runner
linchpin -v --workspace linchpin -p linchpin/PinFile -c linchpin/linchpin.conf up

### Pass inventory generated by linchpin to ansible
cp linchpin/inventories/*.inventory remote_config/inventory/linchpin.inventory

### Use remote hosts in tests playbooks
ansible-playbook set_tests_to_run_on_remote.yml

### Use the ansible configuration for running tests on remote host
export ANSIBLE_CONFIG=${ANSIBLE_CFG_PATH}

### Configure remote user for playbooks
# By default root is used but it can be fedora or cloud-user for cloud images
for USER in root fedora cloud-user; do
  ansible-playbook --extra-vars="remote_user=$USER" check_and_set_remote_user.yml
done

### Prepare test runner
ansible-playbook --extra-vars="artifacts=${ARTIFACTS}" prepare-test-runner.yml
### Run test on test runner (supply artifacts variable which is testing system's job)
ansible-playbook --extra-vars="artifacts=${ARTIFACTS}" tests.yml

### Destroy the test runner
linchpin -v --workspace linchpin -p linchpin/PinFile -c linchpin/linchpin.conf destroy

