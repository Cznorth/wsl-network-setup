# PowerShell helper for entering the residential-proxy container at the
# container path corresponding to the current Windows C: or D: directory.

$script:Bash1ComposeRoot = Split-Path -Parent $PSScriptRoot

function bash1 {
    [CmdletBinding()]
    param()

    $hostPath = (Get-Location).Path
    if ($hostPath -notmatch '^(?<drive>[cCdD]):\\(?<rest>.*)$') {
        throw "bash1 only maps directories on C: or D:. Current directory: $hostPath"
    }

    $drive = $Matches.drive.ToLowerInvariant()
    $rest = $Matches.rest -replace '\\', '/'
    $containerPath = if ([string]::IsNullOrEmpty($rest)) {
        "/mnt/$drive"
    } else {
        "/mnt/$drive/$rest"
    }

    Push-Location $script:Bash1ComposeRoot
    try {
        $running = docker compose ps --status running -q residential-proxy 2>$null
        if (-not $running) {
            docker compose up -d --build
            if ($LASTEXITCODE -ne 0) {
                throw "Could not start residential-proxy."
            }
        }

        docker compose exec -w $containerPath residential-proxy bash
    }
    finally {
        Pop-Location
    }
}
