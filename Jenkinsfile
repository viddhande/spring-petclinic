// Pipeline: Checkout -> Maven Build -> Docker Build -> Login Public ECR -> Tag -> Push
// No Kubernetes stage included yet (as requested).

pipeline {
  agent { label 'slave' }

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '10'))
  }

  environment {
    IMAGE_NAME   = "petclinic"
    IMAGE_TAG    = "${BUILD_NUMBER}"

    // Your AWS Public ECR details
    ECR_REGISTRY = "public.ecr.aws/e0f4k4s5"
    ECR_REPO     = "public.ecr.aws/e0f4k4s5/petclinic"
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
        // Build local docker image with build-number tag
        sh 'docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .'
      }
    }

    stage('Login to Public ECR') {
      steps {
        sh '''
          aws --version
          aws sts get-caller-identity

          # Public ECR login always uses us-east-1
          aws ecr-public get-login-password --region us-east-1 \
          | docker login --username AWS --password-stdin ${ECR_REGISTRY}
        '''
      }
    }

    stage('Tag & Push to Public ECR') {
      steps {
        sh '''
          # Push build-number tag
          docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${ECR_REPO}:${IMAGE_TAG}
          docker push ${ECR_REPO}:${IMAGE_TAG}

          # Also push latest tag (optional but common)
          docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${ECR_REPO}:latest
          docker push ${ECR_REPO}:latest
        '''
      }
    }
  }

  post {
    always {
      echo "Pipeline finished with status: ${currentBuild.currentResult}"
    }
  }
}
