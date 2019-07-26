#!/usr/bin/env bash

if [[ -d "streamsets-cloud-agent" ]]; then
  echo "Please remove the existing streamsets-cloud-agent directory and try again"
  exit 1
fi
mkdir streamsets-cloud-agent && cd streamsets-cloud-agent

readonly SCRIPT_URL=https://agent.streamsetscloud.com

# Download script files
curl -O "$SCRIPT_URL"/agent_commands.sh
curl -O "$SCRIPT_URL"/delagent.sh
curl -O "$SCRIPT_URL"/previewer-crd.yaml
curl -O "$SCRIPT_URL"/template-fetcher.conf
curl -O "$SCRIPT_URL"/template-launcher.conf
curl -O "$SCRIPT_URL"/update-conf.sh

mkdir yaml && cd yaml

curl -O "$SCRIPT_URL"/yaml/aks_ingress.yaml
curl -O "$SCRIPT_URL"/yaml/gke_ingress.yaml
curl -O "$SCRIPT_URL"/yaml/metric-server.yaml
curl -O "$SCRIPT_URL"/yaml/minikube_ingress.yaml
curl -O "$SCRIPT_URL"/yaml/nginx_ingress.yaml
curl -O "$SCRIPT_URL"/yaml/pv-extrta-lib.yaml
curl -O "$SCRIPT_URL"/yaml/pv-gpd.yaml
curl -O "$SCRIPT_URL"/yaml/pv-hostpath.yaml
curl -O "$SCRIPT_URL"/yaml/pvc-test.yaml
curl -O "$SCRIPT_URL"/yaml/streamsets-agent-roles.yaml
curl -O "$SCRIPT_URL"/yaml/streamsets-agent-service.yaml
curl -O "$SCRIPT_URL"/yaml/template-pv-dir-mount.yaml
curl -O "$SCRIPT_URL"/yaml/template-streamsets-agent.yaml

cd .. && mkdir util && cd util

curl -O "$SCRIPT_URL"/util/validators.sh
curl -O "$SCRIPT_URL"/util/usage.sh

cd ..

source util/validators.sh # utilities for validating files, commands etc as pre-reqs

source util/usage.sh # Usage in file to improve readability

# Check that the arguments either begin with -h, all needed args are set as env variables, or all args are present
if [[ $# -gt 0 && "$1" == "-h" ]]; then
  usage
  exit 0
elif [[ $# -ge 10 ]]; then
  while [[ ! -z "$1" ]]; do
    if [[ !("$2") ]]; then
      usage
      exit 1
    fi
    case "$1" in
      --install-type)
        INSTALL_TYPE="$2"
        ;;
      --agent-id)
        AGENT_ID="$2"
        ;;
      --credentials)
        AGENT_CREDENTIALS="$2"
        ;;
      --environment-id)
        ENV_ID="$2"
        ;;
      --streamsets-cloud-url)
        STREAMSETS_CLOUD_URL="$2"
        ;;
      --external-url)
        INGRESS_URL="$2"
        ;;
      --hostname)
        PUBLICIP="$2"
        ;;
      --agent-crt)
        AGENT_CRT="$2"
        ;;
      --agent-key)
        AGENT_KEY="$2"
        ;;
      --directory)
        PATH_MOUNT="$2"
        ;;
      --namespace)
        NS="$2"
        ;;
    esac
    shift
    shift
  done
fi

if [[ !("$AGENT_ID" && "$AGENT_CREDENTIALS" && "$ENV_ID" && "$STREAMSETS_CLOUD_URL" && "$INSTALL_TYPE") ]]; then
  incorrectUsage
  usage
  exit 1
fi
if [[ $INSTALL_TYPE == "LINUX_VM" && !("$PUBLICIP") ]]; then
  incorrectUsage
  usage
  exit 1
fi
if [[ (("$AGENT_KEY") && !("$AGENT_CRT")) || (!("$AGENT_KEY") && ("$AGENT_CRT")) ]]; then
  echo "Missing agent key or certificate"
  exit 1
fi
if [[ "$PATH_MOUNT" && $INSTALL_TYPE != "LINUX_VM" ]]; then
  echo "Directory to mount specified on an install type which does not support mounted directories"
  exit 1
