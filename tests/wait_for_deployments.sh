#!/bin/sh

if [ -z "$1" ]; then
    echo "Usage: $0 DEPLOYMENT1 [DEPLOYMENT2 | ... ]"
fi

DEPLOYMENTS="$*"
terminate() {
    exit 1
}
trap terminate TERM QUIT

TEST_REPLICA=${TEST_REPLICA:-1}
PULL_TIMEOUT=${PULL_TIMEOUT:-300s}
INDIVIDUAL_DEPLOYMENT_TIMEOUT=${INDIVIDUAL_DEPLOYMENT_TIMEOUT:-120s}

## We will wait for the first pod to be ready; we do this, as on a pristine cluster
## most of the time may be spent pulling a Docker Image. Once the Docker Image is pulled however,
## all the other deployments should proceed quickly.
deployment="$(basename "${1%".yaml"}" | tr '.' '-' | tr '_' '-')"
echo "Waiting for the first deployment pod to be initialized, (waiting for Docker pull)"
kubectl wait --timeout="${PULL_TIMEOUT}" --for=condition=initialized "pod/${deployment}-timescaledb-0"

## By using a Job instead of relying on tools on the system that is running the tests, we verify at least
## the following:
##  * There is a primary running
##  * There is a primary service pointing to the primary
##  * There is a replica running
##  * There is a replica service pointing to the replica(s)
##  * The password set is valid for both the primary and the replica
##  * Inserting data works on the primary
##  * TimescaleDB is installed and can create hypertables
##  * Changes made on the primary propagate to (at least one) replica
for deployment in "$@"; do
    deployment="$(basename "${deployment%".yaml"}" | tr '.' '-' | tr '_' '-')"
    JOBNAME="${deployment}"
    kubectl delete "job/${JOBNAME}" > /dev/null 2>&1
    ## Poor man's kustomize, for now, this seems adequate for its purposes though
    sed "s/example\$/${deployment}/g; s/TEST_REPLICA, value: \".*\"/TEST_REPLICA, value: \"${TEST_REPLICA}\"/g" "$(dirname "$0")/wait_for_example_job.yaml" \
      | kubectl apply -f -
done

for deployment in "$@"; do
    deployment="$(basename "${deployment%".yaml"}" | tr '.' '-' | tr '_' '-')"
    JOBNAME="${deployment}"
    echo "Waiting for ${JOBNAME} to complete ..."
    if ! kubectl wait --timeout="${INDIVIDUAL_DEPLOYMENT_TIMEOUT}" --for=condition=complete "job/${JOBNAME}"; then
        echo "===================================================="
        echo " ERROR: deployment ${deployment}, details:"
        echo "===================================================="
        kubectl get pod,ep,configmap,service -l app="${deployment}-timescaledb"
        echo "...................................................."
        kubectl describe "pod/${deployment}-timescaledb-0"
        kubectl logs "pod/${deployment}-timescaledb-0"
        echo "...................................................."
        kubectl describe "pod/${deployment}-timescaledb-1"
        kubectl logs "pod/${deployment}-timescaledb-1"
        echo "...................................................."
        kubectl logs "job/${JOBNAME}"
        echo "===================================================="
        exit 1
    fi
    echo "===================================================="
    echo " OK: deployment ${deployment}"
    echo "===================================================="
done

exit 0
