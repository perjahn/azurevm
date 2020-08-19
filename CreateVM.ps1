Set-StrictMode -v latest
$ErrorActionPreference = "Stop"

function Main($mainargs) {
    if (!$mainargs -or (($mainargs.Length -ne 4) -and ($mainargs.Length -ne 5))) {
        Log "Script for creating infrastructure from arm template."
        Log "Usage: pwsh CreateVM.ps1 <templatefolder> <subscription> <name> <username> [resourcegroup]"
        exit 1
    }

    [string] $templateFolder = $mainargs[0]
    [string] $subscriptionName = $mainargs[1]
    [string] $name = $mainargs[2]
    [string] $username = $mainargs[3]
    [string] $resourceGroupName = $null
    if ($mainargs.Count -eq 5) {
        [string] $resourceGroupName = $mainargs[4]
    }
    else {
        [string] $resourceGroupName = "Group-" + $name
    }
    [string] $location = "West Europe"
    [string] $templateFile = Join-Path $name "template.json"
    [string] $parametersFile = Join-Path $name "parameters.json"


    Create-Files $templateFolder $name $username


    if (!(Test-Path $templateFile)) {
        Log "Couldn't find template file: '$templateFile'"
        exit 1
    }
    if (!(Test-Path $parametersFile)) {
        Log "Couldn't find parameters file: '$parametersFile'"
        exit 1
    }

    Log "Logging in..."
    Connect-AzAccount -Subscription $subscriptionName

    if ($mainargs.Count -eq 4) {
        Log "Creating resource group '$resourceGroupName' in '$location'"
        New-AzResourceGroup -Name $resourceGroupName -Location $location
    }
    else {
        Log "Using existing resource group '$resourceGroupName'"
    }

    Log "Deploying: '$resourceGroupName' '$templateFile' '$parametersFile'"
    New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile $templateFile -TemplateParameterFile $parametersFile
}

function Create-Files([string] $folder, [string] $newname, [string] $username) {
    if (Test-Path $newname) {
        Log "Deleting folder: '$newname'"
        rd -Recurse -Force $newname
    }

    Load-Dependencies

    Log "Copying '$folder' -> '$newname'"
    md $name | Out-Null

    $jsonfiles = @(dir $folder -r *.json)
    Log "Found $($jsonfiles.Count) json files."

    $jsonfiles | ForEach-Object {
        [string] $newfile = Join-Path (pwd).Path $newname $_.Name

        Update-JsonFile $_.FullName $newfile $newname
    }


    [string] $filename = Join-Path (pwd).Path $newname "parameters.json"

    Update-CredentialsInParametersFile $filename $username
    Update-IpAddressInParametersFile $filename
}

function Update-JsonFile([string] $infile, [string] $outfile, [string] $newname) {
    [string] $oldname = "REPLACE_NAME"

    Log "Reading: '$infile'" Magenta
    [string] $content = [IO.File]::ReadAllText($infile)

    [string] $content = $content.Replace($oldname, $newname)

    Log "Prettifying: '$infile' -> '$outfile'" Magenta
    [string] $pretty = [Newtonsoft.Json.Linq.JToken]::Parse($content).ToString([Newtonsoft.Json.Formatting]::Indented)

    Log "Saving: '$outfile'"
    [IO.File]::WriteAllText($outfile, $pretty)
}

function Update-CredentialsInParametersFile([string] $filename, [string] $username) {
    Log "Reading: '$filename'"
    [string] $content = [IO.File]::ReadAllText($filename)

    $json = [Newtonsoft.Json.Linq.JToken]::Parse($content)

    $elements = @($json.parameters.Children() | ? { $_.Name.ToLower().EndsWith("username") })

    if ($elements) {
        $elements | ForEach-Object {
            $_.value.value = $username
        }

        Log "Saving: '$filename'"
        [string] $content = $json.ToString([Newtonsoft.Json.Formatting]::Indented)
        [IO.File]::WriteAllText($filename, $content)
    }

    $elements = @($json.parameters.Children() | ? { $_.Name.ToLower().EndsWith("password") })

    if ($elements) {
        $elements | ForEach-Object {
            $_.value.value = Generate-AlphanumericPassword 24
        }

        Log "Saving: '$filename'"
        [string] $content = $json.ToString([Newtonsoft.Json.Formatting]::Indented)
        [IO.File]::WriteAllText($filename, $content)
    }
}

