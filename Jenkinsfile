pipeline {
  agent { label 'slave' }

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '10'))
  }

  environment {
    // Public ECR details
    ECR_REGISTRY = "public.ecr.aws/e0f4k4s5"
    ECR_REPO     = "public.ecr.aws/e0f4k4s5/petclinic"

    IMAGE_NAME   = "petclinic"
    IMAGE_TAG    = "${BUILD_NUMBER}"

    // Kubernetes details
    KUBECONFIG   = "/home/jenkins/.kube/config"
    K8S_NS       = "petclinic"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Build (Maven)') {
      steps {
        sh 'java -version'
        sh 'mvn -v'
        sh 'mvn clean package -DskipTests'
      }
      post {
        success {
          archiveArtifacts artifacts: 'target/*.jar,target/*.war', fingerprint: true, allowEmptyArchive: true
        }
      }
    }

    stage('Docker Build') {
      steps {
        sh 'docker --version'
        sh 'docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .'
      }
    }

    stage('Push to Public ECR') {
      steps {
        sh '''
          aws --version
          aws sts get-caller-identity

          # Public ECR login always uses us-east-1
          aws ecr-public get-login-password --region us-east-1 \
          | docker login --username AWS --password-stdin ${ECR_REGISTRY}

          # Push build-number tag
          docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${ECR_REPO}:${IMAGE_TAG}
          docker push ${ECR_REPO}:${IMAGE_TAG}

          # Push latest tag
          docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${ECR_REPO}:latest
          docker push ${ECR_REPO}:latest
        '''
      }
    }

    stage('Deploy to EKS') {
      steps {
        sh '''
          echo "Using KUBECONFIG=$KUBECONFIG"
          kubectl get nodes

          kubectl create namespace ${K8S_NS} || true

          # Inject the exact pushed image into deployment.yaml
          sed -i "s|REPLACE_IMAGE|${ECR_REPO}:${IMAGE_TAG}|g" k8s/deployment.yaml

          kubectl apply -f k8s/deployment.yaml
          kubectl apply -f k8s/service.yaml

          kubectl rollout status -n ${K8S_NS} deployment/petclinic
          kubectl get pods -n ${K8S_NS}
          kubectl get svc -n ${K8S_NS} petclinic-svc
        '''
      }
    }
  }

  post {
    success {
      echo "✅ Pipeline completed: Image pushed to Public ECR and deployed to EKS"
    }
    failure {
      echo "❌ Pipeline failed. Check the stage logs above."
    }
  }
}
