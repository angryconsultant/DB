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

# Parse mega.nz folder URL to extract folder ID and decryption key
function Get-MegaFolderInfo {
    param(
        [Parameter(Mandatory)][string]$Url
    )

    # Mega folder URL format: https://mega.nz/folder/{folderID}#{decryptionKey}
    # or: https://mega.nz/#F!{folderID}!{decryptionKey}
    $match = [regex]::Match($Url, 'mega\.nz/folder/([a-zA-Z0-9_-]{8})#([a-zA-Z0-9_-]+)')
    if (-not $match.Success) {
        $match = [regex]::Match($Url, 'mega\.nz/#F!([a-zA-Z0-9_-]{8})!([a-zA-Z0-9_-]+)')
    }

    if (-not $match.Success) {
        Write-Log "Invalid mega.nz folder URL format: $Url" 'ERROR'
        return $null
    }

    return @{
        FolderId = $match.Groups[1].Value
        Key      = $match.Groups[2].Value
    }
}

# Convert Base64URL to standard Base64
function ConvertFrom-Base64Url {
    param([Parameter(Mandatory)][string]$Base64Url)
    
    $base64 = $Base64Url.Replace('-', '+').Replace('_', '/')
    # Add padding if needed
    $mod = $base64.Length % 4
    if ($mod -gt 0) {
        $base64 += '=' * (4 - $mod)
    }
    return $base64
}

# Decrypt mega.nz AES-encrypted data
function Invoke-MegaAesDecrypt {
    param(
        [Parameter(Mandatory)][byte[]]$Data,
        [Parameter(Mandatory)][byte[]]$Key,
        [byte[]]$IV = $null
    )

    if ($null -eq $IV -or $IV.Length -eq 0) {
        $IV = [byte[]]::new(16)  # Zero IV
    }

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
    $aes.KeySize = 128
    $aes.Key = $Key
    $aes.IV = $IV

    $decryptor = $aes.CreateDecryptor()
    $result = $decryptor.TransformFinalBlock($Data, 0, $Data.Length)
    
    $aes.Dispose()
    return $result
}

# Decrypt mega.nz file/folder attributes (JSON)
function Get-MegaDecryptedAttributes {
    param(
        [Parameter(Mandatory)][string]$EncryptedAttributes,
        [Parameter(Mandatory)][byte[]]$Key
    )

    try {
        $base64 = ConvertFrom-Base64Url -Base64Url $EncryptedAttributes
        $encryptedBytes = [Convert]::FromBase64String($base64)
        
        # Decrypt the attributes
        $decryptedBytes = Invoke-MegaAesDecrypt -Data $encryptedBytes -Key $Key
        
        # Remove PKCS7 padding
        $paddingLength = $decryptedBytes[$decryptedBytes.Length - 1]
        if ($paddingLength -gt 0 -and $paddingLength -le 16) {
            $decryptedBytes = $decryptedBytes[0..($decryptedBytes.Length - $paddingLength - 1)]
        }
        
        # Convert to string and parse JSON
        $json = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
        # Remove "MEGA" prefix if present
        if ($json.StartsWith('MEGA')) {
            $json = $json.Substring(4)
        }
        
        return ($json | ConvertFrom-Json)
    }
    catch {
        Write-Log "Failed to decrypt attributes: $($_.Exception.Message)" 'DEBUG'
        return $null
    }
}

# Derive file key from master key and node key
function Get-MegaFileKey {
    param(
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][string]$NodeKey
    )

    try {
        $base64 = ConvertFrom-Base64Url -Base64Url $NodeKey
        $encryptedKeyBytes = [Convert]::FromBase64String($base64)
        
        # Decrypt the node key using master key
        $decryptedKey = Invoke-MegaAesDecrypt -Data $encryptedKeyBytes -Key $MasterKey
        
        # For files, take first 16 bytes as the key
        return $decryptedKey[0..15]
    }
    catch {
        Write-Log "Failed to derive file key: $($_.Exception.Message)" 'DEBUG'
        return $null
    }
}

