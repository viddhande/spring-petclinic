#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# CONFIG (EDIT OR EXPORT AS ENV VARS)
# ==========================================================
APP_NAME="${APP_NAME:-petclinic}"

# Tagging
AUTO_TAG="${AUTO_TAG:-true}"       # true => timestamp tag each run
TAG="${TAG:-1}"                    # used if AUTO_TAG=false

# Nexus (your working endpoint)
NEXUS_HOST="${NEXUS_HOST:-13.232.220.193}"
NEXUS_PORT="${NEXUS_PORT:-8082}"
NEXUS_REPO="${NEXUS_REPO:-docker-hosted}"
NEXUS_USER="${NEXUS_USER:-vid}"
NEXUS_PASS="${NEXUS_PASS:-}"       # if empty => prompt securely

# SonarQube
RUN_SONAR="${RUN_SONAR:-true}"
SONAR_HOST="${SONAR_HOST:-http://localhost:9000}"
SONAR_PROJECT_KEY="${SONAR_PROJECT_KEY:-petclinic}"
SONAR_TOKEN="${SONAR_TOKEN:-}"     # if empty => prompt securely

# Tests
RUN_UNIT_TESTS="${RUN_UNIT_TESTS:-true}"
RUN_FUNCTIONAL_TESTS="${RUN_FUNCTIONAL_TESTS:-true}"            # mvn verify -Pintegration
ALLOW_FUNCTIONAL_TEST_FAIL="${ALLOW_FUNCTIONAL_TEST_FAIL:-true}"# continue if integration profile missing/fails

# Kubernetes
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-petclinic}"
SERVICE_NAME="${SERVICE_NAME:-petclinic-svc}"
NODEPORT="${NODEPORT:-30080}"

# kind cluster control (keep false for your current working cluster)
RECREATE_KIND_CLUSTER="${RECREATE_KIND_CLUSTER:-false}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-devops-cluster}"
KIND_CONTEXT="kind-${KIND_CLUSTER_NAME}"

# Browser visibility (IMPORTANT)
KEEP_PORT_FORWARD="${KEEP_PORT_FORWARD:-true}"
PORT_FORWARD_LOCAL_PORT="${PORT_FORWARD_LOCAL_PORT:-8080}"       # browser uses http://EC2_PUBLIC_IP:8080

# Performance test (optional)
RUN_JMETER="${RUN_JMETER:-false}"                                # OFF by default (you wanted deploy+browser)
JMETER_THREADS="${JMETER_THREADS:-20}"
JMETER_LOOPS="${JMETER_LOOPS:-10}"
JMETER_RAMPUP="${JMETER_RAMPUP:-10}"

# Store perf output OUTSIDE repo (avoid Maven scanning / OOM)
PERF_BASE_DIR="${PERF_BASE_DIR:-/tmp}"

