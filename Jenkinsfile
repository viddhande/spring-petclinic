pipeline {
  agent { label 'slave' }

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '10'))
  }

  environment {
    // Public ECR
    ECR_REGISTRY = "public.ecr.aws/e0f4k4s5"
    ECR_REPO     = "public.ecr.aws/e0f4k4s5/petclinic"
    IMAGE_NAME   = "petclinic"
    IMAGE_TAG    = "${BUILD_NUMBER}"

    // Kubernetes
    KUBECONFIG_PATH = "/home/jenkins/.kube/config"
    K8S_NAMESPACE   = "petclinic"
    EKS_CONTEXT     = "arn:aws:eks:ap-south-1:013461378686:cluster/petclinic-eks"
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Build (Maven)') {
      steps {
        sh '''
          java -version
          mvn -v
          mvn clean package -DskipTests
        '''
      }
      post {
        success {
          archiveArtifacts artifacts: 'target/*.jar', fingerprint: true
        }
      }
    }

    // ✅ ✅ SONARQUBE SCAN (GUARANTEED FIX)
    stage('SonarQube Scan') {
      steps {
        withCredentials([string(credentialsId: 'SONAR_TOKEN', variable: 'SONAR_TOKEN')]) {
          withEnv(['SONAR_HOST_URL=http://13.203.195.66:9000']) {
            sh '''
              echo "Using SonarQube URL: $SONAR_HOST_URL"

              mvn sonar:sonar \
                -Dsonar.host.url=$SONAR_HOST_URL \
                -Dsonar.login=${SONAR_TOKEN} \
                -Dsonar.projectKey=petclinic
            '''
          }
        }
      }
    }

    stage('Docker Build') {
      steps {
        sh '''
          docker --version
          docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .
        '''
      }
    }

    stage('Push to Public ECR') {
      steps {
        sh '''
          aws --version
          aws sts get-caller-identity

          aws ecr-public get-login-password --region us-east-1 \
          | docker login --username AWS --password-stdin ${ECR_REGISTRY}

          docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${ECR_REPO}:${IMAGE_TAG}
          docker push ${ECR_REPO}:${IMAGE_TAG}

          docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${ECR_REPO}:latest
          docker push ${ECR_REPO}:latest
        '''
      }
    }

    stage('Deploy to EKS') {
      steps {
        sh '''
          export KUBECONFIG=${KUBECONFIG_PATH}
          export PATH=/usr/local/bin:$PATH

          kubectl config use-context ${EKS_CONTEXT}
          kubectl create namespace ${K8S_NAMESPACE} || true

          sed -i "s|REPLACE_IMAGE|${ECR_REPO}:${IMAGE_TAG}|g" k8s/deployment.yaml

          kubectl apply -f k8s/deployment.yaml
          kubectl apply -f k8s/service.yaml

          kubectl rollout status deployment/petclinic -n ${K8S_NAMESPACE}
        '''
      }
    }

    stage('Verify Deployment') {
      steps {
        sh '''
          export KUBECONFIG=${KUBECONFIG_PATH}
          kubectl get pods -n ${K8S_NAMESPACE}
          kubectl get svc  -n ${K8S_NAMESPACE}
        '''
      }
    }
  }

  post {
    success {
      echo "✅ CI/CD SUCCESS: Build, SonarQube analysis, push, and deployment completed"
    }
    failure {
      echo "❌ Pipeline failed – check logs above"
    }
  }
}
