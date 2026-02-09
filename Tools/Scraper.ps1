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

# Set the URL of the website to scrape
$url = ""

# Set the regular expression to match video file links
$regex = '([^"]*\.(mp4|avi|wmv))'

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

# Extract the links to the video files
$links = $html.Links | Where-Object { $_.href -match $regex } | Select-Object -ExpandProperty href
Write-Log ("Found {0} top-level video links" -f $links.Count)

# Loop through the links and download each video file
foreach ($link in $links) {
    Write-Log ("Following link {0}" -f $link)
    $subpageStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $subpage = Invoke-WebRequest -Uri $link

    $sources = $subpage.Links | Where-Object { $_.href -match $regex } | Select-Object -ExpandProperty href
    Write-Log ("Subpage exposed {0} candidate sources" -f $sources.Count) 'DEBUG'

    $sources | ForEach-Object {
        $currentSrc = $subpage.ParsedHtml.getElementById('player').currentSrc
        if ([string]::IsNullOrWhiteSpace($currentSrc)) {
            Write-Log 'Player source was empty, skipping.' 'WARN'
            return
        }

        $filename = [System.IO.Path]::GetFileName($currentSrc)
        $filepath = Join-Path -Path $path -ChildPath $filename

        if (Test-Path $filepath) {
            Write-Log ("Skipping existing file {0}" -f $filename) 'DEBUG'
            $skippedCount++
            return
        }

        Write-Log ("Downloading {0}" -f $currentSrc)
        $downloadStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            Invoke-WebRequest -Uri $currentSrc -OutFile $filepath -ErrorAction Stop | Out-Null
            $downloadStopwatch.Stop()
            $downloadCount++
            $sizeMb = if (Test-Path $filepath) { (Get-Item $filepath).Length / 1MB } else { 0 }
            Write-Log (
                "Saved {0} in {1:N2}s ({2:N2} MB)" -f 
                $filename,
                $downloadStopwatch.Elapsed.TotalSeconds,
                $sizeMb
            ) 'SUCCESS'
        }
        catch {
            $downloadStopwatch.Stop()
            Write-Log ("Failed to download {0}: {1}" -f $currentSrc, $_.Exception.Message) 'ERROR'
        }
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