<#
.SYNOPSIS
    Windows deployment for cockpit-headscale. There is nothing to deploy, and
    this script says so precisely rather than pretending otherwise.

.DESCRIPTION
    cockpit-headscale is a Cockpit plugin. Cockpit is a Linux service; its
    package directory is /usr/share/cockpit and its helpers live in
    /usr/local/sbin. There is no Windows half of this repository - no service, no
    scheduled task, no binary - so there is nothing here for a Windows deploy to
    copy. DEPLOY-CONTRACT.md section 1.2 says exactly this: Windows is out of
    scope for the six Cockpit plugins, and the Windows half of the contract
    exists for the components that genuinely ship there.

    This file exists rather than being absent because an absent deploy.ps1 is
    ambiguous - it reads as an oversight, and the next person writes one. A
    script that refuses, and names what you probably wanted instead, is the
    smaller cost. It deliberately contains no deployment logic: a stub that
    copied "something, just in case" would be a Windows install nobody designed.

    WHAT YOU PROBABLY WANT INSTEAD

    To deploy the plugin, on the Linux host running Cockpit:

        sudo ./deploy.sh

    To enrol THIS Windows machine into the tailnet, on the control server:

        hs-admin client-config --os windows

    That prints the tailscale login command and the pre-auth key for this
    tailnet. The key is a credential: it is printed to the caller and to nobody
    else - not to a log, not to a file, and never through the /srv/jobs runner,
    whose logs are group-readable.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest

Write-Host ""
Write-Host "cockpit-headscale has no Windows payload." -ForegroundColor Yellow
Write-Host ""
Write-Host "  It is a Cockpit plugin, and Cockpit is Linux-only. Deploying it means"
Write-Host "  running deploy.sh on the host that serves Cockpit:"
Write-Host ""
Write-Host "      sudo ./deploy.sh"
Write-Host ""
Write-Host "  To enrol this Windows machine into the tailnet, run this on the"
Write-Host "  control server and follow what it prints:"
Write-Host ""
Write-Host "      hs-admin client-config --os windows"
Write-Host ""

exit 1
