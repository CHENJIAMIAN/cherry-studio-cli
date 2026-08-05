[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('models', 'ask', 'request')]
    [string]$Command,

    [string]$Value,
    [string]$Model,
    [string]$System,
    [Parameter(Mandatory)]
    [string]$BaseUrl,
    [string]$BodyFile,
    [string]$RequestJson,
    [ValidateSet('chat', 'anthropic', 'responses')]
    [string]$Format = 'chat',
    [ValidateRange(1, 1000000)]
    [int]$MaxTokens = 1024,
    [switch]$Stream,
    [switch]$Json,
    [string]$ProviderAliasesJson = '{}'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:CHERRY_STUDIO_API_KEY)) {
    throw 'CHERRY_STUDIO_API_KEY was not injected into the request process.'
}

$base = $BaseUrl.TrimEnd('/')
$headers = @{
    Authorization = "Bearer $($env:CHERRY_STUDIO_API_KEY)"
    Accept = 'application/json'
}

function Get-ProviderAliases {
    if ([string]::IsNullOrWhiteSpace($ProviderAliasesJson)) {
        return @{}
    }

    try {
        $parsed = $ProviderAliasesJson | ConvertFrom-Json -AsHashtable -Depth 32
    }
    catch {
        throw 'Provider aliases are not valid JSON.'
    }
    if ($null -eq $parsed) {
        return @{}
    }

    $result = @{}
    foreach ($entry in $parsed.GetEnumerator()) {
        $key = [string]$entry.Key
        $value = [string]$entry.Value
        if (-not [string]::IsNullOrWhiteSpace($key) -and -not [string]::IsNullOrWhiteSpace($value)) {
            $result[$key] = $value
        }
    }
    return $result
}

$script:ProviderAliases = Get-ProviderAliases

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Convert-ContentToText {
    param([object]$Content)

    if ($null -eq $Content) {
        return ''
    }
    if ($Content -is [string]) {
        return $Content
    }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($part in @($Content)) {
        if ($part -is [string]) {
            [void]$builder.Append($part)
            continue
        }

        $text = Get-PropertyValue -Object $part -Name 'text'
        if ($null -ne $text) {
            [void]$builder.Append([string]$text)
            continue
        }

        $nested = Get-PropertyValue -Object $part -Name 'content'
        if ($null -ne $nested) {
            [void]$builder.Append((Convert-ContentToText -Content $nested))
        }
    }
    return $builder.ToString()
}

function Get-DisplayModelId {
    param([Parameter(Mandatory)][string]$RawModelId)

    $separator = $RawModelId.IndexOf(':')
    if ($separator -le 0) {
        return $RawModelId
    }

    $provider = $RawModelId.Substring(0, $separator)
    if (-not $script:ProviderAliases.ContainsKey($provider)) {
        return $RawModelId
    }

    $alias = [string]$script:ProviderAliases[$provider]
    if ([string]::IsNullOrWhiteSpace($alias)) {
        return $RawModelId
    }
    return $alias + ':' + $RawModelId.Substring($separator + 1)
}

function Resolve-ModelId {
    param([Parameter(Mandatory)][string]$RequestedModelId)

    $separator = $RequestedModelId.IndexOf(':')
    if ($separator -le 0) {
        return $RequestedModelId
    }

    $friendlyProvider = $RequestedModelId.Substring(0, $separator)
    $suffix = $RequestedModelId.Substring($separator + 1)
    $matches = @()
    foreach ($entry in $script:ProviderAliases.GetEnumerator()) {
        if ([string]$entry.Value -ieq $friendlyProvider) {
            $matches += ([string]$entry.Key + ':' + $suffix)
        }
    }

    if ($matches.Count -eq 0) {
        return $RequestedModelId
    }
    if ($matches.Count -gt 1) {
        throw "Model alias '$friendlyProvider' maps to multiple provider prefixes. Use a unique provider alias or the raw model ID."
    }
    return $matches[0]
}

function Invoke-CherryRequest {
    param(
        [ValidateSet('Get', 'Post')]
        [string]$Method,
        [string]$Path,
        [object]$Body
    )

    $params = @{
        Method = $Method
        Uri = "$base$Path"
        Headers = $headers
        TimeoutSec = 120
    }
    if ($Method -eq 'Post') {
        $params.ContentType = 'application/json'
        $params.Body = $Body | ConvertTo-Json -Depth 100 -Compress
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        throw "Cherry Studio API request failed: $($_.Exception.Message)"
    }
}

