# Basic timestamped logging so it's easier to follow progress
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
        'DEBUG'   { 'Cyan' }
        default   { 'White' }
    }

    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
}

# Decrypt the video URL returned by the API
function Get-VideoUrl {
    param(
        [string]$EncryptedUrl,
        [long]$Timestamp
    )

    $key = "SECRET_KEY_" + [Math]::Floor($Timestamp / 3600)
    $encBytes = [Convert]::FromBase64String($EncryptedUrl)
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($key)
    $result = [byte[]]::new($encBytes.Length)
    for ($i = 0; $i -lt $encBytes.Length; $i++) {
        $result[$i] = $encBytes[$i] -bxor $keyBytes[$i % $keyBytes.Length]
    }
    return [System.Text.Encoding]::UTF8.GetString($result)
}

# Set the URL of the website to scrape
$url = "https://example.com/videos"
$baseUri = [System.Uri]$url
$apiUrl = "$($baseUri.Scheme)://$($baseUri.Host)/api/vs"

# Set the path to save the downloaded video files
$path = "C:\Users\DanielBjörk\Downloads\x"

Write-Log "Preparing to scrape $url"
Write-Log "Ensuring download directory exists at $path" 'DEBUG'

# Create the directory if it doesn't exist
New-Item -ItemType Directory -Path $path -Force | Out-Null

$overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$downloadCount = 0
$skippedCount = 0

Write-Log 'Requesting main page HTML'
# Request the HTML content of the website
$html = Invoke-WebRequest -Uri $url

# Extract file links: match /f/ paths (covers both named files and short IDs)
$links = $html.Links | Where-Object { $_.href -match '^/f/' } | Select-Object -ExpandProperty href | Select-Object -Unique
Write-Log ("Found {0} top-level file links" -f $links.Count)

# Loop through the links and download each video file
foreach ($link in $links) {
    Write-Log ("Following link {0}" -f $link)
    $subpageStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $absoluteLink = ([System.Uri]::new($baseUri, $link)).AbsoluteUri

    try {
        $subpage = Invoke-WebRequest -Uri $absoluteLink -ErrorAction Stop
    }
    catch {
        Write-Log ("Subpage not found or error for {0}: {1}" -f $link, $_.Exception.Message) 'WARN'
        $subpageStopwatch.Stop()
        Write-Log ("Finished processing {0} in {1:N2}s" -f $link, $subpageStopwatch.Elapsed.TotalSeconds) 'DEBUG'
        continue
    }

    # Get slug from jsSlug variable
    $slugMatch = [regex]::Match($subpage.Content, "var\s+jsSlug\s*=\s*'([^']+)'")
    if (-not $slugMatch.Success) {
        Write-Log 'Could not find jsSlug on subpage, skipping.' 'WARN'
        $subpageStopwatch.Stop()
        Write-Log ("Finished processing {0} in {1:N2}s" -f $link, $subpageStopwatch.Elapsed.TotalSeconds) 'DEBUG'
        continue
    }

    $slug = $slugMatch.Groups[1].Value

    # Call the API to get the encrypted video source URL
    try {
        $body = @{ slug = $slug } | ConvertTo-Json
        $apiResponse = Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $body
    }
    catch {
        Write-Log ("API call failed for {0}: {1}" -f $slug, $_.Exception.Message) 'ERROR'
        $subpageStopwatch.Stop()
        Write-Log ("Finished processing {0} in {1:N2}s" -f $link, $subpageStopwatch.Elapsed.TotalSeconds) 'DEBUG'
        continue
    }

    if (-not $apiResponse.url) {
        Write-Log ("API returned no URL for {0}" -f $slug) 'WARN'
        $subpageStopwatch.Stop()
        Write-Log ("Finished processing {0} in {1:N2}s" -f $link, $subpageStopwatch.Elapsed.TotalSeconds) 'DEBUG'
        continue
    }

    # Decrypt the video URL and derive the filename from the page title (proper name)
    $videoUrl = Get-VideoUrl -EncryptedUrl $apiResponse.url -Timestamp $apiResponse.timestamp
    Write-Log ("Resolved CDN URL: {0}" -f $videoUrl) 'DEBUG'

    # Get proper filename from og:title, fall back to h1, then CDN URL
    $nameMatch = [regex]::Match($subpage.Content, '<meta\s+property="og:title"\s+content="([^"]+)"')
    if (-not $nameMatch.Success) {
        $nameMatch = [regex]::Match($subpage.Content, '<h1[^>]*>([^<]+)</h1>')
    }
    if ($nameMatch.Success) {
        $filename = $nameMatch.Groups[1].Value.Trim()
        # Ensure it has an extension; if not, take it from the CDN URL
        if (-not [System.IO.Path]::GetExtension($filename)) {
            $cdnExt = [System.IO.Path]::GetExtension([System.Uri]::new($videoUrl).LocalPath)
            $filename = $filename + $cdnExt
        }
    }
    else {
        $filename = [System.IO.Path]::GetFileName([System.Uri]::new($videoUrl).LocalPath)
    }
    $filepath = Join-Path -Path $path -ChildPath $filename

    if (Test-Path -LiteralPath $filepath) {
        Write-Log ("Skipping existing file {0}" -f $filename) 'DEBUG'
        $skippedCount++
        $subpageStopwatch.Stop()
        Write-Log ("Finished processing {0} in {1:N2}s" -f $link, $subpageStopwatch.Elapsed.TotalSeconds) 'DEBUG'
        continue
    }

    Write-Log ("Downloading {0}" -f $filename)
    $downloadStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        Invoke-WebRequest -Uri $videoUrl -OutFile $filepath -ErrorAction Stop | Out-Null
        $downloadStopwatch.Stop()
        $downloadCount++
        $sizeMb = if (Test-Path -LiteralPath $filepath) { (Get-Item -LiteralPath $filepath).Length / 1MB } else { 0 }
        Write-Log (
            "Saved {0} in {1:N2}s ({2:N2} MB)" -f 
            $filename,
            $downloadStopwatch.Elapsed.TotalSeconds,
            $sizeMb
        ) 'SUCCESS'
    }
    catch {
        $downloadStopwatch.Stop()
        Write-Log ("Failed to download {0}: {1}" -f $videoUrl, $_.Exception.Message) 'ERROR'
    }

    $subpageStopwatch.Stop()
    Write-Log ("Finished processing {0} in {1:N2}s" -f $link, $subpageStopwatch.Elapsed.TotalSeconds) 'DEBUG'
}

$overallStopwatch.Stop()
Write-Log (
    "Finished downloading videos. New files: {0}, skipped: {1}, total duration: {2}" -f 
    $downloadCount,
    $skippedCount,
    $overallStopwatch.Elapsed.ToString()
)