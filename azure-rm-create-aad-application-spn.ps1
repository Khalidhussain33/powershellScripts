<#
    creates new azurermadapplication for use with logging in to azurerm using password or cert
    to enable script execution, you may need to Set-ExecutionPolicy Bypass -Force

    # can be used with scripts for example
    # Add-AzureRmAccount -ServicePrincipal -CertificateThumbprint $cert.Thumbprint -ApplicationId $app.ApplicationId -TenantId $tenantId
    # requires free AAD base subscription
    # https://docs.microsoft.com/en-us/azure/azure-resource-manager/resource-group-authenticate-service-principal#provide-credentials-through-automated-powershell-script
    
    example command:
    iwr https://tinyurl.com/create-azure-client-id | iex

    example command to save and/or pass arguments:
    (new-object net.webclient).downloadfile("https://raw.githubusercontent.com/jagilber/powershellScripts/master/azure-rm-create-aad-application-spn.ps1","$(get-location)\azure-rm-create-aad-application-spn.ps1");
    then:
    .\azure-rm-create-aad-application-spn.ps1 -aadDisplayName azure-rm-rest-logon -logontype certthumb
    or
    .\azure-rm-create-aad-application-spn.ps1 
    
    # 181108
#>
param(
    [pscredential]$credentials,
    #[Parameter(Mandatory = $true)]
    [string]$aadDisplayName = "azure-rm-rest-logon/$($env:Computername)",
    [string]$uri,
    [switch]$list,
    [string]$pfxPath = "$($env:temp)\$($aadDisplayName).pfx",
    #[Parameter(Mandatory = $true)][ValidateSet('cert', 'key', 'password', 'certthumb')]
    [string]$logonType = 'certthumb'
)

