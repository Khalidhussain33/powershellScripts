<#
.SYNOPSIS
powershell script to collect service fabric node diagnostic data

To download and execute, run the following commands on each sf node in admin powershell:
iwr('https://raw.githubusercontent.com/jagilber/powershellScripts/master/serviceFabric/sf-collect-node-info.ps1') -UseBasicParsing|iex

To download and execute with arguments:
(new-object net.webclient).downloadfile("https://raw.githubusercontent.com/jagilber/powershellScripts/master/serviceFabric/sf-collect-node-info.ps1","c:\sf-collect-node-info.ps1")
c:\sf-collect-node-info.ps1 -certInfo -days 30

upload to workspace sfgather* dir or zip

.DESCRIPTION
    To enable script execution, you may need to Set-ExecutionPolicy Bypass -Force
    script will collect event logs, hotfixes, services, processes, drive, firewall, and other OS information

    Requirements:
        - administrator powershell prompt
        - administrative access to machine
        - remote network ports:
            - smb 445
            - rpc endpoint mapper 135
            - rpc ephemeral ports
            - to test access from source machine to remote machine: dir \\%remote machine%\admin$
        - winrm
            - depending on configuration / security, it may be necessary to modify trustedhosts on 
            source machine for management of remote machines
            - to query: winrm get winrm/config
            - to enable sending credentials to remote machines: winrm set winrm/config/client '@{TrustedHosts="*"}'
            - to disable sending credentials to remote machines: winrm set winrm/config/client '@{TrustedHosts=""}'
        - firewall
            - if firewall is preventing connectivity the following can be run to disable
            - Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
            
    Copyright 2018 Microsoft Corporation

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
    
.NOTES
    File Name  : sf-collect-node-info.ps1
    Author     : jagilber
    Version    : 180815 original
    History    : 
    
.EXAMPLE
    .\sf-collect-node-info.ps1 -certInfo
    Example command to query all diagnostic information, event logs, and certificate store information

.PARAMETER workDir
    output directory where all files will be created.
    default is $env:temp

.LINK
    https://raw.githubusercontent.com/jagilber/powershellScripts/master/serviceFabric/sf-collect-node-info.ps1
#>
[CmdletBinding()]
param(
    $workdir,
    $eventLogNames = "System$|Application$|wininet|dns|Fabric|http|Firewall|Azure",
    $startTime = (get-date).AddDays(-7),
    $endTime = (get-date),
    [int[]]$ports = @(1025, 1026, 1027, 19000, 19080, 135, 445, 3389, 5985),
    [string[]]$remoteMachines,
    $networkTestAddress = $env:computername,
    $externalUrl = "bing.com",
    [switch]$noAdmin,
    [switch]$noEventLogs,
    [switch]$certInfo,
    [switch]$quiet
)

$ErrorActionPreference = "Continue"
$scriptUrl = 'https://raw.githubusercontent.com/jagilber/powershellScripts/master/serviceFabric/sf-collect-node-info.ps1'
$currentWorkDir = get-location
$osVersion = [version]([string]((wmic os get Version) -match "\d"))
$win10 = ($osVersion.major -ge 10)
$parentWorkDir = $null
$jobs = new-object collections.arraylist
$logFile = $Null
$zipFile = $null