# Call mega.nz API with command and parameters
function Invoke-MegaApiRequest {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $apiUrl = 'https://g.api.mega.co.nz/cs'
    
    # Build the request payload
    $payload = @{
        a = $Command
    }
    
    # Merge parameters into payload
    foreach ($key in $Parameters.Keys) {
        $payload[$key] = $Parameters[$key]
    }

    # Wrap in array as mega expects
    $body = @($payload) | ConvertTo-Json -Depth 10 -Compress
    
    Write-Log "API Request: $body" 'DEBUG'

    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $body -ErrorAction Stop
        
        Write-Log "API Response: $($response | ConvertTo-Json -Depth 5)" 'DEBUG'
        
        # Response is an array - get first element
        $result = $response[0]
        
        # Check for API errors (negative numbers)
        if ($result -is [int] -and $result -lt 0) {
            $errorMsg = switch ($result) {
                -1 { "Internal error" }
                -2 { "Invalid arguments" }
                -3 { "Request failed, retrying" }
                -4 { "Rate limit exceeded" }
                -9 { "Object not found" }
                -11 { "Access denied" }
                -14 { "Folder link unavailable" }
                default { "API error code: $result" }
            }
            Write-Log "Mega API error: $errorMsg" 'ERROR'
            return $null
        }
        
        return $result
    }
    catch {
        Write-Log "Mega API request failed: $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

# Fetch and decrypt mega.nz folder structure
function Get-MegaFolderStructure {
    param(
        [Parameter(Mandatory)][string]$FolderId,
        [Parameter(Mandatory)][string]$DecryptionKey
    )

    Write-Log "Fetching folder metadata for ID: $FolderId"
    
    # Convert master key from Base64URL
    $base64Key = ConvertFrom-Base64Url -Base64Url $DecryptionKey
    $masterKeyBytes = [Convert]::FromBase64String($base64Key)
    
    # Mega uses 128-bit keys, so take first 16 bytes
    if ($masterKeyBytes.Length -gt 16) {
        $masterKey = $masterKeyBytes[0..15]
    } else {
        $masterKey = $masterKeyBytes
    }

    # For public folders, we need to first get the public handle
    # Then request the folder structure using 'ph' (public handle) parameter
    $response = Invoke-MegaApiRequest -Command 'f' -Parameters @{
        c = 1
        ph = $FolderId
    }

    if ($null -eq $response) {
        Write-Log "Failed to fetch folder metadata" 'ERROR'
        return $null
    }

    # Parse the folder nodes
    $nodes = @()
    $nodeMap = @{}  # For parent-child relationships

    foreach ($node in $response.f) {
        # Node types: 0=file, 1=folder, 2=root, 3=inbox, 4=trash
        $nodeType = $node.t
        
        # Decrypt the node key to get the file/folder key
        $nodeKey = $null
        if ($node.k) {
            # Key format: "owner_handle:base64_encrypted_key"
            $keyPart = $node.k.Split(':')[-1]  # Take last part
            $nodeKey = Get-MegaFileKey -MasterKey $masterKey -NodeKey $keyPart
        }
        
        # Decrypt attributes to get name and other metadata
        $attributes = $null
        if ($node.a -and $nodeKey) {
            $attributes = Get-MegaDecryptedAttributes -EncryptedAttributes $node.a -Key $nodeKey
        }

        if ($null -eq $attributes -or -not $attributes.n) {
            Write-Log "Could not decrypt node attributes for node $($node.h)" 'DEBUG'
            continue
        }

        $nodeInfo = @{
            Handle = $node.h
            Name = $attributes.n
            Type = $nodeType
            Size = if ($node.s) { $node.s } else { 0 }
            Parent = if ($node.p) { $node.p } else { $null }
            Key = $nodeKey
            Path = ""  # Will be computed later
        }

        $nodes += $nodeInfo
        $nodeMap[$node.h] = $nodeInfo
    }

    Write-Log "Decrypted $($nodes.Count) nodes from folder"

    # Build paths for each node by traversing parent hierarchy
    foreach ($node in $nodes) {
        $pathParts = @($node.Name)
        $currentParent = $node.Parent
        
        while ($currentParent -and $nodeMap.ContainsKey($currentParent)) {
            $parentNode = $nodeMap[$currentParent]
            $pathParts = @($parentNode.Name) + $pathParts
            $currentParent = $parentNode.Parent
        }
        
        $node.Path = ($pathParts -join '\')
    }

    return @{
        Nodes = $nodes
        NodeMap = $nodeMap
    }
}

# Download a single file from mega.nz
function Get-MegaFile {
    param(
        [Parameter(Mandatory)][hashtable]$Node,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    # Request download URL from API
    Write-Log "Requesting download URL for $($Node.Name)" 'DEBUG'
    
    $response = Invoke-MegaApiRequest -Command 'g' -Parameters @{
        g = 1
        p = $Node.Handle
    }

    if ($null -eq $response -or -not $response.g) {
        Write-Log "Failed to get download URL for $($Node.Name)" 'ERROR'
        return $false
    }

    $downloadUrl = $response.g
    
    Write-Log "Downloading $($Node.Name) ($([math]::Round($Node.Size / 1MB, 2)) MB)"
    $downloadStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Download the encrypted file
        $tempFile = "$DestinationPath.megatemp"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -ErrorAction Stop | Out-Null
        
        # Read the encrypted file
        $encryptedData = [System.IO.File]::ReadAllBytes($tempFile)
        
        # Decrypt the file data
        # Mega encrypts files in CBC mode with the node key
        $decryptedData = Invoke-MegaAesDecrypt -Data $encryptedData -Key $Node.Key
        
        # Write decrypted data to final destination
        [System.IO.File]::WriteAllBytes($DestinationPath, $decryptedData)
        
        # Clean up temp file
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        
        $downloadStopwatch.Stop()
        $sizeMb = $Node.Size / 1MB
        Write-Log (
            "Saved {0} in {1:N2}s ({2:N2} MB)" -f
            $Node.Name, $downloadStopwatch.Elapsed.TotalSeconds, $sizeMb
        ) 'SUCCESS'
        
        return $true
    }
    catch {
        $downloadStopwatch.Stop()
        Write-Log "Failed to download $($Node.Name): $($_.Exception.Message)" 'ERROR'
        
        # Clean up temp file on error
        if (Test-Path -LiteralPath "$DestinationPath.megatemp") {
            Remove-Item -LiteralPath "$DestinationPath.megatemp" -Force -ErrorAction SilentlyContinue
        }
        
        return $false
    }
}

# Process mega.nz folder structure and download all files
function Invoke-MegaFolderProcessor {
    param(
        [Parameter(Mandatory)][array]$Nodes,
        [Parameter(Mandatory)][string]$BasePath
    )

    $downloadCount = 0
    $skippedCount = 0
    $folderCount = 0

    # First pass: create all directories
    $folders = $Nodes | Where-Object { $_.Type -eq 1 }
    foreach ($folder in $folders) {
        $folderPath = Join-Path -Path $BasePath -ChildPath $folder.Path
        if (-not (Test-Path -LiteralPath $folderPath)) {
            Write-Log "Creating folder: $($folder.Path)" 'DEBUG'
            New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
            $folderCount++
        }
    }

    Write-Log "Created $folderCount folder(s)"

    # Second pass: download all files
    $files = $Nodes | Where-Object { $_.Type -eq 0 }
    Write-Log "Found $($files.Count) file(s) to download"

    $fileIndex = 0
    foreach ($file in $files) {
        $fileIndex++
        $filePath = Join-Path -Path $BasePath -ChildPath $file.Path

        # Skip if file already exists
        if (Test-Path -LiteralPath $filePath) {
            Write-Log "Skipping existing file ($fileIndex/$($files.Count)): $($file.Name)" 'DEBUG'
            $skippedCount++
            continue
        }

        # Ensure parent directory exists
        $parentDir = Split-Path -Path $filePath -Parent
        if (-not (Test-Path -LiteralPath $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }

        Write-Log "($fileIndex/$($files.Count)) Processing: $($file.Path)"
        
        if (Get-MegaFile -Node $file -DestinationPath $filePath) {
            $downloadCount++
        }
    }

    return @{
        Downloaded = $downloadCount
        Skipped = $skippedCount
        Folders = $folderCount
    }
}

# Download files and folders from mega.nz public folder links
function Invoke-MegaScraper {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DownloadPath
    )

    Write-Log "Preparing to scrape mega.nz folder: $Url"
    New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null

    $overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Parse the URL to extract folder ID and decryption key
    $folderInfo = Get-MegaFolderInfo -Url $Url
    if ($null -eq $folderInfo) {
        Write-Log "Invalid mega.nz URL format" 'ERROR'
        return
    }

    Write-Log "Folder ID: $($folderInfo.FolderId), Key: $($folderInfo.Key.Substring(0, 8))..."

    # Fetch and decrypt the folder structure
    $structure = Get-MegaFolderStructure -FolderId $folderInfo.FolderId -DecryptionKey $folderInfo.Key
    if ($null -eq $structure -or $structure.Nodes.Count -eq 0) {
        Write-Log "Failed to retrieve folder structure or folder is empty" 'ERROR'
        return
    }

    Write-Log "Folder structure retrieved: $($structure.Nodes.Count) total nodes"

    # Process folders and download files
    $result = Invoke-MegaFolderProcessor -Nodes $structure.Nodes -BasePath $DownloadPath

    $overallStopwatch.Stop()
    Write-Log (
        "Mega.nz download complete. Files downloaded: {0}, skipped: {1}, folders created: {2}, duration: {3}" -f
        $result.Downloaded, $result.Skipped, $result.Folders, $overallStopwatch.Elapsed.ToString()
    ) 'SUCCESS'
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
$url = "https://mega.nz/folder/nUtRCLIJ#kYfhz6nRZOHNGBuB9rxhHw"  # <-- Change this to the actual URL you want to scrape

# Set the path to save the downloaded video files
$path = "C:\Users\DanielBjörk\Downloads\x"

Write-Log "Ensuring download directory exists at $path" 'DEBUG'
New-Item -ItemType Directory -Path $path -Force | Out-Null

# Route to the correct scraper based on the URL
if ($url -match 'mega\.nz/') {
    Invoke-MegaScraper -Url $url -DownloadPath $path
}
elseif ($url -match 'erome\.com/') {
    Invoke-EromeScraper -Url $url -DownloadPath $path
}
else {
    Invoke-DefaultScraper -Url $url -DownloadPath $path
}