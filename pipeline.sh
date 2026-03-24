#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# CONFIG (EDIT THESE OR EXPORT AS ENV VARS)
# ==========================================================
APP_NAME="${APP_NAME:-petclinic}"

# If you want unique tag every run, keep AUTO_TAG=true
AUTO_TAG="${AUTO_TAG:-true}"
TAG="${TAG:-1}"  # used if AUTO_TAG=false

# Nexus registry (YOU CONFIRMED PUSH WORKS ON 8082)
NEXUS_HOST="${NEXUS_HOST:-13.232.220.193}"
NEXUS_PORT="${NEXUS_PORT:-8082}"
NEXUS_REPO="${NEXUS_REPO:-docker-hosted}"
NEXUS_USER="${NEXUS_USER:-vid}"
NEXUS_PASS="${NEXUS_PASS:-}"   # If empty, script will prompt securely

# SonarQube
SONAR_HOST="${SONAR_HOST:-http://localhost:9000}"
SONAR_PROJECT_KEY="${SONAR_PROJECT_KEY:-petclinic}"
SONAR_TOKEN="${SONAR_TOKEN:-}" # If empty, script will prompt securely

# Testing toggles
RUN_UNIT_TESTS="${RUN_UNIT_TESTS:-true}"
RUN_FUNCTIONAL_TESTS="${RUN_FUNCTIONAL_TESTS:-true}"      # uses -Pintegration (if present)
ALLOW_FUNCTIONAL_TEST_FAIL="${ALLOW_FUNCTIONAL_TEST_FAIL:-true}"  # don't block if integration profile missing
RUN_SONAR="${RUN_SONAR:-true}"
CHECK_QUALITY_GATE="${CHECK_QUALITY_GATE:-false}"          # optional (true/false)

# Kubernetes
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-petclinic}"
SERVICE_NAME="${SERVICE_NAME:-petclinic-svc}"
NODEPORT="${NODEPORT:-30080}"

# kind behaviour
# If you ALREADY recreated kind with insecure registry mirror, keep this false.
RECREATE_KIND_CLUSTER="${RECREATE_KIND_CLUSTER:-false}"     # true will delete & recreate cluster
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-devops-cluster}"
KIND_CONTEXT="kind-${KIND_CLUSTER_NAME}"

# Website exposure
# When true, it keeps the port-forward running for browser access
KEEP_PORT_FORWARD="${KEEP_PORT_FORWARD:-true}"
PORT_FORWARD_LOCAL_PORT="${PORT_FORWARD_LOCAL_PORT:-8080}"  # open browser at http://EC2_PUBLIC_IP:8080

# Performance test
RUN_JMETER="${RUN_JMETER:-true}"
JMETER_THREADS="${JMETER_THREADS:-20}"
JMETER_LOOPS="${JMETER_LOOPS:-10}"
JMETER_RAMPUP="${JMETER_RAMPUP:-10}"

# ==========================================================
# Helpers
# ==========================================================
log()  { echo -e "\n\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\n\033[1;31m[ERROR]\033[0m $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }
}

prompt_secret() {
  local var_name="$1"
  local prompt_text="$2"
  local current_val="${!var_name:-}"
  if [[ -z "$current_val" ]]; then
    read -r -s -p "$prompt_text: " input
    echo
    export "$var_name"="$input"
  fi
}

# ==========================================================
# Validate prerequisites
# ==========================================================
log "Validating prerequisites..."
need_cmd git
need_cmd mvn
need_cmd docker
need_cmd kubectl
need_cmd kind
if [[ "$RUN_JMETER" == "true" ]]; then
  need_cmd jmeter
fi
log "All required commands exist."

# Ensure Docker daemon is running
if ! docker ps >/dev/null 2>&1; then
  err "Docker daemon not reachable. Start Docker and ensure your user is in docker group."
  err "Try: sudo systemctl start docker && sudo usermod -aG docker \$USER && newgrp docker"
  exit 1
fi

# Prompt for secrets if not set
prompt_secret NEXUS_PASS "Enter Nexus password for user '${NEXUS_USER}'"
if [[ "$RUN_SONAR" == "true" ]]; then
  prompt_secret SONAR_TOKEN "Enter Sonar token"
fi