function Invoke-CherryRawRequest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BodyText,
        [switch]$StreamResponse,
        [switch]$PrettyJson
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$base$Path")
    $request.Headers.TryAddWithoutValidation('Authorization', $headers.Authorization) | Out-Null
    $accept = if ($StreamResponse) { 'text/event-stream' } else { $headers.Accept }
    $request.Headers.TryAddWithoutValidation('Accept', $accept) | Out-Null
    $request.Content = [System.Net.Http.StringContent]::new($BodyText, [System.Text.Encoding]::UTF8, 'application/json')

    try {
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $errorBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw "Cherry Studio API request failed with HTTP $([int]$response.StatusCode): $errorBody"
        }

        if ($StreamResponse) {
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
            try {
                while (($line = $reader.ReadLine()) -ne $null) {
                    [Console]::Out.WriteLine($line)
                    [Console]::Out.Flush()
                }
            }
            finally {
                $reader.Dispose()
                $stream.Dispose()
            }
            return
        }

        $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($PrettyJson) {
            try {
                $responseText | ConvertFrom-Json -Depth 100 | ConvertTo-Json -Depth 100
                return
            }
            catch {
            }
        }
        Write-Output $responseText
    }
    finally {
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-ChatText {
    param([object]$Response)

    $choice = @((Get-PropertyValue -Object $Response -Name 'choices')) | Select-Object -First 1
    $message = Get-PropertyValue -Object $choice -Name 'message'
    $content = Get-PropertyValue -Object $message -Name 'content'
    if ($null -eq $content) {
        $content = Get-PropertyValue -Object $choice -Name 'text'
    }
    return Convert-ContentToText -Content $content
}

function Convert-ChatToResponses {
    param(
        [object]$ChatResponse,
        [string]$RequestedModel
    )

    $chatId = [string](Get-PropertyValue -Object $ChatResponse -Name 'id')
    if ([string]::IsNullOrWhiteSpace($chatId)) {
        $chatId = [Guid]::NewGuid().ToString('N')
    }
    $text = Get-ChatText -Response $ChatResponse
    $usage = Get-PropertyValue -Object $ChatResponse -Name 'usage'
    $inputTokens = Get-PropertyValue -Object $usage -Name 'prompt_tokens'
    $outputTokens = Get-PropertyValue -Object $usage -Name 'completion_tokens'
    $totalTokens = Get-PropertyValue -Object $usage -Name 'total_tokens'

    return [ordered]@{
        id = 'resp_' + $chatId
        object = 'response'
        created_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        status = 'completed'
        model = $RequestedModel
        output = @(
            [ordered]@{
                id = 'msg_' + $chatId
                type = 'message'
                status = 'completed'
                role = 'assistant'
                content = @(
                    [ordered]@{
                        type = 'output_text'
                        text = $text
                        annotations = @()
                    }
                )
            }
        )
        usage = [ordered]@{
            input_tokens = if ($null -eq $inputTokens) { 0 } else { $inputTokens }
            output_tokens = if ($null -eq $outputTokens) { 0 } else { $outputTokens }
            total_tokens = if ($null -eq $totalTokens) { 0 } else { $totalTokens }
        }
    }
}

function New-ChatRequest {
    param(
        [string]$RequestedModel,
        [string]$Prompt,
        [string]$SystemPrompt,
        [switch]$UseStream
    )

    $messages = @()
    if (-not [string]::IsNullOrWhiteSpace($SystemPrompt)) {
        $messages += @{ role = 'system'; content = $SystemPrompt }
    }
    $messages += @{ role = 'user'; content = $Prompt }
    return @{
        model = (Resolve-ModelId -RequestedModelId $RequestedModel)
        messages = $messages
        max_tokens = $MaxTokens
        stream = [bool]$UseStream
    }
}

function New-AnthropicRequest {
    param(
        [string]$RequestedModel,
        [string]$Prompt,
        [string]$SystemPrompt,
        [switch]$UseStream
    )

    $body = @{
        model = (Resolve-ModelId -RequestedModelId $RequestedModel)
        max_tokens = $MaxTokens
        messages = @(@{ role = 'user'; content = $Prompt })
        stream = [bool]$UseStream
    }
    if (-not [string]::IsNullOrWhiteSpace($SystemPrompt)) {
        $body.system = $SystemPrompt
    }
    return $body
}

function New-ResponsesRequest {
    param(
        [string]$RequestedModel,
        [string]$Prompt,
        [string]$SystemPrompt,
        [switch]$UseStream
    )

    $body = @{
        model = (Resolve-ModelId -RequestedModelId $RequestedModel)
        input = @(
            @{
                role = 'user'
                content = @(
                    @{
                        type = 'input_text'
                        text = $Prompt
                    }
                )
            }
        )
        max_output_tokens = $MaxTokens
        stream = [bool]$UseStream
    }
    if (-not [string]::IsNullOrWhiteSpace($SystemPrompt)) {
        $body.instructions = $SystemPrompt
    }
    return $body
}

function Get-RequestPath {
    param([string]$RequestFormat)

    switch ($RequestFormat) {
        'anthropic' { return '/v1/messages' }
        'responses' { return '/v1/responses' }
        default { return '/v1/chat/completions' }
    }
}

function Get-RequestBodyText {
    if (-not [string]::IsNullOrWhiteSpace($BodyFile) -and -not [string]::IsNullOrWhiteSpace($RequestJson)) {
        throw 'Use either -BodyFile or -RequestJson, not both.'
    }

    $text = if (-not [string]::IsNullOrWhiteSpace($BodyFile)) {
        if ($BodyFile -eq '-') {
            [Console]::In.ReadToEnd()
        }
        else {
            if (-not (Test-Path -LiteralPath $BodyFile)) {
                throw "Request body file was not found: $BodyFile"
            }
            Get-Content -LiteralPath $BodyFile -Raw
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($RequestJson)) {
        $RequestJson
    }
    else {
        throw 'A complete request requires -BodyFile, -BodyFile -, or -RequestJson.'
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'The request body is empty.'
    }
    return $text
}

function ConvertTo-NormalizedRequest {
    param(
        [Parameter(Mandatory)][string]$BodyText,
        [string]$OverrideModel,
        [switch]$ForceStream
    )

    try {
        $body = $BodyText | ConvertFrom-Json -AsHashtable -Depth 100
    }
    catch {
        throw "Request body is not valid JSON: $($_.Exception.Message)"
    }
    if ($body -isnot [System.Collections.IDictionary]) {
        throw 'The request body must be a JSON object.'
    }

    if (-not [string]::IsNullOrWhiteSpace($OverrideModel)) {
        $body.model = Resolve-ModelId -RequestedModelId $OverrideModel
    }
    elseif ($body.Contains('model') -and -not [string]::IsNullOrWhiteSpace([string]$body.model)) {
        $body.model = Resolve-ModelId -RequestedModelId ([string]$body.model)
    }

    if ($ForceStream) {
        $body.stream = $true
    }

    return $body
}

function Invoke-FullRequest {
    param(
        [string]$RequestFormat,
        [string]$OverrideModel,
        [switch]$ForceStream,
        [switch]$PrettyJson
    )

    $rawBody = Get-RequestBodyText
    $body = ConvertTo-NormalizedRequest -BodyText $rawBody -OverrideModel $OverrideModel -ForceStream:$ForceStream
    $streamRequested = $ForceStream -or ($body.Contains('stream') -and [bool]$body.stream)
    $bodyText = $body | ConvertTo-Json -Depth 100 -Compress
    try {
        Invoke-CherryRawRequest -Path (Get-RequestPath -RequestFormat $RequestFormat) -BodyText $bodyText -StreamResponse:$streamRequested -PrettyJson:$PrettyJson
    }
    catch {
        if ($RequestFormat -eq 'responses' -and $_.Exception.Message -match 'HTTP 404') {
            throw 'Cherry Studio local API Server does not expose /v1/responses. cherry request always targets the configured Cherry Studio base URL and does not switch to CLIProxyAPI automatically. Run cherry connect, then call the CLIProxyAPI /v1/responses endpoint with its CLIPROXY_API_KEY and a slash-separated proxy model ID for full Responses API support.'
        }
        throw
    }
}

function Write-Models {
    $response = Invoke-CherryRequest -Method Get -Path '/v1/models'
    $models = @($response.data)
    if ($models.Count -eq 0) {
        Write-Output 'No models are currently exposed by the Cherry Studio API Server.'
        return
    }

    $decoratedModels = @()
    foreach ($item in $models | Sort-Object -Property id) {
        $rawId = [string]$item.id
        $displayId = Get-DisplayModelId -RawModelId $rawId
        $copy = [ordered]@{}
        foreach ($property in $item.PSObject.Properties) {
            $copy[$property.Name] = $property.Value
        }
        $copy.alias = $displayId
        $decoratedModels += [PSCustomObject]$copy
    }

    if ($Json) {
        $result = [ordered]@{}
        foreach ($property in $response.PSObject.Properties) {
            if ($property.Name -ne 'data') {
                $result[$property.Name] = $property.Value
            }
        }
        $result.data = $decoratedModels
        $result | ConvertTo-Json -Depth 32
        return
    }

    foreach ($item in $decoratedModels) {
        $name = if ([string]::IsNullOrWhiteSpace([string]$item.name)) { [string]$item.id } else { [string]$item.name }
        Write-Output ("{0}{1}{2}" -f $item.alias, [char]9, $name)
    }
}

switch ($Command) {
    'models' {
        Write-Models
        break
    }
    'request' {
        Invoke-FullRequest -RequestFormat $Format -OverrideModel $Model -ForceStream:$Stream -PrettyJson:$Json
        break
    }
    'ask' {
        if (-not [string]::IsNullOrWhiteSpace($BodyFile) -or -not [string]::IsNullOrWhiteSpace($RequestJson)) {
            Invoke-FullRequest -RequestFormat $Format -OverrideModel $Model -ForceStream:$Stream -PrettyJson:$Json
            break
        }
        if ([string]::IsNullOrWhiteSpace($Model)) {
            throw 'A model ID is required.'
        }
        if ([string]::IsNullOrWhiteSpace($Value)) {
            throw 'A prompt is required.'
        }

        switch ($Format) {
            'anthropic' {
                $body = New-AnthropicRequest -RequestedModel $Model -Prompt $Value -SystemPrompt $System -UseStream:$Stream
                if ($Stream) {
                    $bodyText = $body | ConvertTo-Json -Depth 100 -Compress
                    Invoke-CherryRawRequest -Path '/v1/messages' -BodyText $bodyText -StreamResponse -PrettyJson:$Json
                }
                else {
                    $response = Invoke-CherryRequest -Method Post -Path '/v1/messages' -Body $body
                    if ($Json) {
                        $response | ConvertTo-Json -Depth 32
                    }
                    else {
                        Write-Output (Convert-ContentToText -Content $response.content)
                    }
                }
                break
            }
            'responses' {
                $body = New-ResponsesRequest -RequestedModel $Model -Prompt $Value -SystemPrompt $System -UseStream:$Stream
                if ($Stream) {
                    $bodyText = $body | ConvertTo-Json -Depth 100 -Compress
                    Invoke-CherryRawRequest -Path '/v1/responses' -BodyText $bodyText -StreamResponse -PrettyJson:$Json
                    break
                }

                try {
                    $response = Invoke-CherryRequest -Method Post -Path '/v1/responses' -Body $body
                }
                catch {
                    if ($_.Exception.Message -notmatch '404') {
                        throw
                    }
                    $chatResponse = Invoke-CherryRequest -Method Post -Path '/v1/chat/completions' -Body (New-ChatRequest -RequestedModel $Model -Prompt $Value -SystemPrompt $System)
                    $response = Convert-ChatToResponses -ChatResponse $chatResponse -RequestedModel (Resolve-ModelId -RequestedModelId $Model)
                }

                if ($Json) {
                    $response | ConvertTo-Json -Depth 32
                }
                else {
                    $output = Get-PropertyValue -Object $response -Name 'output'
                    $content = Get-PropertyValue -Object (@($output) | Select-Object -First 1) -Name 'content'
                    Write-Output (Convert-ContentToText -Content $content)
                }
                break
            }
            default {
                $body = New-ChatRequest -RequestedModel $Model -Prompt $Value -SystemPrompt $System -UseStream:$Stream
                if ($Stream) {
                    $bodyText = $body | ConvertTo-Json -Depth 100 -Compress
                    Invoke-CherryRawRequest -Path '/v1/chat/completions' -BodyText $bodyText -StreamResponse -PrettyJson:$Json
                }
                else {
                    $response = Invoke-CherryRequest -Method Post -Path '/v1/chat/completions' -Body $body
                    if ($Json) {
                        $response | ConvertTo-Json -Depth 32
                    }
                    else {
                        Write-Output (Get-ChatText -Response $response)
                    }
                }
                break
            }
        }
        break
    }
}
