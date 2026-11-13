#!/usr/bin/env bash
# Reproduces the rolling-update + rollback demo shown in docs/k8s-demo.txt.
# Prereqs: kind cluster with the app deployed (`kubectl apply -k k8s/`) and image
# ghcr.io/asad6426/devops-task:1.1.0 available to the cluster.
set -euo pipefail

NS=devops-task
NEW_IMAGE=${1:-ghcr.io/asad6426/devops-task:1.1.0}

run() { echo "\$ $*"; "$@" 2>&1; echo; }
version() { kubectl -n "$NS" exec deploy/devops-task -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/').read().decode())"; }

# Load generator inside the cluster: hits the Service every 50ms for 150s and counts non-200s.
kubectl delete pod -n default loadgen --ignore-not-found >/dev/null
# shellcheck disable=SC2016 # the loop is meant to expand inside the pod, not here
kubectl run loadgen -n default --image=curlimages/curl:8.11.1 --restart=Never --command -- sh -c \
  'end=$(($(date +%s)+150)); ok=0; fail=0; while [ $(date +%s) -lt $end ]; do c=$(curl -s -o /dev/null -m 2 -w "%{http_code}" http://devops-task.devops-task.svc/); if [ "$c" = 200 ]; then ok=$((ok+1)); else fail=$((fail+1)); echo "FAIL $c $(date +%T)"; fi; sleep 0.05; done; echo "RESULT ok=$ok fail=$fail"' >/dev/null
kubectl wait -n default --for=condition=Ready pod/loadgen --timeout=90s >/dev/null
sleep 3

echo "### 1. Current state"
run kubectl -n "$NS" get deploy devops-task -o wide
echo "\$ curl / (from inside a pod)"; version; echo

echo "### 2. Rolling update to ${NEW_IMAGE} while the load generator hits the Service"
run kubectl -n "$NS" set image deploy/devops-task app="$NEW_IMAGE"
run kubectl -n "$NS" annotate deploy/devops-task kubernetes.io/change-cause="set image ${NEW_IMAGE}" --overwrite
run kubectl -n "$NS" rollout status deploy/devops-task --timeout=180s
echo "\$ curl / (from inside a pod)"; version; echo
run kubectl -n "$NS" rollout history deploy/devops-task

echo "### 3. Rollback with kubectl rollout undo"
run kubectl -n "$NS" rollout undo deploy/devops-task
run kubectl -n "$NS" rollout status deploy/devops-task --timeout=180s
echo "\$ curl / (from inside a pod)"; version; echo
run kubectl -n "$NS" get pods

echo "### 4. Load generator result (covers both rollouts)"
kubectl wait -n default --for=jsonpath='{.status.phase}'=Succeeded pod/loadgen --timeout=200s >/dev/null
echo "\$ kubectl logs loadgen"
kubectl logs -n default loadgen | tail -5
kubectl delete pod -n default loadgen >/dev/null
echo
echo "### 5. HPA"
run kubectl -n "$NS" get hpa
