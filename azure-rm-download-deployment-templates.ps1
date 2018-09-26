﻿<#
    script to export all deployment templates, parameters, and operations from azure subscription or list of resourcegroups
    https://docs.microsoft.com/en-us/rest/api/resources/resourcegroups/exporttemplate

    {
"options" : "IncludeParameterDefaultValue, IncludeComments",
"resources" : ['*']

}
#>

param(
    [string]$outputDir = (get-location).path,
    [string[]]$resourceGroups,
    [string]$clientId,
    [string]$clientSecret,
    [switch]$useGit,
    [switch]$currentOnly
)

$outputDir = $outputDir + "\armDeploymentTemplates"
$ErrorActionPreference = "silentlycontinue"
$getCurrentConfig = $clientId + $clientSecret -gt 0
$currentdir = (get-location).path
$error.Clear()
$repo = "https://raw.githubusercontent.com/jagilber/powershellScripts/master/"
$restLogonScript = "$($currentDir)\azure-rm-rest-logon.ps1"
$restQueryScript = "$($currentDir)\azure-rm-rest-query.ps1"
$global:token = $Null

function main()
{
    check-authentication
    New-Item -ItemType Directory $outputDir -ErrorAction SilentlyContinue
    Get-AzureRmDeployment | Save-AzureRmDeploymentTemplate -Path $outputDir -Force
    set-location $outputDir

    if($useGit -and !(git))
    {
        write-host "git not installed"
        $useGit = $false
        $error.Clear()
    }
    
    if($useGit -and !(git status))
    {
        git init
    }

    if($resourceGroups.Count -lt 1)
    {
        $resourceGroups = @((Get-AzureRmResourceGroup).ResourceGroupName)
    }


    if(!$currentOnly)
    {
        $deployments = (Get-AzureRmResourceGroup) | Where-Object ResourceGroupName -imatch ($resourceGroups -join "|") | Get-AzureRmResourceGroupDeployment

        foreach($dep in ($deployments | sort-object -Property Timestamp))
        {
            $rg = $dep.ResourceGroupName
            $rgDir = "$($outputDir)\$($rg)"
            New-Item -ItemType Directory $rgDir -ErrorAction SilentlyContinue

            $baseFile = "$($rgDir)\$($dep.deploymentname)"
            Save-AzureRmResourceGroupDeploymentTemplate -Path "$($baseFile).template.json" -ResourceGroupName $rg -DeploymentName ($dep.DeploymentName) -Force
            out-file -Encoding ascii -InputObject ((convertto-json ($dep.Parameters) -Depth 99).Replace("    "," ")) -FilePath "$($baseFile).parameters.json" -Force

            $operations = Get-AzureRmResourceGroupDeploymentOperation -DeploymentName $($dep.DeploymentName) -ResourceGroupName $rg
            out-file -Encoding ascii -InputObject ((convertto-json $operations -Depth 99).Replace("    "," ")) -FilePath "$($baseFile).operations.json" -Force

            if($useGit)
            {
                git add -A
                git commit -a -m "$($rg) $($dep.deploymentname) $($dep.TimeStamp) $($dep.ProvisioningState)`n$($dep.outputs | fl * | out-string)" --date (($dep.TimeStamp).ToString("o"))
            }
        }
    }

    if($getCurrentConfig)
    {
        if(!(test-path $restLogonScript))
        {
            get-update -destinationFile $restLogonScript -updateUrl "$($repo)$([io.path]::GetFileName($restLogonScript))"
        }
      
        if(!(test-path $restQueryScript))
        {
            get-update -destinationFile $restQueryScript -updateUrl "$($repo)$([io.path]::GetFileName($restQueryScript))"
        }

        $global:token = Invoke-Expression "$($restLogonScript) -clientSecret $($clientSecret) -applicationId $($clientId)" 
        $global:token
   }
    
    if($useGit -and !(git status))
    {
        git init
    }

    if($resourceGroups.Count -lt 1)
    {
        $resourceGroups = @((Get-AzureRmResourceGroup).ResourceGroupName)
    }

    foreach($rg in $resourceGroups)
    {
        $rgDir = "$($outputDir)\$($rg)"
        New-Item -ItemType Directory $rgDir -ErrorAction SilentlyContinue
        if($getCurrentConfig)
        {   
            $currentConfig = get-currentConfig -rg $rg
            #out-file -InputObject (convertto-json (get-currentConfig -rg $rg)) -FilePath "$($rgDir)\current.json" -Force
            out-file -InputObject ([Text.RegularExpressions.Regex]::Unescape((convertto-json ($currentConfig.template)))) -FilePath "$($rgDir)\current.json" -Force

            if($currentConfig.error)
            {
                out-file -InputObject ([Text.RegularExpressions.Regex]::Unescape((convertto-json ($currentConfig.error)))) -FilePath "$($rgDir)\current.errors.json" -Force
            }
        }

        foreach($dep in (Get-AzureRmResourceGroupDeployment -ResourceGroupName $rg))
        {
            if($useGit)
            {
                $templateFile = "$($rgDir)\template.json"

                Save-AzureRmResourceGroupDeploymentTemplate -Path $templateFile -ResourceGroupName $rg -DeploymentName ($dep.DeploymentName) -Force
                out-file -Encoding ascii -InputObject (convertto-json $dep.Parameters) -FilePath "$($rgDir)\parameters.json" -Force
                out-file -Encoding ascii -InputObject (convertto-json (Get-AzureRmResourceGroupDeploymentOperation -DeploymentName $($dep.DeploymentName) -ResourceGroupName $rg) -Depth 99) -FilePath "$($rgDir)\operations.json" -Force
                
                git add -A
                git commit -a -m "$($rg) $($dep.deploymentname)) $($dep.TimeStamp) $($dep.ProvisioningState)`n$($outputs | out-string)" --date (($dep.TimeStamp).ToString("o"))
            }
            else
            {
                Save-AzureRmResourceGroupDeploymentTemplate -Path $rgDir -ResourceGroupName $rg -DeploymentName ($dep.DeploymentName) -Force
                out-file -Encoding ascii -InputObject (convertto-json $dep.Parameters) -FilePath "$($rgDir)\$($dep.deploymentname).parameters.json" -Force
                out-file -Encoding ascii -InputObject (convertto-json (Get-AzureRmResourceGroupDeploymentOperation -DeploymentName $($dep.DeploymentName) -ResourceGroupName $rg) -Depth 99) -FilePath "$($rgDir)\$($dep.deploymentname).operations.json" -Force
            }
        }    
    }

    if(!$getCurrentConfig)
    {
        write-warning "this information does *not* include the currently running confiruration, only the last deployments. example no changes made in portal after deployment"
        write-host "to get the current running configuration ('automation script' in portal), use portal, or"
        write-host "rerun script with clientid and clientsecret"
        write-host "these are values used when connecting to azure using a script either with powershel azure modules or rest methods"
        write-host "output will contain clientid and clientsecret (thumbprint)"
        write-host "see link for additional information https://blogs.msdn.microsoft.com/igorpag/2017/06/28/using-powershell-as-an-azure-arm-rest-api-client/" -ForegroundColor Cyan

        write-host "use this script to generate azure ad spn app with a self signed cert for use with scripts (not just this one)"
        write-host "(new-object net.webclient).downloadfile(`"https://raw.githubusercontent.com/jagilber/powershellScripts/master/azure-rm-create-aad-application-spn.ps1`",`"$($currentDir)\azure-rm-create-aad-application-spn.ps1`");" -ForegroundColor Yellow
        write-host "$($currentDir)\azure-rm-create-aad-application-spn.ps1 -aadDisplayName powerShellRestSpn -logontype certthumb" -ForegroundColor Yellow
    }
}