function main()
{
    $error.Clear()
    write-warning "to troubleshoot this issue, this script may collect sensitive information similar to other microsoft diagnostic tools."
    write-warning "information may contain items such as ip addresses, process information, user names, or similar."
    write-warning "information in directory / zip can be reviewed before uploading to workspace."

    if(!$workDir -and $remoteMachines)
    {
        $workdir = "$($env:temp)\sfgather-$((get-date).ToString("yy-MM-dd-HH-ss"))"
    }
    elseif(!$workDir)
    {
        $workdir = "$($env:temp)\sfgather-$($env:COMPUTERNAME)"
    }

    $parentWorkDir = [io.path]::GetDirectoryName($workDir)

    if ((test-path $workdir))
    {
        remove-item $workdir -Recurse -Force
    }

    new-item $workdir -ItemType Directory
    Set-Location $parentworkdir
    $logFile = "$($workdir)\sf-collect-node-info.log"
    Start-Transcript -Path $logFile -Force
    write-host "starting $(get-date)"

    if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
    {   
        Write-Warning "please restart script in administrator powershell session"

        if (!$noadmin)
        {
            Write-Warning "if unable to run as admin, restart and use -noadmin switch. This will collect less data that may be needed. exiting..."
            return $false
        }
    }

    write-host "remove old jobs"
    get-job | remove-job -Force

    if($remoteMachines)
    {
        foreach ($machine in @($remoteMachines))
        {
            $adminPath = "\\$($machine)\admin$\temp"

            if(!(Test-path $adminPath))
            {
                Write-Warning "unable to connect to $($machine) to start diagnostics. skipping!"
                continue
            }

            copy-item -path ($MyInvocation.ScriptName) -Destination $adminPath

            write-host "adding job for $($machine)"
            [void]$jobs.Add((Invoke-Command -JobName $machine -AsJob -ComputerName $machine -scriptblock {
                param($scriptUrl = $args[0], $machine = $args[1], $networkTestAddress = $args[2])
                $parentWorkDir = "$($env:systemroot)\temp"
                $workDir = "$($parentWorkDir)\sfgather-$($machine)"
                $scriptPath = "$($parentWorkDir)\$($scriptUrl -replace `".*/`",`"`")"

                if (!(test-path $scriptPath))
                {
                    (new-object net.webclient).downloadfile($scriptUrl,$scriptPath)
                }
             
                start-process -filepath "powershell.exe" -ArgumentList "-File $($scriptPath) -quiet -noadmin -networkTestAddress $($networkTestAddress) -workDir $($workDir)" -Wait -NoNewWindow
                write-host ($error | out-string)
            } -ArgumentList @($scriptUrl, $machine, $networkTestAddress)))
        }

        monitor-jobs

        foreach ($machine in @($remoteMachines))
        {
            $adminPath = "\\$($machine)\admin$\temp"
            $foundZip = $false

            if(!(Test-path $adminPath))
            {
                Write-Warning "unable to connect to $($machine) to copy zip. skipping!"
                continue
            }

            $sourcePath = "$($adminPath)\sfgather-$($machine)"
            $destPath = "$($workDir)\sfgather-$($machine)"

            $sourcePathZip = "$($sourcePath).zip"
            $destPathZip = "$($destPath).zip"

            if((test-path $sourcePathZip))
            {
                write-host "copying file $($sourcePathZip) to $($destPathZip)" -ForegroundColor Magenta
                Copy-Item $sourcePathZip $destPathZip -Force
                remove-item $sourcePathZip -Force
                $foundZip = $true
            }
            
            if((test-path $sourcePath))
            {
                if(!$foundZip)
                {
                    write-host "copying folder $($sourcePath) to $($destPath)" -ForegroundColor Magenta
                    Copy-Item $sourcePath $destPath -Force -Recurse
                    compress-file $destPath
                }

                remove-item $sourcePath -Recurse -Force
            }
            else
            {
                write-host "warning: unable to find diagnostic files in $($sourcePath)"
            }
        }

        $zipFile = compress-file $workDir
    }
    else
    {
        process-machine
    }

    if (!($quiet) -and (test-path "$($env:systemroot)\explorer.exe"))
    {
        start-process "explorer.exe" -ArgumentList $parentWorkDir
    }
}
function process-machine()
{
    write-host "processing machine"
    
    if ($win10)
    {
        add-job -jobName "windows update" -scriptBlock {
            param($workdir = $args[0]) 
            Get-WindowsUpdateLog -LogPath "$($workdir)\windowsupdate.log.txt"
        } -arguments $workdir
    }
    else
    {
        copy-item "$env:systemroot\windowsupdate.log" "$($workdir)\windowsupdate.log.txt"
    }

    if (!$noEventLogs)
    {
        add-job -jobName "event logs" -scriptBlock {
            param($workdir = $args[0], $parentWorkdir = $args[1], $eventLogNames = $args[2], $startTime = $args[3], $endTime = $args[4])
            $scriptFile = "$($parentWorkdir)\event-log-manager.ps1"
            if (!(test-path $scriptFile))
            {
                (new-object net.webclient).downloadfile("http://aka.ms/event-log-manager.ps1", $scriptFile)
            }

            $tempLocation = "$($workdir)\event-logs"
            if(!(test-path $tempLocation))
            {
                New-Item -ItemType Directory -Path $tempLocation    
            }

            $argList = "-File $($parentWorkdir)\event-log-manager.ps1 -eventLogNamePattern `"$($eventlognames)`" -eventStartTime `"$($startTime)`" -eventStopTime `"$($endTime)`" -eventDetails -merge -uploadDir `"$($tempLocation)`" -nodynamicpath"
            write-host "event logs: starting command powershell.exe $($argList)"
            start-process -filepath "powershell.exe" -ArgumentList $argList -Wait -WindowStyle Hidden -WorkingDirectory $tempLocation
        } -arguments @($workdir, $parentWorkdir, $eventLogNames, $startTime, $endTime)
    }

    add-job -jobName "check for dump file c" -scriptBlock {
        param($workdir = $args[0])
        # slow
        # Invoke-Command -ScriptBlock { start-process "cmd.exe" -ArgumentList "/c dir c:\*.*dmp /s > "$env:temp\dumplist-c.txt" -Wait -WindowStyle Hidden }
        #Invoke-Expression "cmd.exe /c dir c:\*.*dmp /s > $($workdir)\dumplist-c.txt"
        get-childitem -Recurse -Path "c:\" -Filter "*.*dmp" | out-file "$($workdir)\dumplist-c.txt"
    } -arguments @($workdir)

    add-job -jobName "check for dump file d" -scriptBlock {
        param($workdir = $args[0])
        # Invoke-Command -ScriptBlock { start-process "cmd.exe" -ArgumentList "/c dir d:\*.*dmp /s > "$env:temp\dumplist-d.txt" -Wait -WindowStyle Hidden }
        #Invoke-Expression "cmd.exe /c dir d:\*.*dmp /s > $($workdir)\dumplist-d.txt"
        get-childitem -Recurse -Path "d:\" -Filter "*.*dmp" | out-file "$($workdir)\dumplist-d.txt"
    } -arguments @($workdir)

    add-job -jobName "network port tests" -scriptBlock {
        param($workdir = $args[0], $networkTestAddress = $args[1], $ports = $args[2])
        foreach ($port in $ports)
        {
            test-netconnection -port $port -ComputerName $networkTestAddress -InformationLevel Detailed | out-file -Append "$($workdir)\network-port-test.txt"
        }
    } -arguments @($workdir, $networkTestAddress, $ports)

    add-job -jobName "check external connection" -scriptBlock {
        param($workdir = $args[0], $externalUrl = $args[1])
        [net.httpWebResponse](Invoke-WebRequest $externalUrl -UseBasicParsing).BaseResponse | out-file "$($workdir)\network-external-test.txt" 
    } -arguments @($workdir, $externalUrl)

    add-job -jobName "resolve-dnsname" -scriptBlock {
        param($workdir = $args[0], $networkTestAddress = $args[1], $externalUrl = $args[2])
        Resolve-DnsName -Name $networkTestAddress | out-file -Append "$($workdir)\resolve-dnsname.txt"
        Resolve-DnsName -Name $externalUrl | out-file -Append "$($workdir)\resolve-dnsname.txt"
    } -arguments @($workdir, $networkTestAddress, $externalUrl)

    add-job -jobName "nslookup" -scriptBlock {
        param($workdir = $args[0], $networkTestAddress = $args[1], $externalUrl = $args[2])
        write-host "nslookup"
        out-file -InputObject "querying nslookup for $($externalUrl)" -Append "$($workdir)\nslookup.txt"
        Invoke-Expression "nslookup $($externalUrl) | out-file -Append $($workdir)\nslookup.txt"
        out-file -InputObject "querying nslookup for $($networkTestAddress)" -Append "$($workdir)\nslookup.txt"
        Invoke-Expression "nslookup $($networkTestAddress) | out-file -Append $($workdir)\nslookup.txt"
    } -arguments @($workdir, $networkTestAddress, $externalUrl)


    write-host "winrm settings"
    Invoke-Expression "winrm get winrm/config/client > $($workdir)\winrm-config.txt" 

    if ($certInfo)
    {
        write-host "certs (output scrubbed)"
        [regex]::Replace((Get-ChildItem -Path cert: -Recurse | format-list * | out-string), "[0-9a-fA-F]{20}`r`n", "xxxxxxxxxxxxxxxxxxxx`r`n") | out-file "$($workdir)\certs.txt"
    }
    
    write-host "http log files"
    copy-item -path "C:\Windows\System32\LogFiles\HTTPERR\*" -Destination $workdir -Force -Filter "*.log"

    add-job -jobName "drives" -scriptBlock {
        param($workdir = $args[0])
        Get-psdrive | out-file "$($workdir)\drives.txt"
    } -arguments @($workdir)

    add-job -jobName "os info" -scriptBlock {
        param($workdir = $args[0])
        get-wmiobject -Class Win32_OperatingSystem -Namespace root\cimv2 | format-list * | out-file "$($workdir)\os-info.txt"
        get-hotfix | out-file "$($workdir)\hotfixes.txt"
        Get-process | out-file "$($workdir)\process-summary.txt"
        Get-process | format-list * | out-file "$($workdir)\processes.txt"
        get-process | Where-Object ProcessName -imatch "fabric" | out-file "$($workdir)\processes-fabric.txt"
        Get-service | out-file "$($workdir)\service-summary.txt"
        Get-Service | format-list * | out-file "$($workdir)\services.txt"
    } -arguments @($workdir)

    write-host "installed applications"
    Invoke-Expression "reg.exe query HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall /s /v DisplayName > $($workDir)\installed-apps.reg.txt"

    write-host "features"
    Get-WindowsFeature | Where-Object "InstallState" -eq "Installed" | out-file "$($workdir)\windows-features.txt"

    add-job -jobName ".net reg" -scriptBlock {
        param($workdir = $args[0])
        Invoke-Expression "reg.exe query HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\.NETFramework /s > $($workDir)\dotnet.reg.txt"
    } -arguments @($workdir)

    write-host "policies"
    Invoke-Expression "reg.exe query HKEY_LOCAL_MACHINE\SOFTWARE\Policies /s > $($workDir)\policies.reg.txt"

    write-host "schannel"
    Invoke-Expression "reg.exe query HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL /s > $($workDir)\schannel.reg.txt"

    add-job -jobName "firewall" -scriptBlock {
        param($workdir = $args[0])
        Invoke-Expression "reg.exe query HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules /s > $($workDir)\firewallrules.reg.txt"
        Get-NetFirewallRule | out-file "$($workdir)\firewall-config.txt"
    } -arguments @($workdir)

    add-job -jobName "get-nettcpconnetion" -scriptBlock {
        param($workdir = $args[0])
        Get-NetTCPConnection | format-list * | out-file "$($workdir)\netTcpConnection.txt"
        Get-NetTCPConnection | Where-Object RemotePort -eq 1026 | out-file "$($workdir)\connected-nodes.txt"
    } -arguments @($workdir)

    write-host "netstat ports"
    Invoke-Expression "netstat -bna > $($workdir)\netstat.txt"

    write-host "netsh ssl"
    Invoke-Expression "netsh http show sslcert > $($workdir)\netshssl.txt"

    write-host "ip info"
    Invoke-Expression "ipconfig /all > $($workdir)\ipconfig.txt"

    write-host "service fabric reg"
    #HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Service Fabric
    Invoke-Expression "reg.exe query `"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Service Fabric`" /s > $($workDir)\serviceFabric.reg.txt"
    Invoke-Expression "reg.exe query HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\ServiceFabricNodeBootStrapAgent /s > $($workDir)\serviceFabricNodeBootStrapAgent.reg.txt"

    #
    # service fabric information
    #
    $fabricDataRoot = (get-itemproperty -path "hklm:\software\microsoft\service fabric" -Name "fabricdataroot").fabricdataroot
    write-host "fabric data root:$($fabricDataRoot)"

    add-job -jobName "fabric config files" -scriptBlock {
        param($workdir = $args[0], $fabricDataRoot = $args[1])
        Get-ChildItem $($fabricDataRoot) -Recurse | out-file "$($workDir)\dir-fabricdataroot.txt"
        Copy-Item -Path $fabricDataRoot -Filter "*.xml" -Destination $workdir -Recurse
    } -arguments @($workdir, $fabricDataRoot)


    $clusterManifestFile = "$($fabricDataRoot)\clustermanifest.xml"
    if ((test-path $clusterManifestFile))
    {
        write-host "reading $($clusterManifestFile)"    
        $xml = read-xml -xmlFile $clusterManifestFile
        $xml.clustermanifest
        $seedNodes = $xml.ClusterManifest.Infrastructure.PaaS.Votes.Vote
        write-host "seed nodes: $($seedNodes | format-list * | out-string)"
        $nodeCount = $xml.ClusterManifest.Infrastructure.PaaS.Roles.Role.RoleNodeCount
        write-host "node count:$($nodeCount)"
        $clusterId = ($xml.ClusterManifest.FabricSettings.Section | Where-Object Name -eq "Paas").FirstChild.value
        write-host "cluster id:$($clusterId)"
        $upgradeServiceParams = ($xml.ClusterManifest.FabricSettings.Section | Where-Object Name -eq "UpgradeService").parameter
        $sfrpUrl = ($upgradeServiceParams | Where-Object Name -eq "BaseUrl").Value
        $sfrpUrl = "$($sfrpUrl)$($clusterId)"
        write-host "sfrp url:$($sfrpUrl)"
        out-file -InputObject $sfrpUrl "$($workdir)\sfrp-response.txt"
        $ucert = ($upgradeServiceParams | Where-Object Name -eq "X509FindValue").Value
        
        $sfrpResponse = Invoke-WebRequest $sfrpUrl -UseBasicParsing -Certificate (Get-ChildItem -Path cert: -Recurse | Where-Object Thumbprint -eq $ucert)
        write-host "sfrp response: $($sfrpresponse)"
        out-file -Append -InputObject $sfrpResponse "$($workdir)\sfrp-response.txt"
    }

    $fabricRoot = (get-itemproperty -path "hklm:\software\microsoft\service fabric" -Name "fabricroot").fabricroot
    write-host "fabric root:$($fabricRoot)"
    Get-ChildItem $($fabricRoot) -Recurse | out-file "$($workDir)\dir-fabricroot.txt"

    write-host "waiting for $($jobs.Count) jobs to complete"

    monitor-jobs

    write-host "formatting xml files"
    foreach ($file in (get-childitem -filter *.xml -Path "$($workdir)" -Recurse))
    {
        # format xml in output
        read-xml -xmlFile $file.FullName -format
    }

    $zipFile = compress-file $workDir
}

function add-job($jobName, $scriptBlock, $arguments)
{
    write-host "adding job $($jobName)"
    [void]$jobs.Add((Start-Job -Name $jobName -ScriptBlock $scriptBlock -ArgumentList $arguments))
}

function compress-file($dir)
{
    $zipFile = "$($dir).zip"
    write-host "creating zip $($zipFile)"

    if ((test-path $zipFile ))
    {
        remove-item $zipFile -Force
    }

    Stop-Transcript | out-null

    if ($win10)
    {
        Compress-archive -path $workdir -destinationPath $zipFile -Force
    }
    else
    {
        Add-Type -Assembly System.IO.Compression.FileSystem
        $compressionLevel = [System.IO.Compression.CompressionLevel]::Optimal
        [void][System.IO.Compression.ZipFile]::CreateFromDirectory($workdir, $zipFile, $compressionLevel, $false)
    }

    Start-Transcript -Path $logFile -Force -Append | Out-Null
    return $zipFile
}

function monitor-jobs()
{
    $incompletedCount = 0

    while (get-job)
    {
        foreach ($job in get-job)
        {
            write-host ("name:$($job.Name) state:$($job.State) output:$((Receive-Job -job $job | fl * | out-string))") -ForegroundColor Cyan

            if ($job.State -imatch "Failed|Completed")
            {
                remove-job $job -Force
            }
        }

        $incompleteCount = (get-job | Where-Object State -eq "Running").Count
        
        if($incompletedCount -ne $incompleteCount)
        {
            write-host "$((get-date).ToString("hh:mm:ss")) waiting on $($incompleteCount) jobs..." -ForegroundColor Yellow
            $incompletedCount = $incompleteCount
            continue
        }

        start-sleep -seconds 1
    }
}
function read-xml($xmlFile, [switch]$format)
{
    try
    {
        write-host "reading xml file $($xmlFile)"
        [Xml.XmlDocument] $xdoc = New-Object System.Xml.XmlDocument
        [void]$xdoc.Load($xmlFile)

        if ($format)
        {
            [IO.StringWriter] $sw = new-object IO.StringWriter
            [Xml.XmlTextWriter] $xmlTextWriter = new-object Xml.XmlTextWriter ($sw)
            $xmlTextWriter.Formatting = [Xml.Formatting]::Indented
            $xdoc.PreserveWhitespace = $true
            [void]$xdoc.WriteTo($xmlTextWriter)
            #write-host ($sw.ToString())
            out-file -FilePath $xmlFile -InputObject $sw.ToString()
        }

        return $xdoc
    }
    catch
    {
        return $Null
    }
}

try
{
    main
}
catch
{
    write-error "main exception: $($error | out-string)"
}
finally
{
    set-location $currentWorkDir
    get-job | remove-job -Force
    write-host "finished $(get-date)"
    write-debug "errors during script: $($error | out-string)"
    Stop-Transcript
    write-host "upload zip to workspace:$($zipFile)" -ForegroundColor Cyan
}