# ==========================================================
# Helpers
# ==========================================================
log()  { echo -e "\n\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\n\033[1;31m[ERROR]\033[0m $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

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

TMP_KIND_CONFIG=""
cleanup() { [[ -n "${TMP_KIND_CONFIG}" && -f "${TMP_KIND_CONFIG}" ]] && rm -f "${TMP_KIND_CONFIG}" || true; }
trap cleanup EXIT

# ==========================================================
# Validate prerequisites
# ==========================================================
log "Validating prerequisites..."
need_cmd git
need_cmd mvn
need_cmd docker
need_cmd kubectl
need_cmd kind
if [[ "$RUN_JMETER" == "true" ]]; then need_cmd jmeter; fi
log "All required commands exist."

# Docker daemon check
if ! docker ps >/dev/null 2>&1; then
  err "Docker daemon not reachable. Try: sudo systemctl start docker"
  exit 1
fi

# --- IMPORTANT CLEANUP to avoid Maven checkstyle/nohttp scanning huge perf output in repo ---
rm -rf perf-results perf-tests 2>/dev/null || true
rm -f kind-config.yaml 2>/dev/null || true

# Prompt for secrets (DO NOT hardcode passwords)
prompt_secret NEXUS_PASS "Enter Nexus password for user '${NEXUS_USER}'"
if [[ "$RUN_SONAR" == "true" ]]; then
  prompt_secret SONAR_TOKEN "Enter Sonar token"
fi

# Tag selection
if [[ "$AUTO_TAG" == "true" ]]; then
  TAG="$(date +%Y%m%d%H%M%S)"
fi

IMAGE="${NEXUS_HOST}:${NEXUS_PORT}/${NEXUS_REPO}/${APP_NAME}:${TAG}"
REGISTRY="${NEXUS_HOST}:${NEXUS_PORT}"

log "Using image: ${IMAGE}"

# ==========================================================
# Optional: recreate kind cluster with HTTP registry mirror
# (config stored in /tmp to avoid Maven NoHttp violation)
# ==========================================================
if [[ "$RECREATE_KIND_CLUSTER" == "true" ]]; then
  log "Recreating kind cluster '${KIND_CLUSTER_NAME}' with HTTP mirror for ${REGISTRY} ..."
  TMP_KIND_CONFIG="/tmp/kind-config-${KIND_CLUSTER_NAME}.yaml"

  cat > "${TMP_KIND_CONFIG}" <<EOF_KIND
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${REGISTRY}"]
    endpoint = ["http://${REGISTRY}"]
EOF_KIND

  kind delete cluster --name "${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true
  kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${TMP_KIND_CONFIG}"
fi

# Ensure correct kubectl context
if kubectl config get-contexts "${KIND_CONTEXT}" >/dev/null 2>&1; then
  kubectl config use-context "${KIND_CONTEXT}" >/dev/null
else
  warn "kubectl context ${KIND_CONTEXT} not found. Ensure kind cluster exists."
fi

log "Kubernetes nodes:"
kubectl get nodes

# ==========================================================
# Ensure manifests exist (always correct YAML)
# ==========================================================
log "Ensuring Kubernetes manifests exist and are valid..."
mkdir -p k8s

cat > k8s/deployment.yaml <<EOF_DEPLOY
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
EOF_DEPLOY

cat > k8s/service.yaml <<EOF_SVC
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
EOF_SVC

kubectl apply --dry-run=client -f k8s/deployment.yaml >/dev/null
kubectl apply --dry-run=client -f k8s/service.yaml >/dev/null
log "Manifests validated."

# ==========================================================
# Build + Tests
# ==========================================================
log "1) Maven clean package..."
export MAVEN_OPTS="${MAVEN_OPTS:- -Xmx1024m}"
mvn -U clean package

if [[ "$RUN_UNIT_TESTS" == "true" ]]; then
  log "2) Unit tests..."
  mvn test
fi

if [[ "$RUN_FUNCTIONAL_TESTS" == "true" ]]; then
  log "3) Functional/Integration tests..."
  set +e
  mvn verify -Pintegration
  IT_STATUS=$?
  set -e

  if [[ $IT_STATUS -ne 0 && "$ALLOW_FUNCTIONAL_TEST_FAIL" != "true" ]]; then
    err "Functional tests failed."
    exit 1
  fi
  [[ $IT_STATUS -ne 0 ]] && warn "Functional tests failed or profile missing. Continuing."
fi

# ==========================================================
# Sonar
# ==========================================================
if [[ "$RUN_SONAR" == "true" ]]; then
  log "4) SonarQube scan..."
  if ! curl -s --max-time 5 "${SONAR_HOST}/api/system/health" >/dev/null; then
    err "SonarQube not reachable at ${SONAR_HOST}"
    exit 1
  fi

  mvn sonar:sonar \
    -Dsonar.host.url="${SONAR_HOST}" \
    -Dsonar.login="${SONAR_TOKEN}" \
    -Dsonar.projectKey="${SONAR_PROJECT_KEY}"
fi

# ==========================================================
# Docker build + push to Nexus
# ==========================================================
log "5) Docker build..."
FIRST_LINE=$(head -n 1 Dockerfile || true)
if [[ "$FIRST_LINE" != FROM* ]]; then
  err "Dockerfile invalid. First line must start with 'FROM'. Found: ${FIRST_LINE}"
  exit 1
fi

docker build -t "${APP_NAME}:latest" .
docker tag "${APP_NAME}:latest" "${IMAGE}"

log "6) Docker login to Nexus ${REGISTRY}..."
echo "${NEXUS_PASS}" | docker login "${REGISTRY}" -u "${NEXUS_USER}" --password-stdin

log "7) Push image..."
docker push "${IMAGE}"

# ==========================================================
# K8s deploy
# ==========================================================
log "8) Create/Update imagePullSecret nexus-regcred..."
kubectl create secret docker-registry nexus-regcred \
  --docker-server="${REGISTRY}" \
  --docker-username="${NEXUS_USER}" \
  --docker-password="${NEXUS_PASS}" \
  -n "${K8S_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "9) Deploy to Kubernetes..."
