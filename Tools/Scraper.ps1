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

# Download all videos from an erome.com album page.
# Video source URLs are embedded directly in the HTML as <source src="...">.
# Erome requires a Referer header matching the site origin.
function Invoke-EromeScraper {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DownloadPath
    )

    $baseUri = [System.Uri]$Url
    $referer = "$($baseUri.Scheme)://$($baseUri.Host)"

    Write-Log "Preparing to scrape erome album $Url"
    New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null

    $overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $downloadCount = 0
    $skippedCount = 0

    Write-Log 'Requesting album page HTML'
    try {
        $html = Invoke-WebRequest -Uri $Url -Headers @{ Referer = $referer } -ErrorAction Stop
    }
    catch {
        Write-Log ("Failed to fetch album page: {0}" -f $_.Exception.Message) 'ERROR'
        return
    }

    # Extract album title for subfolder / naming
    $titleMatch = [regex]::Match($html.Content, '<h1[^>]*class="album-title-page"[^>]*>([^<]+)</h1>')
    $albumTitle = if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim() } else { 'erome_album' }
    Write-Log ("Album title: {0}" -f $albumTitle)

    # Sanitise title for filesystem use
    $safeTitle = ($albumTitle -replace '[\\/:*?"<>|]', '_').Trim()

    # Extract all video source URLs from <source src="..."> inside <video> tags
    $videoUrls = [regex]::Matches($html.Content, '<source\s+src="([^"]+\.mp4)"') |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique

    if ($videoUrls.Count -eq 0) {
        Write-Log 'No video sources found on this album page.' 'WARN'
        return
    }

    Write-Log ("Found {0} video(s) to download" -f $videoUrls.Count)

    $index = 0
    foreach ($videoUrl in $videoUrls) {
        $index++
        # Derive filename: albumTitle_01.mp4, albumTitle_02.mp4, …
        $ext = [System.IO.Path]::GetExtension([System.Uri]::new($videoUrl).LocalPath)
        if (-not $ext) { $ext = '.mp4' }
        $filename = if ($videoUrls.Count -eq 1) {
            "$safeTitle$ext"
        } else {
            "{0}_{1:D2}{2}" -f $safeTitle, $index, $ext
        }
        $filepath = Join-Path -Path $DownloadPath -ChildPath $filename

        if (Test-Path -LiteralPath $filepath) {
            Write-Log ("Skipping existing file {0}" -f $filename) 'DEBUG'
            $skippedCount++
            continue
        }

        Write-Log ("Downloading {0} ({1}/{2})" -f $filename, $index, $videoUrls.Count)
        $dlStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            Invoke-WebRequest -Uri $videoUrl -OutFile $filepath -Headers @{
                Referer    = $referer
                Origin     = $referer
            } -ErrorAction Stop | Out-Null
            $dlStopwatch.Stop()
            $downloadCount++
            $sizeMb = if (Test-Path -LiteralPath $filepath) { (Get-Item -LiteralPath $filepath).Length / 1MB } else { 0 }
            Write-Log ("Saved {0} in {1:N2}s ({2:N2} MB)" -f $filename, $dlStopwatch.Elapsed.TotalSeconds, $sizeMb) 'SUCCESS'
        }
        catch {
            $dlStopwatch.Stop()
            Write-Log ("Failed to download {0}: {1}" -f $videoUrl, $_.Exception.Message) 'ERROR'
        }
    }

    $overallStopwatch.Stop()
    Write-Log (
        "Erome finished. New files: {0}, skipped: {1}, total duration: {2}" -f
        $downloadCount, $skippedCount, $overallStopwatch.Elapsed.ToString()
    )
}