fi

# Get the directory the script is from
SCRIPT_DIR="$(dirname "$(readlink "$0")")"

validate_file "${SCRIPT_DIR}/yaml/metric-server.yaml"
validate_file "${SCRIPT_DIR}/yaml/template-streamsets-agent.yaml"
validate_file "${SCRIPT_DIR}/update-conf.sh"
validate_file "${SCRIPT_DIR}/template-launcher.conf"
validate_file "${SCRIPT_DIR}/template-fetcher.conf"
validate_file "${SCRIPT_DIR}/yaml/streamsets-agent-roles.yaml"

# Need to generate UUIDs, uuidgen is available on OSX and most Linux else cat
UUID_COMMAND="uuidgen"
if [[ -z $(which uuidgen) ]]; then
  UUID_COMMAND="cat /proc/sys/kernel/random/uuid"
fi

NS=${NS:-default}

# Install Kubernetes and its dependencies
if [[ $INSTALL_TYPE == "LINUX_VM" ]]; then
  # Install kubernetes
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 664" sh -s -

  # Wait for Kubernetes to start up
  until [[ $(kubectl get namespaces | grep "default") ]] && kubectl cluster-info ; do
    sleep 1
  done
fi

[[ $INSTALL_TYPE == "LINUX_VM" ]] || [[ $INSTALL_TYPE == "DOCKER" ]] || [[ $INSTALL_TYPE == "AKS" ]] && kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.24.1/deploy/mandatory.yaml

[[ $INSTALL_TYPE == "LINUX_VM" ]] || [[ $INSTALL_TYPE == "DOCKER" ]] || [[ $INSTALL_TYPE == "AKS" ]] && kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.24.1/deploy/provider/cloud-generic.yaml

#[[ $INSTALL_TYPE == "DOCKER" ]] &&  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.24.1/deploy/provider/baremetal/service-nodeport.yaml

[[ $NS != "default" ]] && kubectl create namespace $NS

kubectl create -f yaml/streamsets-agent-service.yaml -n $NS

# User input
source update-conf.sh

# create docker secret
kubectl create secret docker-registry dockercred --docker-server=docker.io --docker-username=$DOCKER_USER_NAME --docker-password=$DOCKER_PASSWORD --docker-email=$DOCKER_EMAIL -n $NS

echo $PATH_MOUNT

[[ ! -z "$PATH_MOUNT" ]] && kubectl create -f yaml/pv-dir-mount.yaml

# Deploy the configuration for the operator
kubectl create configmap launcher-conf --from-file=launcher.conf -n $NS

# Install Agent Roles
kubectl apply -f yaml/streamsets-agent-roles.yaml -n $NS

# Install Agent
kubectl apply -f yaml/streamsets-agent.yaml -n $NS

# Wait for Agent to start up
WAIT_MESSAGE="Starting Agent. This may take a few minutes...."
if [[ $INSTALL_TYPE == "GKE" ]]; then
  WAIT_MESSAGE="Starting Agent. This may take up to 20 minutes...."
fi

i=1
sp="/-\|"
echo -n "$WAIT_MESSAGE"
until [[ "$(kubectl get pods -n $NS 2> /dev/null | grep launcher | awk '{print $3}')" = "Running" && "$(kubectl get pods -n $NS 2> /dev/null | grep launcher | awk '{print $2}')" = "1/1" && "$(curl -LI -k -XGET $INGRESS_URL -o /dev/null -w '%{http_code}\n' -s)" = "200" ]] ; do
  printf "\b${sp:i++%${#sp}:1}"
  sleep 1
done

echo ""
echo -e "\e[32m+---------------------------------------------------------+"
echo -e "\e[2m-----------------------------------------------------------"
echo -e "\e[0m\e[39mAgent is running at: \e[32m$INGRESS_URL"
[[  $SHOULD_ACCEPT_SELF_SIGNED == 1 ]] && echo -e "\e[33mGo to \e[32m$INGRESS_URL \e[33min the browser and accept the self-signed certificate."
echo -e "\e[2m\e[32m-----------------------------------------------------------"
echo -e "\e[0m\e[32m+---------------------------------------------------------+"