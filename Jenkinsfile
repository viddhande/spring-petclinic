// Jenkins Declarative Pipeline for Spring Petclinic
// Stages included: Checkout -> Maven Build -> Docker Build -> Docker Smoke Test -> Archive
// Note: No Push-to-ECR stage included (as per your requirement).

pipeline {

  // Run the whole pipeline on the Jenkins agent node that has label 'slave'
  agent { label 'slave' }

  // Optional pipeline settings
  options {
    // Adds timestamps in console logs (helps debugging)
    timestamps()

    // Keeps only last 10 builds to save Jenkins storage
    buildDiscarder(logRotator(numToKeepStr: '10'))
  }

  // Environment variables used in pipeline
  environment {
    IMAGE_NAME = "petclinic"
  }

  stages {

    stage('Checkout') {
      steps {
        // Pulls the repo code from GitHub
        checkout scm

        // Shows files in workspace to confirm checkout is correct
        sh 'ls -la'
      }
    }

    stage('Build (Maven)') {
      steps {
        // Prints versions to confirm tools are available on agent
        sh 'java -version'
        sh 'mvn -v'

        // Builds the application and generates jar/war inside target/
        sh 'mvn clean package -DskipTests'
      }
      post {
        success {
          // Stores jar/war as Jenkins build artifacts for download
          archiveArtifacts artifacts: 'target/*.jar,target/*.war', fingerprint: true, allowEmptyArchive: true
        }
      }
    }

    stage('Docker Build') {
      steps {
        // Confirms Docker exists on agent
        sh 'docker --version'

        // Builds docker image using Dockerfile in repo root
        sh 'docker build -t petclinic:${BUILD_NUMBER} .'

        // Shows top images for confirmation
        sh 'docker images | head -n 20'
      }
    }

    stage('Docker Run (Smoke Test)') {
      steps {
        /*
          This stage is a basic verification:
          - Run the built image locally on the agent
          - Hit the localhost endpoint
          - If it fails, print container logs and fail the build
          - Cleanup container after test
        */
        sh '''
          docker rm -f petclinic-test || true

          docker run -d --name petclinic-test -p 8080:8080 petclinic:${BUILD_NUMBER}

          // Wait for app to start
          sleep 15

          // Test the app endpoint
          curl -I http://localhost:8080 || (docker logs petclinic-test && exit 1)

          // Cleanup
          docker rm -f petclinic-test
        '''
      }
    }
  }

  post {
    always {
      // Always prints final result at end
      echo "Pipeline finished with status: ${currentBuild.currentResult}"

      // Optional cleanup: remove image to save disk on agent
      sh 'docker image rm -f petclinic:${BUILD_NUMBER} || true'
    }
  }
}