# Download videos from the original site using API + decryption
function Invoke-DefaultScraper {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DownloadPath
    )

    $baseUri = [System.Uri]$Url
    $apiUrl = "$($baseUri.Scheme)://$($baseUri.Host)/api/vs"

    Write-Log "Preparing to scrape $Url"
    New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null

    $overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $downloadCount = 0
    $skippedCount = 0
    $seenFilenames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Fetch page 1 to discover pagination
    Write-Log 'Requesting page 1 HTML'
    $html = Invoke-WebRequest -Uri $Url

    # Detect last page from pagination nav (e.g. href="?page=5")
    $pageMatches = [regex]::Matches($html.Content, 'href="\?page=(\d+)"')
    $lastPage = 1
    foreach ($m in $pageMatches) {
        $pageNum = [int]$m.Groups[1].Value
        if ($pageNum -gt $lastPage) { $lastPage = $pageNum }
    }

    if ($lastPage -gt 1) {
        Write-Log ("Detected {0} pages of content" -f $lastPage)
    }

    # Collect /f/ links from all pages
    $allLinks = [System.Collections.Generic.List[string]]::new()

    # Page 1 links (already fetched)
    $html.Links | Where-Object { $_.href -match '^/f/' } | ForEach-Object { $allLinks.Add($_.href) }
    Write-Log ("Page 1: found {0} file links" -f $allLinks.Count)

    # Fetch remaining pages
    for ($page = 2; $page -le $lastPage; $page++) {
        $separator = if ($Url.Contains('?')) { '&' } else { '?' }
        $pageUrl = "{0}{1}page={2}" -f $Url, $separator, $page
        Write-Log ("Requesting page {0}/{1}" -f $page, $lastPage)
        try {
            $pageHtml = Invoke-WebRequest -Uri $pageUrl -ErrorAction Stop
            $pageLinks = $pageHtml.Links | Where-Object { $_.href -match '^/f/' } | Select-Object -ExpandProperty href
            $countBefore = $allLinks.Count
            foreach ($pl in $pageLinks) { $allLinks.Add($pl) }
            Write-Log ("Page {0}: found {1} file links" -f $page, ($allLinks.Count - $countBefore))
        }
        catch {
            Write-Log ("Failed to fetch page {0}: {1}" -f $page, $_.Exception.Message) 'ERROR'
        }
    }

    $links = $allLinks | Select-Object -Unique
    Write-Log ("Found {0} total unique file links across {1} page(s)" -f $links.Count, $lastPage)

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

        $slugMatch = [regex]::Match($subpage.Content, "var\s+jsSlug\s*=\s*'([^']+)'")
        if (-not $slugMatch.Success) {
            Write-Log 'Could not find jsSlug on subpage, skipping.' 'WARN'
            $subpageStopwatch.Stop()
            Write-Log ("Finished processing {0} in {1:N2}s" -f $link, $subpageStopwatch.Elapsed.TotalSeconds) 'DEBUG'
            continue
        }

        $slug = $slugMatch.Groups[1].Value

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

        $videoUrl = Get-VideoUrl -EncryptedUrl $apiResponse.url -Timestamp $apiResponse.timestamp
        Write-Log ("Resolved CDN URL: {0}" -f $videoUrl) 'DEBUG'

        $nameMatch = [regex]::Match($subpage.Content, '<meta\s+property="og:title"\s+content="([^"]+)"')
        if (-not $nameMatch.Success) {
            $nameMatch = [regex]::Match($subpage.Content, '<h1[^>]*>([^<]+)</h1>')
        }
        if ($nameMatch.Success) {
            $filename = $nameMatch.Groups[1].Value.Trim()
            if (-not [System.IO.Path]::GetExtension($filename)) {
                $cdnExt = [System.IO.Path]::GetExtension([System.Uri]::new($videoUrl).LocalPath)
                $filename = $filename + $cdnExt
            }
        }
        else {
            $filename = [System.IO.Path]::GetFileName([System.Uri]::new($videoUrl).LocalPath)
        }
        $filepath = Join-Path -Path $DownloadPath -ChildPath $filename

        if (-not $seenFilenames.Add($filename)) {
            Write-Log ("Skipping duplicate filename {0}" -f $filename) 'DEBUG'
            $skippedCount++
            $subpageStopwatch.Stop()
            Write-Log ("Finished processing {0} in {1:N2}s" -f $link, $subpageStopwatch.Elapsed.TotalSeconds) 'DEBUG'
            continue
        }

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
                $filename, $downloadStopwatch.Elapsed.TotalSeconds, $sizeMb
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
        $downloadCount, $skippedCount, $overallStopwatch.Elapsed.ToString()
    )
}

# ── Main ──────────────────────────────────────────────────────────────────────
# Set the URL of the website to scrape
$url = "https://example.com/"  # <-- Change this to the actual URL you want to scrape

# Set the path to save the downloaded video files
$path = "C:\Users\DanielBjörk\Downloads\x"

Write-Log "Ensuring download directory exists at $path" 'DEBUG'
New-Item -ItemType Directory -Path $path -Force | Out-Null

# Route to the correct scraper based on the URL
if ($url -match 'erome\.com/') {
    Invoke-EromeScraper -Url $url -DownloadPath $path
}
else {
    Invoke-DefaultScraper -Url $url -DownloadPath $path
}