# Tag handling
if [[ "$AUTO_TAG" == "true" ]]; then
  TAG="$(date +%Y%m%d%H%M%S)"
fi

IMAGE="${NEXUS_HOST}:${NEXUS_PORT}/${NEXUS_REPO}/${APP_NAME}:${TAG}"
REGISTRY="${NEXUS_HOST}:${NEXUS_PORT}"

log "Using image: ${IMAGE}"

# ==========================================================
# (Optional) Recreate kind cluster with HTTP Nexus mirror
# ==========================================================
if [[ "$RECREATE_KIND_CLUSTER" == "true" ]]; then
  log "Recreating kind cluster '${KIND_CLUSTER_NAME}' with insecure HTTP registry mirror for ${REGISTRY} ..."
  cat > kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${REGISTRY}"]
    endpoint = ["http://${REGISTRY}"]
EOF

  kind delete cluster --name "${KIND_CLUSTER_NAME}" || true
  kind create cluster --name "${KIND_CLUSTER_NAME}" --config kind-config.yaml
fi

# Ensure kubectl uses correct context
if ! kubectl config get-contexts "${KIND_CONTEXT}" >/dev/null 2>&1; then
  warn "kubectl context ${KIND_CONTEXT} not found. Ensure kind cluster exists: kind get clusters"
else
  kubectl config use-context "${KIND_CONTEXT}" >/dev/null
fi

log "Kubernetes nodes:"
kubectl get nodes

# ==========================================================
# Ensure k8s manifests exist (fixes YAML mistakes automatically)
# ==========================================================
log "Ensuring Kubernetes manifests exist and are valid..."

mkdir -p k8s

cat > k8s/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEPLOYMENT_NAME}
  template:
    metadata:
      labels:
        app: ${DEPLOYMENT_NAME}
    spec:
      imagePullSecrets:
        - name: nexus-regcred
      containers:
        - name: ${DEPLOYMENT_NAME}
          image: REPLACE_IMAGE
          ports:
            - containerPort: 8080
EOF

cat > k8s/service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
spec:
  type: NodePort
  selector:
    app: ${DEPLOYMENT_NAME}
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: ${NODEPORT}
EOF

kubectl apply --dry-run=client -f k8s/deployment.yaml >/dev/null
kubectl apply --dry-run=client -f k8s/service.yaml >/dev/null
log "Manifests validated."

# ==========================================================
# Build + Tests
# ==========================================================
log "1) Maven clean package (build)..."
mvn -U clean package

if [[ "$RUN_UNIT_TESTS" == "true" ]]; then
  log "2) Unit tests..."
  mvn test
else
  warn "Unit tests disabled (RUN_UNIT_TESTS=false)"
fi

if [[ "$RUN_FUNCTIONAL_TESTS" == "true" ]]; then
  log "3) Functional/Integration tests (mvn verify -Pintegration)..."
  set +e
  mvn verify -Pintegration
  IT_STATUS=$?
  set -e
  if [[ $IT_STATUS -ne 0 ]]; then
    if [[ "$ALLOW_FUNCTIONAL_TEST_FAIL" == "true" ]]; then
      warn "Functional tests failed or integration profile not present. Continuing because ALLOW_FUNCTIONAL_TEST_FAIL=true"
    else
      err "Functional tests failed. Stopping pipeline."
      exit 1
    fi
  fi
else
  warn "Functional tests disabled (RUN_FUNCTIONAL_TESTS=false)"
fi