# ----------------------------------------------------------------------------------------------------------------
function main()
{
    $keyCredential = $null
    $thumbprint = $null
    $ClientSecret = $null
    $keyvalue
   
    # todo: add new msi option
    
    $error.Clear()
    # authenticate
    try
    {
        Get-AzureRmResourceGroup | Out-Null
    }
    catch
    {
        try
        {
            Add-AzureRmAccount
        }
        catch [System.Management.Automation.CommandNotFoundException]
        {
            write-host "installing azurerm sdk. this will take a while..."
            
            install-module azurerm
            import-module azurerm

            Add-AzureRmAccount
        }
    }

    if (!$uri)
    {
        $uri = "https://$($aadDisplayName)"
    }

    $tenantId = (Get-AzureRmContext).Tenant.Id

    if ((Get-AzureRmADApplication -DisplayNameStartWith $aadDisplayName -ErrorAction SilentlyContinue))
    {
        $app = Get-AzureRmADApplication -DisplayNameStartWith $aadDisplayName

        if ((read-host "AAD application exists: $($aadDisplayName). Do you want to delete?[y|n]") -imatch "y")
        {
            remove-AzureRmADApplication -objectId $app.objectId -Force
        
            $id = Get-AzureRmADServicePrincipal -SearchString $aadDisplayName
        
            if (@($id).Count -eq 1)
            {
                Remove-AzureRmADServicePrincipal -ObjectId $id
            }
        }
    }
    
    if (!$list)
    {
        if ($logontype -ieq 'cert')
        {
            Write-Warning "this option is NOT currently working for rest authentication, but does work for ps auth!!!"
            $cert = New-SelfSignedCertificate -CertStoreLocation "cert:\currentuser\My" -Subject "CN=$($aadDisplayName)" -KeyExportPolicy Exportable -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider"
            
            if (!$credentials)
            {
                $credentials = (get-credential)
            }

            $pwd = ConvertTo-SecureString -String $credentials.Password -Force -AsPlainText

            if([io.file]::Exists($pfxPath))
            {
                [io.file]::Delete($pfxPath)
            }

            Export-PfxCertificate -cert "cert:\currentuser\my\$($cert.thumbprint)" -FilePath $pfxPath -Password $pwd
            $cert509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate($pfxPath, $pwd)
            $thumbprint = $cert509.thumbprint
            $keyValue = [System.Convert]::ToBase64String($cert509.GetCertHash())
            write-host "New-AzureRmADApplication -DisplayName $aadDisplayName -HomePage $uri -IdentifierUris $uri -CertValue $keyValue -EndDate $cert.NotAfter -StartDate $cert.NotBefore"

            if($oldAdApp = Get-AzureRmADApplication -DisplayNameStartWith $aadDisplayName)
            {
                remove-AzureRmADApplication -ObjectId $oldAdApp.objectId
            }
            
            $DebugPreference = "Continue"    
            write-host "New-AzureRmADApplication -DisplayName $aadDisplayName -HomePage $uri -IdentifierUris $uri -CertValue $keyValue -EndDate $($cert.NotAfter) -StartDate $($cert.NotBefore) -verbose"
            $app = New-AzureRmADApplication -DisplayName $aadDisplayName -HomePage $uri -IdentifierUris $uri -CertValue ($cert.GetRawCertData()) -EndDate ($cert.NotAfter) -StartDate ($cert.NotBefore) -verbose #-Debug 
            $app            
            #$DebugPreference = "SilentlyContinue"
            $app = New-AzureRmADAppCredential -applicationId ($app.ApplicationId) -DisplayName $aadDisplayName -HomePage $uri -IdentifierUris $uri -KeyCredentials $KeyCredential -Verbose

        }
        elseif ($logontype -ieq 'certthumb')
        {
            
            $cert = New-SelfSignedCertificate -CertStoreLocation "cert:\currentuser\My" -Subject "$($aadDisplayName)" -KeyExportPolicy Exportable -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider"
            $keyValue = [System.Convert]::ToBase64String($cert.GetCertHash())
            write-host "New-AzureRmADApplication -DisplayName $aadDisplayName -HomePage $uri -IdentifierUris $uri -CertValue $keyValue -EndDate $cert.NotAfter -StartDate $cert.NotBefore"
            $thumbprint = $cert.Thumbprint
            $ClientSecret = [System.Convert]::ToBase64String($cert.GetCertHash())
            $pwd = ConvertTo-SecureString -String $ClientSecret -Force -AsPlainText
            $app = New-AzureRmADApplication -DisplayName $aadDisplayName -HomePage $uri -IdentifierUris $uri -Password $pwd -EndDate ($cert.NotAfter)
        }
        elseif ($logontype -ieq 'key')
        {
            $bytes = New-Object Byte[] 32
            $rand = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            $rand.GetBytes($bytes)

            $ClientSecret = [System.Convert]::ToBase64String($bytes)
            $pwd = ConvertTo-SecureString -String $ClientSecret -Force -AsPlainText
            $endDate = [System.DateTime]::Now.AddYears(2)

            $app = New-AzureRmADApplication -DisplayName $aadDisplayName -HomePage $URI -IdentifierUris $URI -Password $pwd -EndDate $endDate
            write-host "client secret: $($ClientSecret)" -ForegroundColor Yellow

        }
        else
        {
            write-warning "credentials need to be psadcredentials to work"
            if (!$credentials)
            {
                write-warning "no credentials, exiting"
                exit 1
            }
            # to use password
            $app = New-AzureRmADApplication -DisplayName $aadDisplayName -HomePage $uri -IdentifierUris $uri -PasswordCredentials $credentials
        }

        $app
        
        New-AzureRmADServicePrincipal -ApplicationId ($app.ApplicationId) -DisplayName $aadDisplayName
        
        Start-Sleep 15
        New-AzureRmRoleAssignment -RoleDefinitionName Reader -ServicePrincipalName ($app.ApplicationId)
        New-AzureRmRoleAssignment -RoleDefinitionName Contributor -ServicePrincipalName ($app.ApplicationId)
        

        if ($logontype -ieq 'cert' -or $logontype -ieq 'certthumb')
        {
            write-host "for use in script: Add-AzureRmAccount -ServicePrincipal -CertificateThumbprint $($cert.Thumbprint) -ApplicationId $($app.ApplicationId) -TenantId $($tenantId)"
            write-host "certificate thumbprint: $($cert.Thumbprint)"
            
        }
    } 

    $app
    write-host "application id: $($app.ApplicationId)" -ForegroundColor Cyan
    write-host "tenant id: $($tenantId)" -ForegroundColor Cyan
    write-host "application identifier Uri: $($uri)" -ForegroundColor Cyan
    write-host "keyValue: $($keyValue)" -ForegroundColor Cyan
    write-host "clientsecret: $($clientsecret)" -ForegroundColor Cyan
    write-host "clientsecret BASE64:$([convert]::ToBase64String([text.encoding]::Unicode.GetBytes($clientsecret)))"
    write-host "thumbprint: $($thumbprint)" -ForegroundColor Cyan
    write-host "pfx path: $($pfxPath)" -ForegroundColor Cyan
    $global:thumbprint = $thumbprint
    $global:applicationId = $app.Applicationid
    $global:tenantId = $tenantId
    $global:clientSecret = $ClientSecret
    $global:keyValue = $keyValue
    write-host "clientid / applicationid saved in `$global:applicationId" -ForegroundColor Yellow
    write-host "clientsecret / base64 thumb saved in `$global:clientSecret" -ForegroundColor Yellow

}
# ----------------------------------------------------------------------------------------------------------------

main