sed "s|REPLACE_IMAGE|${IMAGE}|g" k8s/deployment.yaml | kubectl apply -n "${K8S_NAMESPACE}" -f -
kubectl apply -n "${K8S_NAMESPACE}" -f k8s/service.yaml

log "10) Wait for rollout..."
kubectl rollout status -n "${K8S_NAMESPACE}" deployment/"${DEPLOYMENT_NAME}" --timeout=180s
kubectl get pods -n "${K8S_NAMESPACE}" -l app="${DEPLOYMENT_NAME}"
kubectl get svc -n "${K8S_NAMESPACE}" "${SERVICE_NAME}"

# ==========================================================
# Browser visibility (NO SMOKE TEST)
# ==========================================================
PF_PID=""
if [[ "$KEEP_PORT_FORWARD" == "true" ]]; then
  log "11) Starting port-forward for browser access on 0.0.0.0:${PORT_FORWARD_LOCAL_PORT} ..."
  pkill -f "kubectl port-forward.*${PORT_FORWARD_LOCAL_PORT}:8080" >/dev/null 2>&1 || true

  nohup kubectl port-forward --address 0.0.0.0 -n "${K8S_NAMESPACE}" \
    svc/"${SERVICE_NAME}" "${PORT_FORWARD_LOCAL_PORT}:8080" \
    >/tmp/petclinic-portforward.log 2>&1 &

  PF_PID=$!
  sleep 2

  log "Port-forward started (PID=${PF_PID})."
  log "✅ Open in browser: http://<EC2_PUBLIC_IP>:${PORT_FORWARD_LOCAL_PORT}/"
  log "📌 Logs: tail -f /tmp/petclinic-portforward.log"
  log "🛑 Stop later: kill ${PF_PID}"
  log "NOTE: Security Group must allow inbound TCP ${PORT_FORWARD_LOCAL_PORT} from your IP."
fi

# ==========================================================
# Performance testing (optional) - outputs OUTSIDE repo
# ==========================================================
if [[ "$RUN_JMETER" == "true" ]]; then
  PERF_DIR="${PERF_BASE_DIR}/petclinic-perf-${TAG}"
  mkdir -p "${PERF_DIR}"

  log "12) JMeter performance test (localhost:${PORT_FORWARD_LOCAL_PORT})..."
  cat > /tmp/petclinic_load_test.jmx <<EOF_JMX
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
EOF_JMX

  jmeter -n \
    -t /tmp/petclinic_load_test.jmx \
    -l "${PERF_DIR}/results.jtl" \
    -e -o "${PERF_DIR}/html-report"

  log "JMeter report: ${PERF_DIR}/html-report/index.html"
fi

log "======================================"
log "PIPELINE COMPLETED ✅"
log "Image pushed: ${IMAGE}"
if [[ "$KEEP_PORT_FORWARD" == "true" ]]; then
  log "Browser URL: http://<EC2_PUBLIC_IP>:${PORT_FORWARD_LOCAL_PORT}/"
fi
log "======================================"
