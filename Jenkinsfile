pipeline {
  agent { label 'slave' }

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '10'))
  }

  environment {
    // ECR image details
    ECR_REPO = "public.ecr.aws/e0f4k4s5/petclinic"
    IMAGE_TAG = "latest"

    // Kubernetes
    K8S_NAMESPACE = "petclinic"
  }

  stages {

    stage('Checkout Code') {
      steps {
        checkout scm
      }
    }

    stage('Verify Kubernetes Access') {
      steps {
        sh '''
          kubectl version --client
          kubectl get nodes
        '''
      }
    }

    stage('Deploy to EKS') {
      steps {
        sh '''
          kubectl create namespace ${K8S_NAMESPACE} || true

          kubectl apply -f k8s/deployment.yaml
          kubectl apply -f k8s/service.yaml

          kubectl rollout status deployment/petclinic -n ${K8S_NAMESPACE}
        '''
      }
    }

    stage('Verify Deployment') {
      steps {
        sh '''
          kubectl get pods -n ${K8S_NAMESPACE}
          kubectl get svc -n ${K8S_NAMESPACE}
        '''
      }
    }
  }

  post {
    success {
      echo "✅ Deployment to EKS successful"
    }
    failure {
      echo "❌ Deployment failed"
    }
  }
}
