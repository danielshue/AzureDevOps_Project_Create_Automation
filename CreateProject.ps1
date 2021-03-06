#
# Usage: CreateProject.ps1 {ProjectName} {ProjectDescription}
#
# This repository contains sample project demonstrating how to implement automated 
# creation of a Team Project in an existing Azure DevOps Organization. Additionally the 
# project will initiallize a default repo, apply a branch policy on the master branch, 
# add the project admininstrators as the auto populated approvers on a pull request. 
# Finally we add a group rule on the organization to map an AAD group to the project and role.

# Change the variable below to match the Azure DevOps Organization Name for example:
# https://dev.azure.com/{OrganizationName}/ or https://{OrganizationName}.visualstudio.com/
$DevOpsOrganization = "danshue"

# Change the variable to match the Active Directory Group Name where the new roles will be created.
$adgroupname = "ou=CICD DevOps,ou=Security Groups,dc=corp,dc=microsoft,dc=com"

# Change the varilable below where the Actuve Directory COnnection Server is located
$ADConnectServer = "dirsync101.corp.microsoft.com"

# Change the varilable below for the personal access token for executing the script
# See https://docs.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate
$pat = '{your PAT token here}'

function New-DevopsProject {
  [cmdletbinding()]
  param(
    [parameter(Mandatory = $true)]
    [Alias('Name')]
    [string] $ProjectName,
    [string] $Description
  )

  # Create initial groups and sync to AAD.  These groups will be used to map users to the project with correct permissions.  Project Admins are the only group allowed to approve PR to merge to master.
  Import-Module ActiveDirectory

  # Name of the Groups
  $projectadmins = "$projectname - DevOps - Project Administrators"
  $buildadmins = "$projectname - DevOps - Build Administrators"
  $Validusers = "$projectname - DevOps - Valid Users"
  $Contributors = "$projectname - DevOps - Project Contributors"
  $readers = "$projectname - DevOps - Project Readers"
  $Releaseadmins = "$projectname - DevOps - Release Administrators"
  
  # Create necessary groups in AD, which is also used for entitlements
  $GroupTypes = "Project Administrators", "Build Administrators", "Valid Users", "Contributors", "Readers", "Release Administrators"
  
  New-ADGroup -Name "$projectadmins" -GroupCategory Security -GroupScope Universal -path $adgroupname
  new-adgroup -name "$buildadmins" -GroupCategory Security -GroupScope Universal -path $adgroupname
  New-ADGroup -Name "$Validusers" -GroupCategory Security -GroupScope Universal -path $adgroupname
  New-ADGroup -Name "$Contributors" -GroupCategory Security -GroupScope Universal -path $adgroupname
  New-ADGroup -Name "$readers" -GroupCategory Security -GroupScope Universal -path $adgroupname
  New-ADGroup -Name "$Releaseadmins" -GroupCategory Security -GroupScope Universal -path $adgroupname

  # Need to allow 20 seconds for group creation to complete.
  Start-Sleep -Seconds 20 
  $GroupsCreate = ("$projectadmins", "$buildadmins", "$Validusers", "$Contributors", "$readers", "$Releaseadmins")
  $groupscreated = foreach ($group in $GroupsCreate) { Get-ADGroup -identity $group }

  #force Dirsync and confirm Groups are created in AzureAD
  $ADSyncSplat = @{
    ComputerName = $ADConnectServer
  }

  #if a credential is needed you'll have to fill in $ADCred
  if ($ADCred) {
    $ADSyncSplat.Add("Credential", $ADCred)
  }

  # The sync can take some time and vary greatly up to 2 minutes.
  Invoke-Command @ADSyncSplat -ScriptBlock {

    Import-Module ADSync
    $null = Start-ADSyncSyncCycle -PolicyType Delta

    $runtime = 0
       
    do {
       
      Write-Verbose "AD sync is running, current run time: $runtime seconds" -Verbose
      Start-Sleep -Seconds 1
      $runtime = $runtime + 1
    }
       
    while ((Get-ADSyncScheduler | Select-Object -ExpandProperty SyncCycleInProgress) -eq "True")
    
    Write-Verbose "AD sync completed." -Verbose
  
  }


  # Check for new groups in Azure AD
  Connect-AzAccount -Credential (get-credential)
  
  ForEach ($Group in $GroupsCreated) {
    $Retry = 0
    Do {
      $Group.AzureGroupId = Get-AzADGroup -SearchString $Group.name -ErrorAction Stop | Select-Object -ExpandProperty Id
      If (-not $Group.AzureGroupID) {
        $Retry ++
        Write-Verbose "Unable to locate ""$($Group.name)"" in Azure AD for the $($Tenant.TenantName) tenant, waiting 60 seconds and try again.  Retry: $Retry"
        Start-Sleep -Seconds 60
      }
    } Until ($Group.AzureGroupId)
  }

  # DevOps API calls for generating project and applying groups
  # in this example the PAT token is in the script. This not secure.  
  # Normally the token would be stored in a secret store like Azure 
  # Keyvault and pulled in dynamically.
  $token = [system.convert]::ToBase64String([system.text.encoding]::ASCII.GetBytes(":$($pat)"))
  $header = @{
    authorization = "Basic $token"
  }

  $uri = "https://dev.azure.com/$DevOpsOrganization/_apis/projects?api-version=5.1"
  $projecturi = "https://dev.azure.com/$DevOpsOrganization/$projectname/_apis/git/repositories/$ProjectName/importRequests?api-version=5.1-preview"
  $projectrepouri = "https://dev.azure.com/$DevOpsOrganization/$projectname/_apis/git/repositories?api-version=6.0-preview.1"
  $repopolicyconfig = "https://dev.azure.com/$DevOpsOrganization/$projectname/_apis/policy/configurations?api-version=5.0"

  # Create Project in Azure DevOps
  #
  #    The templateTypeId in this case maps to Scrum you can only create a project with default templates:
  # 
  #    Agile templateTypeID is adcc42ab-9882-485e-a3ed-7678f01f66bc
  #    Scrum templateTypeID is 6b724908-ef14-45cf-84f8-768b5384da45
  #    Basic (a stripped down scrum template)  b8a3a935-7e91-48b8-a94c-606d37c3e9f2
  #    CMMI is 27450541-8e31-4150-9947-dc59f998fc01
  #
  # If you have an inherited process template you can query the type and apply the inherited template

  write-verbose "Creating Project in Azure DevOps"

  $Projectbody = '{
    "name": "' + $ProjectName + '", 
    "description": "' + $Description + '", 
    "capabilities": {
        "versioncontrol": { 
            "sourceControlType": "Git"}, 
        "processTemplate":{
            "templateTypeId": "6b724908-ef14-45cf-84f8-768b5384da45"}
        }
    }'

  $createproject = Invoke-RestMethod -Uri $uri -Headers $header -method post -Body $projectbody -ContentType application/json 
  Start-Sleep -Seconds 5

  Write-Verbose "Creating null repo..."
  # create null repo
  # we are actually just cloning an empty repo from a public github repo.  you could point to any repo to act as a template with a readme file,etc.
  $Repobody = '{
    "parameters": {
        "gitSource": {
            "url": "https://github.com/davis61513/nullrepo.git"}
        }
    }'

  $createnullrepo = Invoke-RestMethod -uri $projecturi -Headers $header -Method post -body $Repobody -ContentType application/json
  Start-Sleep -Seconds 5

  # get repo id- we need the repo ID to add the branch policy later
  Write-Verbose "Getting REPO ID..."
  $repoid = invoke-restmethod -uri $projectrepouri -Headers $header 
  [string]$realid = $repoid.value.id

  #set approval policy -first we set the minimum approvers and that approvers cannot approve their own pull request.
  Write-Verbose "Setting Approval policies on Repository..."

  $policybody = '{
  "isEnabled": true,
  "isBlocking": false,
  "type": {
    "id": "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"
  },
  "settings": {
    "minimumApproverCount": 1,
    "creatorVoteCounts": false,
    "scope": [
      {
        "repositoryId": "' + $realid + '",
        "refName": "refs/heads/master",
        "matchKind": "exact"
      }
    ]
  }
}'

  # we are now adding the required reviewers ID.  Note that the id under type must match the policy block.  In this case the id matches addinga reviewer ID
  # You cannot directly add an AAD identity here so instead we are using the pre-defined project admin group ID (4a7f3061-9af2-4f2d-a31c-8d24b8c3abb7)
  
  $setpolicy = Invoke-RestMethod -uri $repopolicyconfig -Headers $header -Method Post -Body $policybody -ContentType application/json
  Start-Sleep -Seconds 5

  $approverguid = Get-AzADGroup -DisplayName $projectadmins
  [string]$appguid = $approverguid.id

  $approversbody = '{
  "isEnabled": true,
  "isBlocking": true,
  "type": {
    "id": "fd2167ab-b0be-447a-8ec8-39368250530e"
  },
  "settings": {
    "requiredReviewerIds": [
      "4a7f3061-9af2-4f2d-a31c-8d24b8c3abb7"
    ],
    "addedFilesOnly": false,
   "scope": [
      {
        "repositoryId": "' + $realid + '",
        "refName": "refs/heads/master",
        "matchKind": "exact"
      },
      {
        "repositoryId": "' + $realid + '",
        "refName": "refs/heads/releases/",
        "matchKind": "prefix"
      }
    ]
  }
}'
  #Write-Verbose "Setting approvers..."
  #$setapprovers = Invoke-RestMethod -uri $repopolicyconfig -Headers $header -Method Post -Body $approversbody -ContentType application/json
  #all after this may break function beaware!!!
  #goal here is to add an entitlement for a AAD group to a project
  $entitlementURI = "https://vsaex.dev.azure.com/$DevOpsOrganization/_apis/groupentitlements?api-version=5.1-preview.1"
  $groups2map = ("$projectadmins", "$Contributors", "$readers")

  $projectqueryURI = "https://dev.azure.com/$DevOpsOrganization/_apis/projects?api-version=5.1"
  $projects = Invoke-RestMethod -Headers $header -uri $projectqueryURI

  #filter result of query for project that matches project name
  $projguid = @($projects.value) -match $projectname

  #actual guid of project
  $projguid.id
  $pguid = $projguid.id

  #loop for groups 2 map
  foreach ($g2m in $groups2map) {

    $type = $g2m.split('-')[-1] -replace '\s', ''

    #get azadgroup guid
    $targetadgroup = get-azadgroup -DisplayName "$g2m"
    $tg = $targetadgroup.id
    $entitlementbody = '{
  
  "group": {
    "origin": "aad",
    "originId": "' + $tg + '",
    "subjectKind": "group"
  },
  "id": null,
  "licenseRule": {
    "licensingSource": "account,",
    "accountLicenseType": "express",
    "licenseDisplayName": "Basic"
  },
  "projectEntitlements": [
    {
      "projectRef": {
        "id": "743b363f-f826-4170-bec1-bc775409a7ea",
        "name":"' + $projectname + '"
      },
      "group": {
        "groupType": "' + $type + '"
      }
    }
  ]
}'

    # To add users we use the entitlement api to create a group that maps to an AAD group and adds them to the project in the correct role based group.
    $addentitlement = Invoke-RestMethod -Headers $header -uri $entitlementURI -Body $entitlementbody -Method Post -ContentType application/json

    #proj id 743b363f-f826-4170-bec1-bc775409a7ea
    Start-Sleep -Seconds 3

    $testid = Invoke-RestMethod -Headers $header -uri "https://vsaex.dev.azure.com/$DevOpsOrganization/_apis/groupentitlements?api-version=5.1-preview.1" | select -ExpandProperty value

    # this should run a match and get specific ID
    $devopsguid = $testid | ? { $_.group.originid -match $tg }

    $updateuri = "https://vsaex.dev.azure.com/$DevOpsOrganization/_apis/groupentitlements/$($Devopsguid.id)?api-version=5.1-preview.1"


    $updatebody = '[
  {
  "from": "",
  "op": "add",
  "path": "/projectEntitlements",
  "value": {
    "projectRef": {
      "id": "' + $pguid + '"
    },
    "group": {
      "groupType": "ProjectContributor"
    }
  }
  }]'

    $actualupdate = Invoke-RestMethod -Headers $header -uri $updateuri -Body $updatebody -Method Patch -ContentType application/json-patch+json

  }
}