# Moves every Starlight release from a build-N tag to v0.N.0 (same commit, same release).
# Releases are never deleted or recreated: the tag is switched with `gh release edit --tag`,
# and the old tag is deleted only after the release is confirmed on the new one.
#
# Needs: Git and GitHub CLI (winget install GitHub.cli), then `gh auth login` once.
# Run from any folder:  powershell -ExecutionPolicy Bypass -File retag-releases.ps1

$ErrorActionPreference = "Stop"
$Repo = "jmmorgado/starlight-ios"
$Work = Join-Path $env:TEMP "starlight-retag"

# 1. Snapshot before (tag, title, date, assets)
$before = gh api --paginate "repos/$Repo/releases?per_page=100" | ConvertFrom-Json
$before | ForEach-Object { "{0} | {1} | {2} | {3}" -f $_.tag_name, $_.name, $_.published_at, (($_.assets | ForEach-Object { $_.name }) -join ",") } |
    Set-Content (Join-Path $env:TEMP "starlight-releases-before.txt")
Write-Host "Saved the list of $($before.Count) releases to $env:TEMP\starlight-releases-before.txt"

# 2. A bare clone with all tags (no files checked out)
if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
git clone --bare --quiet "https://github.com/$Repo.git" $Work
Push-Location $Work
try {
    foreach ($release in $before) {
        $tag = $release.tag_name
        if ($tag -notmatch '^build-(\d+)$') { Write-Host "Skipping $tag"; continue }
        $n = $Matches[1]
        $new = "v0.$n.0"
        $sha = (git rev-list -n 1 "refs/tags/$tag").Trim()
        Write-Host "== $tag -> $new ($sha)"

        # New tag on the same commit
        git tag -f $new $sha | Out-Null
        git push --quiet origin "refs/tags/$new"

        # Point the existing release at it, keeping the title
        gh release edit $tag --repo $Repo --tag $new --title "Starlight build $n" | Out-Null

        # Delete the old tag only once the release is on the new tag, at the same commit
        $linked = gh api "repos/$Repo/releases/tags/$new" --jq ".tag_name"
        $newSha = gh api "repos/$Repo/commits/$new" --jq ".sha"
        if ($linked -ne $new -or $newSha -ne $sha) {
            throw "Release for $tag is not on $new at $sha; the old tag was kept"
        }
        git push --quiet origin ":refs/tags/$tag"
        Write-Host "   moved"
    }
}
finally {
    Pop-Location
}

# 3. Fix the only internal link (build 4 notes -> build 3)
$notes = gh api "repos/$Repo/releases/tags/v0.4.0" --jq ".body"
$fixed = $notes -replace "releases/tag/build-3", "releases/tag/v0.3.0"
$tmp = Join-Path $env:TEMP "starlight-notes-4.md"
Set-Content -Path $tmp -Value $fixed -Encoding UTF8
gh release edit v0.4.0 --repo $Repo --notes-file $tmp | Out-Null

# 4. Check: same number of releases, all published, Starlight.ipa still attached
$after = gh api --paginate "repos/$Repo/releases?per_page=100" | ConvertFrom-Json
$problems = $after | Where-Object { $_.draft -or -not ($_.assets | Where-Object { $_.name -eq "Starlight.ipa" }) -or $_.tag_name -notmatch '^v0\.\d+\.0$' }
Write-Host ""
Write-Host "Before: $($before.Count) releases. After: $($after.Count) releases."
if ($problems) {
    Write-Host "Check these:" -ForegroundColor Yellow
    $problems | ForEach-Object { Write-Host " - $($_.tag_name) $($_.name)" }
} else {
    Write-Host "All releases are published on v0.N.0 tags with Starlight.ipa attached." -ForegroundColor Green
}
