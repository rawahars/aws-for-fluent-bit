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
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

$ResourcesRoot = "${PSScriptRoot}"
$Region = "us-west-2"
$Architecture = "x86-64"
$StackName = "integ-test-fluent-bit-${Architecture}"

Function Create-TestResources {
    $template = Get-Content -Path "${ResourcesRoot}\resources\cfn-kinesis-s3-firehose.yml" -Raw
    trap {
        try
        {
            New-CFNStack -Region $Region -StackName $StackName -Capability CAPABILITY_NAMED_IAM -TemplateBody $template
        } catch {
            if ($_.Exception.Message -NotMatch "already exists") {
                throw $_
            }
            Write-Host "The stack already exists!"
        }
        continue
    }
    Get-CFNStack -Region $Region -StackName $StackName
}

Function Setup-TestResources {
    # If the stack does not exist, then we will error out here itself.
    Get-CFNStack -Region $Region -StackName $StackName
    # The logical names are as per cfn-kinesis-s3-firehose.yml
    $env:FIREHOSE_STREAM = (Get-CFNStackResourceList -StackName $StackName -LogicalResourceId "firehoseDeliveryStreamForFirehoseTest").PhysicalResourceId
    $env:KINESIS_STREAM = (Get-CFNStackResourceList -StackName $StackName -LogicalResourceId "kinesisStream").PhysicalResourceId
    $env:S3_BUCKET_NAME = (Get-CFNStackResourceList -StackName $StackName -LogicalResourceId "s3Bucket").PhysicalResourceId
}

Function Remove-TestResources {
    Remove-CFNStack -Region $Region -StackName $StackName
}

switch ($Action) {
    "Create" {
        Create-TestResources
    }

    "Setup" {
        Setup-TestResources
    }

    "Delete" {
        Remove-TestResources
    }
}
