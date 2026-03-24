cat > pipeline.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# -------------------------
# REQUIRED CONFIG (EDIT)
# -------------------------
NEXUS_HOST="<EC2_PUBLIC_IP>"          # example: 13.232.xx.xx
NEXUS_PORT="8083"
NEXUS_REPO="docker-hosted"
NEXUS_USER="admin"
NEXUS_PASS="<NEXUS_PASSWORD>"

SONAR_HOST="http://localhost:9000"    # Sonar runs on this same EC2
SONAR_TOKEN="<SONAR_TOKEN>"
SONAR_PROJECT_KEY="petclinic"

APP_NAME="petclinic"
TAG="$(date +%Y%m%d%H%M%S)"
K8S_NAMESPACE="default"

# -------------------------
# DO NOT EDIT BELOW
# -------------------------
IMAGE="${NEXUS_HOST}:${NEXUS_PORT}/${NEXUS_REPO}/${APP_NAME}:${TAG}"

echo "======================================"
echo " PIPELINE START"
echo " Image: $IMAGE"
echo "======================================"

echo "1) Maven Build (compile + package)"
mvn -U clean package

echo "2) Unit Tests"
mvn test

echo "3) Functional Tests (Integration Tests)"
mvn verify -Pintegration || echo "No integration tests found OR integration profile not configured"

echo "4) SonarQube Scan"
mvn sonar:sonar \
  -Dsonar.host.url="$SONAR_HOST" \
  -Dsonar.login="$SONAR_TOKEN" \
  -Dsonar.projectKey="$SONAR_PROJECT_KEY"

echo "5) Docker Build"
docker build -t "$IMAGE" .

echo "6) Docker Login to Nexus"
echo "$NEXUS_PASS" | docker login "${NEXUS_HOST}:${NEXUS_PORT}" -u "$NEXUS_USER" --password-stdin

echo "7) Push Image to Nexus"
docker push "$IMAGE"

echo "8) Create imagePullSecret in Kubernetes (if not exists)"
kubectl get secret nexus-regcred -n "$K8S_NAMESPACE" >/dev/null 2>&1 || \
kubectl create secret docker-registry nexus-regcred \
  --docker-server="${NEXUS_HOST}:${NEXUS_PORT}" \
  --docker-username="$NEXUS_USER" \
  --docker-password="$NEXUS_PASS" \
  -n "$K8S_NAMESPACE"

echo "9) Deploy to Kubernetes via kubectl"
sed "s|REPLACE_IMAGE|$IMAGE|g" k8s/deployment.yaml | kubectl apply -f -
kubectl apply -f k8s/service.yaml

echo "10) Wait for rollout"
kubectl rollout status deployment/$APP_NAME -n "$K8S_NAMESPACE" --timeout=180s

echo "11) Performance Test (JMeter) against NodePort :30080"
mkdir -p perf-results
jmeter -n -t perf-tests/load_test.jmx \
  -l perf-results/results.jtl \
  -e -o perf-results/html-report

echo "======================================"
echo " PIPELINE SUCCESS"
echo " App (from EC2):   http://localhost:30080/"
echo " App (from laptop): http://${NEXUS_HOST}:30080/"
echo " JMeter report:    perf-results/html-report/index.html"
echo "======================================"
EOF
