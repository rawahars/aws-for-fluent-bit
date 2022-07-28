# Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You
# may not use this file except in compliance with the License. A copy of
# the License is located at
#
# 	http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF
# ANY KIND, either express or implied. See the License for the specific
# language governing permissions and limitations under the License.

Param(
[Parameter(Mandatory=$false)]
[ValidateSet("cicd","cloudwatch","cloudwatch_logs","clean-cloudwatch","kinesis","kinesis_streams","firehose","kinesis_firehose","s3","clean-s3","delete")]
[string]$TestPlugin = "cicd"
)

$ErrorActionPreference = 'Stop'

$IntegTestRoot = "${PSScriptRoot}"
$env:AWS_REGION = "us-west-2"
$env:PROJECT_ROOT = Resolve-Path -Path "${PSScriptRoot}\.."

Function Install-Package {
    # Install docker-compose on the instance
    # Use installation instructions from "https://docs.docker.com/compose/install/compose-plugin/#install-compose-on-windows-server"
    if (-Not (Test-Path -Path "$Env:ProgramFiles\Docker\docker-compose.exe" -PathType Leaf))
    {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest "https://github.com/docker/compose/releases/download/v2.7.0/docker-compose-Windows-x86_64.exe" -UseBasicParsing -OutFile $Env:ProgramFiles\Docker\docker-compose.exe
    }
    Write-Host $( docker-compose version )
}

Function Test-Command {
    Param (
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$TestMethod
    )

    if ($LASTEXITCODE)
    {
        throw ("Integration tests failed for Windows during {0}" -f $TestMethod)
    }
}

Function Run-Test {
    Param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$PluginUnderTest,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$DockerComposeTestFilePath,

        [Parameter(Mandatory=$false)]
        [switch]$Background,

        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]$SleepTime=120
    )
    # Generates log data which will be stored on the s3 bucket
    docker-compose --file $DockerComposeTestFilePath build
    Test-Command -TestMethod "$($MyInvocation.MyCommand): ${PluginUnderTest}"
    if (-Not $Background)
    {
        docker-compose --file $DockerComposeTestFilePath up --abort-on-container-exit
    } else {
        docker-compose --file $DockerComposeTestFilePath up -d
    }
    Test-Command -TestMethod "$($MyInvocation.MyCommand): ${PluginUnderTest}"

    # Giving a pause before running the validation test
    Start-Sleep -Seconds $SleepTime
}

Function Validate-Test {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$PluginUnderTest,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$DockerComposeValidateFilePath,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ValidationFileName
    )
    # Creates a file as a flag for the validation failure
    New-Item -Path "${IntegTestRoot}\out\${ValidationFileName}" -ItemType File -Force

    docker-compose --file $DockerComposeValidateFilePath build
    Test-Command -TestMethod "$($MyInvocation.MyCommand): ${PluginUnderTest}"
    docker-compose --file $DockerComposeValidateFilePath up --abort-on-container-exit
    Test-Command -TestMethod "$($MyInvocation.MyCommand): ${PluginUnderTest}"

    if (Test-Path -Path "${IntegTestRoot}\out\${ValidationFileName}" -PathType Leaf) {
        throw "Test failed for ${PluginUnderTest}."
    }
    Write-Host "Validation succeeded for ${PluginUnderTest}"
}

Function Clean-Test {
    Param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$PluginUnderTest,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$DockerComposeFilePath
    )
    docker-compose --file $DockerComposeFilePath down -v --rmi all --remove-orphans
    Test-Command -TestMethod "$($MyInvocation.MyCommand): ${PluginUnderTest}"
}

Function Test-CloudWatch {
    $env:LOG_GROUP_NAME="fluent-bit-integ-test-amd64"
    $env:TAG=-join ((65..90) + (97..122) | Get-Random -Count 10 | % {[char]$_})
    $env:VOLUME_MOUNT_CONTAINER="C:/out"
    $env:AWS_FOR_FLUENT_BIT_CONTAINER_NAME="aws-for-fluent-bit-$($env:TAG)"
    $DockerComposeFluentBitProjectBuildPath = "${IntegTestRoot}/test_cloudwatch/docker-compose.fluent-bit.windows.yml"
    $DockerComposeTestFilePath = "${IntegTestRoot}/test_cloudwatch/docker-compose.windows.test.yml"
    $DockerComposeValidateFilePath = "${IntegTestRoot}/test_cloudwatch/docker-compose.validate.yml"

    # Run docker compose for running the fluent-bit container
    Run-Test -PluginUnderTest "Cloudwatch" -DockerComposeTestFilePath $DockerComposeFluentBitProjectBuildPath -Background
    # Find and set the fluent-bit container IP so that other containers can bind to the socket.
    $env:FLUENT_CONTAINER_IP =  ((docker inspect --format='{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' $env:AWS_FOR_FLUENT_BIT_CONTAINER_NAME).Trim())[0]
    if ($env:FLUENT_CONTAINER_IP -eq "") {
        throw "Empty IP Address for the fluent-bit container"
    }

    Run-Test -PluginUnderTest "Cloudwatch" -DockerComposeTestFilePath $DockerComposeTestFilePath
    # Once the tests are completed, then perform docker-compose down
    Clean-Test -PluginUnderTest "Cloudwatch" -DockerComposeFilePath $DockerComposeTestFilePath
    Clean-Test -PluginUnderTest "Cloudwatch" -DockerComposeFilePath $DockerComposeFluentBitProjectBuildPath

    # Perform validation of the tests
    Validate-Test -PluginUnderTest "Cloudwatch" -DockerComposeValidateFilePath $DockerComposeValidateFilePath -ValidationFileName "cloudwatch-test"
    Clean-Test -PluginUnderTest "Cloudwatch" -DockerComposeFilePath $DockerComposeValidateFilePath
}

