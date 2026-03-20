// Jenkins Declarative Pipeline for Spring Petclinic
// Stages: Checkout -> Maven Build -> Docker Build
// Note: Smoke Test stage removed as requested.
// Note: Docker cleanup removed because docker permission is not yet fixed on agent.

pipeline {

  // Pipeline runs on your connected agent node
  agent { label 'slave' }

  options {
    // Adds timestamps in console logs
    timestamps()

    // Keeps last 10 builds only
    buildDiscarder(logRotator(numToKeepStr: '10'))
  }

  environment {
    IMAGE_NAME = "petclinic"
  }

  stages {

    stage('Checkout') {
      steps {
        // Pull latest code from GitHub
        checkout scm

        // Show workspace files
        sh 'ls -la'
      }
    }

    stage('Build (Maven)') {
      steps {
        // Verify tools
        sh 'java -version'
        sh 'mvn -v'

        // Build application (jar/war goes to target/)
        sh 'mvn clean package -DskipTests'
      }
      post {
        success {
          // Store artifacts in Jenkins
          archiveArtifacts artifacts: 'target/*.jar,target/*.war', fingerprint: true, allowEmptyArchive: true
        }
      }
    }

    stage('Docker Build') {
      steps {
        // Verify docker exists
        sh 'docker --version'

        // Build docker image from Dockerfile in repo root
        sh 'docker build -t petclinic:${BUILD_NUMBER} .'
      }
    }
  }

  post {
    always {
      echo "Pipeline finished with status: ${currentBuild.currentResult}"
    }
  }
}