function Generate-AlphanumericPassword([int] $numberOfChars) {
    [char[]] $validChars = 'a'..'z' + 'A'..'Z' + [char]'0'..[char]'9'
    [string] $password = ""
    do {
        [string] $password = (1..$numberOfChars | ForEach-Object { $validChars[(Get-Random -Maximum $validChars.Length)] }) -join ""
    }
    while (
        !($password | ? { ($_.ToCharArray() | ? { [Char]::IsUpper($_) }) }) -or
        !($password | ? { ($_.ToCharArray() | ? { [Char]::IsLower($_) }) }) -or
        !($password | ? { ($_.ToCharArray() | ? { [Char]::IsDigit($_) }) }));

    return $password
}

function Update-IpAddressInParametersFile([string] $filename) {
    Log "Reading: '$filename'"
    [string] $content = [IO.File]::ReadAllText($filename)

    $json = [Newtonsoft.Json.Linq.JToken]::Parse($content)

    $elements = @($json.parameters.Descendants() | ? { ($_.GetType().Name -eq "JProperty") -and ($_.Name -eq "sourceAddressPrefix" -or $_.Name.ToLower().EndsWith("ipaddress")) })

    if ($elements) {
        Log "Retrieving public ip address."
        $ip = Invoke-RestMethod -Uri "https://api.ipify.org?format=json"

        Log "Got public ip address: $($ip.ip)"

        $elements | ForEach-Object {
            $_.value.value = $ip.ip
        }

        Log "Saving: '$filename'"
        [string] $content = $json.ToString([Newtonsoft.Json.Formatting]::Indented)
        [IO.File]::WriteAllText($filename, $content)
    }
}

function Load-Dependencies() {
    [string] $nugetpkg = "https://www.nuget.org/api/v2/package/Newtonsoft.Json/12.0.3"
    [string] $zipfile = Join-Path ([IO.Path]::GetTempPath()) "json.zip"
    [string] $dllfolder = Join-Path ([IO.Path]::GetTempPath()) "jsondll"
    [string] $dllfile = Join-Path ([IO.Path]::GetTempPath()) "jsondll" "lib" "netstandard2.0" "Newtonsoft.Json.dll"

    [string] $hash = "99177A4CBE03625768D64A3D73392310372888F74C3EB271CF775E93057A38E6"
    if ((Test-Path $dllfile) -and (Get-FileHash $dllfile).Hash -eq $hash) {
        Log "File already downloaded: '$dllfile'"
    }
    else {
        Log "Downloading: '$nugetpkg' -> '$zipfile'"
        Invoke-WebRequest -UseBasicParsing $nugetpkg -OutFile $zipfile
        if (!(Test-Path $zipfile)) {
            Log "Couldn't download: '$zipfile'" Red
            exit 1
        }

        Log "Extracting: '$zipfile' -> '$dllfolder'"
        Expand-Archive $zipfile $dllfolder

        if (!(Test-Path $dllfile)) {
            Log "Couldn't extract: '$dllfile'" Red
            exit 1
        }

        Log "Deleting file: '$zipfile'"
        del $zipfile
    }

    if (Get-FileHash $dllfile) {
    }
    
    Log "Loading assembly: '$dllfile'"
    Import-Module $dllfile | Out-Null
}

function Log([string] $message, $color) {
    [string] $date = [DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss")
    if ($color) {
        Write-Host ($date + ": " + $message) -f $color
    }
    else {
        Write-Host ($date + ": " + $message) -f Green
    }
}

Main $args
