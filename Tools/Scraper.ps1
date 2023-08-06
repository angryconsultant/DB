# Set the URL of the website to scrape
$url = ""

# Set the regular expression to match video file links
$regex = '([^"]*\.(mp4|avi|wmv))'

# Set the path to save the downloaded video files
$path = "C:\Users\daniel\Downloads\x"

# Create the directory if it doesn't exist
New-Item -ItemType Directory -Path $path -Force | Out-Null

# Request the HTML content of the website
$html = Invoke-WebRequest -Uri $url

# Extract the links to the video files
$links = $html.Links | Where-Object { $_.href -match $regex } | Select-Object -ExpandProperty href

# Loop through the links and download each video file
foreach ($link in $links) {
    Write-Host "Following link $link..."
    $subpage = Invoke-WebRequest -Uri $link

    ($subpage.Links | Where-Object { $_.href -match $regex } | Select-Object -ExpandProperty href) | ForEach-Object {
        $currentSrc = $subpage.ParsedHtml.getElementById("player").currentSrc
        Write-Host "Downloading $currentSrc..."
        
        $filename = [System.IO.Path]::GetFileName($currentSrc)
        $filepath = Join-Path -Path $path -ChildPath $filename
        
        if (![string]::IsNullOrEmpty($currentSrc) -and !(Test-Path $filepath)) {
            Invoke-WebRequest -Uri $currentSrc -OutFile $filepath
        }
    }

}

Write-Host "Finished downloading videos."