Function Clean-CloudWatch {
    $env:LOG_GROUP_NAME="fluent-bit-integ-test-amd64"
    $DockerComposeTestFilePath = "${IntegTestRoot}/test_cloudwatch/docker-compose.clean.yml"

    Run-Test -PluginUnderTest "Cloudwatch" -DockerComposeTestFilePath $DockerComposeTestFilePath -SleepTime 1
    Clean-Test -PluginUnderTest "Cloudwatch" -DockerComposeFilePath $DockerComposeTestFilePath
}

Function Test-Kinesis {
    $DockerComposeTestFilePath = "${IntegTestRoot}/test_kinesis/windows/docker-compose.windows.test.yml"
    $DockerComposeValidateFilePath = "${IntegTestRoot}/test_kinesis/windows/docker-compose.windows.validate-and-clean-s3.yml"
    $env:S3_ACTION="validate"

    Run-Test -PluginUnderTest "kinesis stream" -DockerComposeTestFilePath $DockerComposeTestFilePath
    Validate-Test -PluginUnderTest "kinesis stream" -DockerComposeValidateFilePath $DockerComposeValidateFilePath -ValidationFileName "kinesis-test"
}

Function Test-KinesisStreams {
    $DockerComposeTestFilePath = "${IntegTestRoot}/test_kinesis/windows/docker-compose.core.windows.test.yml"
    $DockerComposeValidateFilePath = "${IntegTestRoot}/test_kinesis/windows/docker-compose.windows.validate-and-clean-s3.yml"
    $env:S3_ACTION="validate"

    Run-Test -PluginUnderTest "kinesis stream" -DockerComposeTestFilePath $DockerComposeTestFilePath
    Validate-Test -PluginUnderTest "kinesis stream" -DockerComposeValidateFilePath $DockerComposeValidateFilePath -ValidationFileName "kinesis-test"
}

Function Test-Firehose {
    $DockerComposeTestFilePath = "${IntegTestRoot}/test_firehose/windows/docker-compose.windows.test.yml"
    $DockerComposeValidateFilePath = "${IntegTestRoot}/test_kinesis/windows/docker-compose.windows.validate-and-clean-s3.yml"
    $env:S3_ACTION="validate"

    Run-Test -PluginUnderTest "firehose" -DockerComposeTestFilePath $DockerComposeTestFilePath
    Validate-Test -PluginUnderTest "firehose" -DockerComposeValidateFilePath $DockerComposeValidateFilePath -ValidationFileName "firehose-test"
}

Function Test-KinesisFirehose {
    $DockerComposeTestFilePath = "${IntegTestRoot}/test_firehose/windows/docker-compose.core.windows.test.yml"
    $DockerComposeValidateFilePath = "${IntegTestRoot}/test_kinesis/windows/docker-compose.windows.validate-and-clean-s3.yml"
    $env:S3_ACTION="validate"

    Run-Test -PluginUnderTest "firehose" -DockerComposeTestFilePath $DockerComposeTestFilePath
    Validate-Test -PluginUnderTest "firehose" -DockerComposeValidateFilePath $DockerComposeValidateFilePath -ValidationFileName "firehose-test"
}