function get-update($updateUrl, $destinationFile)
{
    write-host "get-update:checking for updated script: $($updateUrl)"
    $file = ""
    $git = $null

    try 
    {
        $git = Invoke-RestMethod -UseBasicParsing -Method Get -Uri $updateUrl 

        # git may not have carriage return
        # reset by setting all to just lf
        $git = [regex]::Replace($git, "`r`n","`n")
        # add cr back
        $git = [regex]::Replace($git, "`n", "`r`n")

        if ([IO.File]::Exists($destinationFile))
        {
            $file = [IO.File]::ReadAllText($destinationFile)
        }

        if (([string]::Compare($git, $file) -ne 0))
        {
            write-host "copying script $($destinationFile)"
            [IO.File]::WriteAllText($destinationFile, $git)
            return $true
        }
        else
        {
            write-host "script is up to date"
        }
        
        return $false
    }
    catch [System.Exception] 
    {
        write-host "get-update:exception: $($error)"
        $error.Clear()
        return $false    
    }
}

function get-currentConfig($rg)
{
    $url = "https://management.azure.com/subscriptions/$((get-azurermcontext).subscription.id)/resourcegroups/$($rg)/exportTemplate?api-version=2018-02-01"
    write-host $url
    $body = "@{'options'='IncludeParameterDefaultValue, IncludeComments';'resources' = @('*')}"
    $command = "$($restQueryScript) -clientId =$($clientid) -query `"resourcegroups/$($rg)/exportTemplate`" -apiVersion `"2018-02-01`" -method post -body " + $body
    write-host $command 
    $results = invoke-expression $command

    if($results.error)
    {
        write-warning (convertto-json ($results.error))
    }
    
    return $results
}

function check-authentication()
{
        # authenticate
        try
        {
            $tenants = @(Get-AzureRmTenant)
                        
            if ($tenants)
            {
                write-host "auth passed $($tenants.Count)"
            }
            else
            {
                write-host "auth error $($error)" -ForegroundColor Yellow
                exit 1
            }
        }
        catch
        {
            try
            {
                Add-AzureRmAccount
            }
            catch
            {
                write-host "exception authenticating. exiting $($error)" -ForegroundColor Yellow
                exit 1
            }
        }
}

try
{
    main
}
catch
{
    write-host "main exception $($error | out-string)"
}
finally
{
    code $outputDir
    $outputDir
    set-location $currentdir
    write-host "finished"
}