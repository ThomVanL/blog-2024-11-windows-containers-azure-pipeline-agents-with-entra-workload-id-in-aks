function Print-Header ($header) {
  Write-Host "`n${header}`n" -ForegroundColor Cyan
}

if (-not (Test-Path Env:AZP_URL)) {
  Write-Error "error: missing AZP_URL environment variable"
  exit 1
}

# Fetch an Azure DevOps access token and
# write it to environment variable AZP_TOKEN

if (-not (Test-Path Env:AZURE_FEDERATED_TOKEN_FILE)) {
  Write-Error "error: missing AZURE_FEDERATED_TOKEN_FILE environment variable"
  exit 1
}

$identity_token = Get-Content -Path $env:AZURE_FEDERATED_TOKEN_FILE
$token_response = Invoke-RestMethod -Method POST `
  -UseBasicParsing `
  -Uri ("{0}{1}/oauth2/v2.0/token" -f $env:AZURE_AUTHORITY_HOST, $env:AZURE_TENANT_ID) `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{
    grant_type            = "client_credentials"
    client_id             = $env:AZURE_CLIENT_ID
    scope                 = "499b84ac-1321-427f-aa17-267ca6975798/.default"
    client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    client_assertion      = $identity_token
  }
$env:AZP_TOKEN = $token_response.access_token

if (-not (Test-Path Env:AZP_TOKEN_FILE)) {
  if (-not (Test-Path Env:AZP_TOKEN)) {
    Write-Error "error: missing AZP_TOKEN environment variable"
    exit 1
  }

  $Env:AZP_TOKEN_FILE = "\azp\.token"
  $Env:AZP_TOKEN | Out-File -FilePath $Env:AZP_TOKEN_FILE
}

Remove-Item Env:AZP_TOKEN

if ((Test-Path Env:AZP_WORK) -and -not (Test-Path $Env:AZP_WORK)) {
  New-Item $Env:AZP_WORK -ItemType directory | Out-Null
}

New-Item "\azp\agent" -ItemType directory | Out-Null

# Let the agent ignore the token env variables
$Env:VSO_AGENT_IGNORE = "AZP_TOKEN,AZP_TOKEN_FILE"

Set-Location agent

Print-Header "1. Determining matching Azure Pipelines agent..."

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$(Get-Content ${Env:AZP_TOKEN_FILE})"))
$package = Invoke-RestMethod -Headers @{Authorization = ("Basic $base64AuthInfo") } "$(${Env:AZP_URL})/_apis/distributedtask/packages/agent?platform=win-x64&`$top=1"
$packageUrl = $package[0].Value.downloadUrl

Write-Host $packageUrl

Print-Header "2. Downloading and installing Azure Pipelines agent..."

$wc = New-Object System.Net.WebClient
$wc.DownloadFile($packageUrl, "$(Get-Location)\agent.zip")

Expand-Archive -Path "agent.zip" -DestinationPath "\azp\agent"

try {
  Print-Header "3. Configuring Azure Pipelines agent..."

  .\config.cmd --unattended --agent "$(if (Test-Path Env:AZP_AGENT_NAME) { ${Env:AZP_AGENT_NAME} } else { hostname })" --url "$(${Env:AZP_URL})" --auth PAT --token "$(Get-Content ${Env:AZP_TOKEN_FILE})" --pool "$(if (Test-Path Env:AZP_POOL) { ${Env:AZP_POOL} } else { 'Default' })" --work "$(if (Test-Path Env:AZP_WORK) { ${Env:AZP_WORK} } else { '_work' })" --replace

  Print-Header "4. Running Azure Pipelines agent..."

  .\run.cmd --once
}
finally {
  Print-Header "Cleanup. Removing Azure Pipelines agent..."

  .\config.cmd remove --unattended --auth PAT --token "$(Get-Content ${Env:AZP_TOKEN_FILE})"
}