Function Test-S3 {
    # different S3 prefix for each test
    $env:ARCHITECTURE= "x86-64"
    $env:S3_PREFIX_PUT_OBJECT="logs/${env:ARCHITECTURE}/putobject"
    $env:S3_PREFIX_MULTIPART="logs/${env:ARCHITECTURE}/multipart"
    # Tag is used in the s3 keys; each test run has a unique (random) tag
    $env:TAG=-join ((65..90) + (97..122) | Get-Random -Count 10 | % {[char]$_})
    $env:S3_ACTION="validate"
    $DockerComposeTestFilePath = "${IntegTestRoot}/test_s3/windows/docker-compose.windows.test.yml"
    $DockerComposeValidateFilePath = "${IntegTestRoot}/test_s3/windows/docker-compose.windows.validate-s3-multipart.yml"

    Run-Test -PluginUnderTest "S3" -DockerComposeTestFilePath $DockerComposeTestFilePath -SleepTime 20
    Validate-Test -PluginUnderTest "S3" -DockerComposeValidateFilePath $DockerComposeValidateFilePath -ValidationFileName "s3-test"

    $DockerComposeValidateFilePath = "${IntegTestRoot}/test_s3/windows/docker-compose.windows.validate-s3-putobject.yml"
    Validate-Test -PluginUnderTest "S3" -DockerComposeValidateFilePath $DockerComposeValidateFilePath -ValidationFileName "s3-test"
}

Function Clean-S3 {
    $env:S3_ACTION="clean"
    $DockerComposeTestFilePath = "${IntegTestRoot}/test_kinesis/windows/docker-compose.windows.validate-and-clean-s3.yml"

    Run-Test -PluginUnderTest "Clean-S3" -DockerComposeTestFilePath $DockerComposeTestFilePath -SleepTime 1
}

# Install the required packages
Install-Package

switch ($TestPlugin) {
    "cloudwatch" {
        $env:CW_PLUGIN_UNDER_TEST="cloudwatch"
        Test-CloudWatch
        Clean-CloudWatch
    }

    "cloudwatch_logs" {
        $env:CW_PLUGIN_UNDER_TEST="cloudwatch_logs"
        Test-CloudWatch
        Clean-CloudWatch
    }

    "clean-cloudwatch" {
        Clean-CloudWatch
    }

    "kinesis" {
        $env:S3_PREFIX="kinesis-test"
        $env:TEST_FILE="kinesis-test"
        $env:EXPECTED_EVENTS_LEN="1000"

        # Create and setup test environment.
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Create"
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Setup"

        Clean-S3
        Test-Kinesis
    }

    "kinesis_streams" {
        $env:S3_PREFIX="kinesis-test"
        $env:TEST_FILE="kinesis-test"
        $env:EXPECTED_EVENTS_LEN="1000"

        # Create and setup test environment.
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Create"
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Setup"

        Clean-S3
        Test-KinesisStreams
    }

    "firehose" {
        $env:S3_PREFIX="firehose-test"
        $env:TEST_FILE="firehose-test"
        $env:EXPECTED_EVENTS_LEN="1000"

        # Create and setup test environment.
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Create"
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Setup"

        Clean-S3
        Test-Firehose
    }

    "kinesis_firehose" {
        $env:S3_PREFIX="firehose-test"
        $env:TEST_FILE="firehose-test"
        $env:EXPECTED_EVENTS_LEN="1000"

        # Create and setup test environment.
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Create"
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Setup"

        Clean-S3
        Test-KinesisFirehose
    }

    "s3" {
        $env:S3_PREFIX="logs"
        $env:TEST_FILE="s3-test"
        $env:EXPECTED_EVENTS_LEN="7717"

        # Create and setup test environment.
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Create"
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Setup"

        Clean-S3
        Test-S3
    }

    "clean-s3" {
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Setup"
        Clean-S3
    }

    "cicd" {
        $env:CW_PLUGIN_UNDER_TEST="cloudwatch"
        Write-Host "Running tests on Golang CW Plugin"
        Test-CloudWatch
        Clean-CloudWatch

        $env:CW_PLUGIN_UNDER_TEST="cloudwatch_logs"
        Write-Host "Running tests on Core C CW Plugin"
        Test-CloudWatch
        Clean-CloudWatch

        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Create"
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Setup"

        $env:S3_PREFIX="kinesis-test"
        $env:TEST_FILE="kinesis-test"
        $env:EXPECTED_EVENTS_LEN="1000"
        Clean-S3
        Test-Kinesis

        $env:S3_PREFIX="kinesis-test"
        $env:TEST_FILE="kinesis-test"
        $env:EXPECTED_EVENTS_LEN="1000"
        Clean-S3
        Test-KinesisStreams

        $env:S3_PREFIX="firehose-test"
        $env:TEST_FILE="firehose-test"
        $env:EXPECTED_EVENTS_LEN="1000"
        Clean-S3
        Test-Firehose

        $env:S3_PREFIX="firehose-test"
        $env:TEST_FILE="firehose-test"
        $env:EXPECTED_EVENTS_LEN="1000"
        Clean-S3
        Test-KinesisFirehose

        $env:S3_PREFIX="logs"
        $env:TEST_FILE="s3-test"
        $env:EXPECTED_EVENTS_LEN="7717"
        Clean-S3
        Test-S3
    }

    "delete" {
        Invoke-Expression "$IntegTestRoot\resources\manage_test_resources.ps1 -Action Delete"
    }
}