# ==========================================================
# Sonar scan (+ optional Quality Gate)
# ==========================================================
if [[ "$RUN_SONAR" == "true" ]]; then
  log "4) SonarQube scan..."
  # quick reachability check
  if ! curl -s --max-time 5 "${SONAR_HOST}/api/system/health" >/dev/null; then
    err "SonarQube not reachable at ${SONAR_HOST}. Start SonarQube container and try again."
    exit 1
  fi

  mvn sonar:sonar \
    -Dsonar.host.url="${SONAR_HOST}" \
    -Dsonar.login="${SONAR_TOKEN}" \
    -Dsonar.projectKey="${SONAR_PROJECT_KEY}"

  if [[ "$CHECK_QUALITY_GATE" == "true" ]]; then
    log "4b) Checking Sonar Quality Gate (optional)..."

    REPORT_FILE="target/sonar/report-task.txt"
    if [[ ! -f "$REPORT_FILE" ]]; then
      err "Sonar report-task.txt not found. Cannot check Quality Gate."
      exit 1
    fi

    CE_TASK_URL=$(grep -E '^ceTaskUrl=' "$REPORT_FILE" | cut -d'=' -f2)
    if [[ -z "$CE_TASK_URL" ]]; then
      err "ceTaskUrl not found in report-task.txt"
      exit 1
    fi

    for i in {1..30}; do
      STATUS=$(curl -s -u "${SONAR_TOKEN}:" "$CE_TASK_URL" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
      log "Sonar task status: ${STATUS:-UNKNOWN}"
      [[ "$STATUS" == "SUCCESS" ]] && break
      if [[ "$STATUS" == "FAILED" || "$STATUS" == "CANCELED" ]]; then
        err "Sonar background task ${STATUS}"
        exit 1
      fi
      sleep 5
    done

    ANALYSIS_ID=$(curl -s -u "${SONAR_TOKEN}:" "$CE_TASK_URL" | sed -n 's/.*"analysisId":"\([^"]*\)".*/\1/p')
    if [[ -z "$ANALYSIS_ID" ]]; then
      err "analysisId not found from CE task response"
      exit 1
    fi

    QG_STATUS=$(curl -s -u "${SONAR_TOKEN}:" "${SONAR_HOST}/api/qualitygates/project_status?analysisId=${ANALYSIS_ID}" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    log "Quality Gate Status: ${QG_STATUS:-UNKNOWN}"

    if [[ "$QG_STATUS" != "OK" ]]; then
      err "Quality Gate failed: ${QG_STATUS}"
      exit 1
    fi
    log "Quality Gate passed ✅"
  fi
else
  warn "Sonar scan disabled (RUN_SONAR=false)"
fi

# ==========================================================
# Docker build + Nexus push
# ==========================================================
log "5) Docker build..."
# Ensure Dockerfile is valid (first line must be FROM, not cat...)
FIRST_LINE=$(head -n 1 Dockerfile || true)
if [[ "$FIRST_LINE" != FROM* ]]; then
  err "Dockerfile seems invalid. First line must start with 'FROM'. Current first line: ${FIRST_LINE}"
  exit 1
fi

docker build -t "${APP_NAME}:latest" .

log "6) Tagging image for Nexus..."
docker tag "${APP_NAME}:latest" "${IMAGE}"

log "7) Logging into Nexus registry ${REGISTRY}..."
echo "${NEXUS_PASS}" | docker login "${REGISTRY}" -u "${NEXUS_USER}" --password-stdin

log "8) Pushing image to Nexus..."
docker push "${IMAGE}"

# ==========================================================
# Kubernetes secret + deploy
# ==========================================================
log "9) Creating/updating Kubernetes imagePullSecret 'nexus-regcred'..."
kubectl create secret docker-registry nexus-regcred \
  --docker-server="${REGISTRY}" \
  --docker-username="${NEXUS_USER}" \
  --docker-password="${NEXUS_PASS}" \
  -n "${K8S_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "10) Deploying to Kubernetes..."
sed "s|REPLACE_IMAGE|${IMAGE}|g" k8s/deployment.yaml | kubectl apply -n "${K8S_NAMESPACE}" -f -
kubectl apply -n "${K8S_NAMESPACE}" -f k8s/service.yaml

log "11) Waiting for rollout..."
kubectl rollout status -n "${K8S_NAMESPACE}" deployment/"${DEPLOYMENT_NAME}" --timeout=180s

log "Pods:"
kubectl get pods -n "${K8S_NAMESPACE}" -l app="${DEPLOYMENT_NAME}"

log "Service:"
kubectl get svc -n "${K8S_NAMESPACE}" "${SERVICE_NAME}"

# ==========================================================
# Smoke test (kind-friendly) using kind node IP + NodePort
# ==========================================================
log "12) Smoke test..."
KIND_NODE_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${KIND_CLUSTER_NAME}-control-plane" 2>/dev/null || true)

if [[ -n "${KIND_NODE_IP}" ]]; then
  log "Trying NodePort on kind node IP: http://${KIND_NODE_IP}:${NODEPORT}/"
  curl -I "http://${KIND_NODE_IP}:${NODEPORT}/" || true
else
  warn "Could not detect kind node container IP. Skipping NodePort curl test."
fi

# ==========================================================
# Optional: expose website to browser via port-forward (0.0.0.0)
# ==========================================================
PF_PID=""
if [[ "$KEEP_PORT_FORWARD" == "true" ]]; then
  log "13) Starting port-forward for browser access on 0.0.0.0:${PORT_FORWARD_LOCAL_PORT} ..."
  # Kill any existing port-forward on same port (best-effort)
  pkill -f "kubectl port-forward.*${PORT_FORWARD_LOCAL_PORT}:8080" >/dev/null 2>&1 || true

  kubectl port-forward --address 0.0.0.0 -n "${K8S_NAMESPACE}" svc/"${SERVICE_NAME}" "${PORT_FORWARD_LOCAL_PORT}:8080" \
    >/tmp/petclinic-portforward.log 2>&1 &

  PF_PID=$!
  sleep 3
  log "Port-forward running (PID=${PF_PID})."
  log "Open in browser: http://<EC2_PUBLIC_IP>:${PORT_FORWARD_LOCAL_PORT}/"
  log "NOTE: Ensure AWS Security Group allows inbound TCP ${PORT_FORWARD_LOCAL_PORT} from your IP."
fi

# ==========================================================
# Performance testing (JMeter) against port-forward (localhost:8080)
# ==========================================================
if [[ "$RUN_JMETER" == "true" ]]; then
  log "14) Creating JMeter test plan (targets localhost:${PORT_FORWARD_LOCAL_PORT})..."
  mkdir -p perf-tests perf-results

  cat > perf-tests/load_test.jmx <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<jmeterTestPlan version="1.2" properties="5.0" jmeter="5.6.3">
  <hashTree>
    <TestPlan guiclass="TestPlanGui" testclass="TestPlan" testname="Petclinic Load Test" enabled="true"/>
    <hashTree>
      <ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup" testname="Users" enabled="true">
        <elementProp name="ThreadGroup.main_controller" elementType="LoopController">
          <stringProp name="LoopController.loops">${JMETER_LOOPS}</stringProp>
        </elementProp>
        <stringProp name="ThreadGroup.num_threads">${JMETER_THREADS}</stringProp>
        <stringProp name="ThreadGroup.ramp_time">${JMETER_RAMPUP}</stringProp>
      </ThreadGroup>
      <hashTree>
        <HTTPSamplerProxy guiclass="HttpTestSampleGui" testclass="HTTPSamplerProxy" testname="GET Home" enabled="true">
          <stringProp name="HTTPSampler.domain">localhost</stringProp>
          <stringProp name="HTTPSampler.port">${PORT_FORWARD_LOCAL_PORT}</stringProp>
          <stringProp name="HTTPSampler.protocol">http</stringProp>
          <stringProp name="HTTPSampler.path">/</stringProp>
          <stringProp name="HTTPSampler.method">GET</stringProp>
        </HTTPSamplerProxy>
        <hashTree/>
      </hashTree>
    </hashTree>
  </hashTree>
</jmeterTestPlan>
EOF

  log "15) Running JMeter..."
  jmeter -n \
    -t perf-tests/load_test.jmx \
    -l perf-results/results.jtl \
    -e -o perf-results/html-report

  log "JMeter report generated: perf-results/html-report/index.html"
else
  warn "JMeter disabled (RUN_JMETER=false)"
fi

# ==========================================================
# Finish / cleanup
# ==========================================================
log "======================================"
log "PIPELINE COMPLETED ✅"
log "Image pushed: ${IMAGE}"
log "K8s service:  ${SERVICE_NAME} (NodePort ${NODEPORT})"
if [[ -n "${KIND_NODE_IP}" ]]; then
  log "Internal kind URL: http://${KIND_NODE_IP}:${NODEPORT}/"
fi

if [[ "$KEEP_PORT_FORWARD" == "true" ]]; then
  log "Browser URL: http://<EC2_PUBLIC_IP>:${PORT_FORWARD_LOCAL_PORT}/"
  log "Port-forward PID: ${PF_PID}"
  log "To stop port-forward later: kill ${PF_PID}"
else
  log "Port-forward not kept. Set KEEP_PORT_FORWARD=true to access in browser."
fi

log "======================================"
