<#
.SYNOPSIS
powershell script to collect service fabric node diagnostic data
To download and execute, run the following commands on each sf node in admin powershell:
(new-object net.webclient).downloadfile("https://raw.githubusercontent.com/jagilber/powershellScripts/master/serviceFabric/sf-collect-node-info.ps1","c:\sf-collect-node-info.ps1")
c:\sf-collect-node-info.ps1
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
    .\sf-collect-node-info.ps1
    Example command to query all diagnostic information and event logs

.PARAMETER workDir
    output directory where all files will be created.
    default is $env:temp

.LINK
    https://raw.githubusercontent.com/jagilber/powershellScripts/master/serviceFabric/sf-collect-node-info.ps1
#>
[CmdletBinding()]
param(
    $workdir = $env:temp,
    $eventLogNames = "System$|Application$|wininet|dns|Fabric|http|Firewall|Azure",
    $startTime = (get-date).AddDays(-7).ToShortDateString(),
    $endTime = (get-date).ToShortDateString(),
    [int[]]$ports = @(1025, 1026, 1027, 19000, 19080, 135, 445, 3389, 5985, 5986),
    $remoteMachine = $env:computername,
    $externalUrl = "bing.com",
    [switch]$noAdmin,
    [switch]$noEventLogs
)

$ErrorActionPreference = "Continue"
$currentWorkDir = get-location
$osVersion = [version]([string]((wmic os get Version) -match "\d"))
$win10 = ($osVersion.major -ge 10)
$parentWorkDir = $workdir
$workdir = "$($workdir)\sfgather-$($env:COMPUTERNAME)"
$ps = "powershell.exe"
$jobs = new-object collections.arraylist
$logFile = "$($workdir)\sf-collect-node-info.log"
function main()
{
    $error.Clear()
    write-warning "to troubleshoot this issue, this script may collect sensitive information similar to other microsoft diagnostic tools."
    write-warning "information may contain information such as ip addresses, process information, user names, or similar."
    write-warning "all information is in plain text that can be reviewed before uploading data to workspace."

    if ((test-path $workdir))
    {
        remove-item $workdir -Recurse 
    }

    new-item $workdir -ItemType Directory
    Set-Location $parentworkdir

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
    write-host "windows update"

    if ($win10)
    {
        $jobs.Add((Start-Job -ScriptBlock {
                    param($workdir = $args[0]) 
                    Get-WindowsUpdateLog -LogPath "$($workdir)\windowsupdate.log.txt"
                } -ArgumentList $workdir))
    }
    else
    {
        copy-item "$env:systemroot\windowsupdate.log" "$($workdir)\windowsupdate.log.txt"
    }

    if (!$noEventLogs)
    {
        write-host "event logs"
        $jobs.Add((Start-Job -ScriptBlock {
                    param($workdir = $args[0], $parentWorkdir = $args[1], $eventLogNames = $args[2], $startTime = $args[3], $endTime = $args[4], $ps = $args[5], $remoteMachine = $args[6])
                    (new-object net.webclient).downloadfile("http://aka.ms/event-log-manager.ps1", "$($parentWorkdir)\event-log-manager.ps1")
                    $argList = "-File $($parentWorkdir)\event-log-manager.ps1 -eventLogNamePattern `"$($eventlognames)`" -eventStartTime $($startTime) -eventStopTime $($endTime) -eventDetails -merge -uploadDir $($workdir) -machines $($remoteMachine)"
                    start-process -filepath $ps -ArgumentList $argList -Wait -WindowStyle Hidden
                } -ArgumentList $workdir, $parentWorkdir, $eventLogNames, $startTime, $endTime, $ps, $remoteMachine))
    }

    write-host "check for dump files"
    $jobs.Add((Start-Job -ScriptBlock {
                param($workdir = $args[0], $remoteMachine = $args[1])
                # slow
                # Invoke-Command -ComputerName $remoteMachine -ScriptBlock { start-process "cmd.exe" -ArgumentList "/c dir c:\*.*dmp /s > "$env:temp\dumplist-c.txt" -Wait -WindowStyle Hidden }
                # start-process "cmd.exe" -ArgumentList "/c dir \\$($remoteMachine)\c$\*.*dmp /s > $($workdir)\dumplist-c.txt" -Wait -WindowStyle Hidden
                start-process "cmd.exe" -ArgumentList "/c dir c:\*.*dmp /s > $($workdir)\dumplist-c.txt" -Wait -WindowStyle Hidden
            } -ArgumentList $workdir, $remoteMachine))
    $jobs.Add((Start-Job -ScriptBlock {
                param($workdir = $args[0], $remoteMachine = $args[1])
                # Invoke-Command -ComputerName $remoteMachine -ScriptBlock { start-process "cmd.exe" -ArgumentList "/c dir d:\*.*dmp /s > "$env:temp\dumplist-d.txt" -Wait -WindowStyle Hidden }
                # start-process "cmd.exe" -ArgumentList "/c dir \\$($remoteMachine)\d$\*.*dmp /s > $($workdir)\dumplist-d.txt" -Wait -WindowStyle Hidden
                start-process "cmd.exe" -ArgumentList "/c dir d:\*.*dmp /s > $($workdir)\dumplist-d.txt" -Wait -WindowStyle Hidden
            } -ArgumentList $workdir, $remoteMachine))

    write-host "network port tests"
    $jobs.Add((Start-Job -ScriptBlock {
                param($workdir = $args[0], $remoteMachine = $args[1], $ports = $args[2])
                foreach ($port in $ports)
                {
                    test-netconnection -port $port -ComputerName $remoteMachine | out-file -Append "$($workdir)\network-port-test.txt"
                }
            } -ArgumentList $workdir, $remoteMachine, $ports))

    write-host "check external connection"
    [net.httpWebResponse](Invoke-WebRequest $externalUrl -UseBasicParsing).BaseResponse | out-file "$($workdir)\network-external-test.txt" 

    write-host "resolve-dnsname" # doesnt require admin like nslookup
    Resolve-DnsName -Name $remoteMachine | out-file -Append "$($workdir)\resolve-dnsname.txt"
    Resolve-DnsName -Name $externalUrl | out-file -Append "$($workdir)\resolve-dnsname.txt"
    
    write-host "nslookup"
    out-file -InputObject "querying nslookup for $($externalUrl)" -Append "$($workdir)\nslookup.txt"
    start-process $ps -ArgumentList "nslookup $($externalUrl) | out-file -Append $($workdir)\nslookup.txt" -Wait -WindowStyle Hidden
    out-file -InputObject "querying nslookup for $($remoteMachine)" -Append "$($workdir)\nslookup.txt"
    start-process $ps -ArgumentList "nslookup $($remoteMachine) | out-file -Append $($workdir)\nslookup.txt" -WindowStyle Hidden

    write-host "winrm settings"
    start-process $ps -ArgumentList "winrm get winrm/config/client > $($workdir)\winrm-config.txt" -WindowStyle Hidden

    write-host "certs (output scrubbed)"
    [regex]::Replace((Get-ChildItem -Path cert: -Recurse | format-list * | out-string), "[0-9a-fA-F]{20}`r`n", "xxxxxxxxxxxxxxxxxxxx`r`n") | out-file "$($workdir)\certs.txt"

    write-host "http log files"
    copy-item -path "\\$($remoteMachine)\C$\Windows\System32\LogFiles\HTTPERR\*" -Destination $workdir -Force -Filter "*.log"

    write-host "hotfixes"
    get-hotfix -ComputerName $remoteMachine | out-file "$($workdir)\hotfixes.txt"

    write-host "os"
    get-wmiobject -Class Win32_OperatingSystem -Namespace root\cimv2 -ComputerName $remoteMachine | format-list * | out-file "$($workdir)\os-info.txt"

    write-host "drives"
    Get-psdrive | out-file "$($workdir)\drives.txt"

    write-host "processes"
    Get-process -ComputerName $remoteMachine | format-list * | out-file "$($workdir)\processes.txt"

    write-host "services"
    Get-Service -ComputerName $remoteMachine | format-list * | out-file "$($workdir)\services.txt"

    write-host "installed applications"
    start-process $ps -ArgumentList "reg.exe query \\$($remoteMachine)\HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall /s /v DisplayName > $($workDir)\installed-apps.reg.txt" -WindowStyle Hidden

    write-host "features"
    Get-WindowsFeature | Where-Object "InstallState" -eq "Installed" | out-file "$($workdir)\windows-features.txt"

    write-host ".net"
    $jobs.Add((Start-Job -ScriptBlock {
                param($workdir = $args[0], $remoteMachine = $args[1])
                start-process $ps -ArgumentList "reg.exe query \\$($remoteMachine)\HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\.NETFramework /s > $($workDir)\dotnet.reg.txt" -WindowStyle Hidden
            } -ArgumentList $workdir, $remoteMachine))

    write-host "policies"
    start-process $ps -ArgumentList "reg.exe query \\$($remoteMachine)\HKEY_LOCAL_MACHINE\SOFTWARE\Policies /s > $($workDir)\policies.reg.txt" -WindowStyle Hidden

    write-host "schannel"
    start-process $ps -ArgumentList "reg.exe query \\$($remoteMachine)\HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL /s > $($workDir)\schannel.reg.txt" -WindowStyle Hidden

    write-host "firewall rules"
    start-process $ps -ArgumentList "reg.exe query \\$($remoteMachine)\HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules /s > $($workDir)\firewallrules.reg.txt" -WindowStyle Hidden

    write-host "firewall settings"
    Get-NetFirewallRule | out-file "$($workdir)\firewall-config.txt"

    write-host "get-nettcpconnetion" # doesnt require admin like netstat
    Get-NetTCPConnection | format-list * | out-file "$($workdir)\netTcpConnection.txt"

    write-host "netstat ports"
    start-process $ps -ArgumentList "netstat -bna > $($workdir)\netstat.txt" -WindowStyle Hidden

    write-host "netsh ssl"
    start-process $ps -ArgumentList "netsh http show sslcert > $($workdir)\netshssl.txt" -WindowStyle Hidden

    write-host "ip info"
    start-process $ps -ArgumentList "ipconfig /all > $($workdir)\ipconfig.txt" -WindowStyle Hidden

    write-host "waiting for $($jobs.Count) jobs to complete"

    while (($uncompletedCount = (get-job | Where-Object State -ne "Completed").Count) -gt 0)
    {
        write-host "waiting on $($uncompletedCount) jobs..."
        start-sleep -seconds 10
    }

    if ($win10)
    {
        write-host "zip"
        $zipFile = "$($workdir).zip"

        if ((test-path $zipFile ))
        {
            remove-item $zipFile 
        }
        
        Stop-Transcript 
        Compress-archive -path $workdir -destinationPath $workdir
        Start-Transcript -Path $logFile -Force -Append

        write-host "upload $($zipFile) to workspace" -ForegroundColor Cyan
    }
    else
    {
        write-host "zip and upload $($workdir) to workspace" -ForegroundColor Cyan
    }

    if ((test-path "$($env:systemroot)\explorer.exe"))
    {
        start-process "explorer.exe" -ArgumentList $parentWorkDir -WindowStyle Hidden
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
    write-host "remove jobs"
    get-job | remove-job -Force
    write-host "finished $(get-date)"
    write-debug "errors during script: $($error | out-string)"
    Stop-Transcript 
}
