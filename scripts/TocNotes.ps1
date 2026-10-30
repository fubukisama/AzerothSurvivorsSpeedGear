#requires -Version 5.1
# Pure byte-to-byte helpers. Callers must verify this library's receipt SHA-256
# before loading it. This library never reads or changes any file or setting.

function Get-AZSGTocNotesCanonicalBytes([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -gt 16KB) { throw 'TOC is missing or exceeds 16 KiB.' }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $text = $encoding.GetString($Bytes)
    $notes = [regex]::Matches($text, '(?m)^## Notes: ([^\r\n]*)(?=\r?$)')
    $allNotes = [regex]::Matches($text, '(?im)^##[ \t]*Notes[ \t]*:')
    if ($notes.Count -ne 1 -or $allNotes.Count -ne 1) { throw 'TOC must contain one exact Notes directive.' }
    $translations = [regex]::Matches($text, '(?m)^## X-AZSG-Notes-([a-z]{2}): ([^\r\n]*)(?=\r?$)')
    $allTranslations = [regex]::Matches($text, '(?im)^##[ \t]*X-AZSG-Notes-')
    if ($translations.Count -ne 14 -or $allTranslations.Count -ne 14) { throw 'TOC must contain exactly fourteen translation directives.' }
    $allowed = @('en', 'zh', 'ja', 'pl', 'cs', 'de', 'pt', 'es', 'fr', 'ro', 'tr', 'ru', 'uk', 'ko')
    $values = @{}
    foreach ($translation in $translations) {
        $code = $translation.Groups[1].Value
        $value = $translation.Groups[2].Value
        if ($allowed -cnotcontains $code -or $values.ContainsKey($code) -or
            [string]::IsNullOrWhiteSpace($value) -or $value -match '[\x00-\x1f\x7f]') {
            throw 'TOC has an unknown, duplicate or invalid translation.'
        }
        $values[$code] = $value
    }
    $current = $notes[0].Groups[1]
    $known = $false
    foreach ($value in $values.Values) {
        if ([string]::Equals($current.Value, [string]$value, [StringComparison]::Ordinal)) { $known = $true; break }
    }
    if (-not $known) { throw 'TOC Notes is not one of its fourteen fixed translations.' }
    # Replace only the captured value. Encoding round-trips strict UTF-8, so
    # BOM, line endings and every other byte remain part of the receipt hash.
    $canonical = $text.Substring(0, $current.Index) + [string]$values['en'] +
        $text.Substring($current.Index + $current.Length)
    return ,($encoding.GetBytes($canonical))
}

function Test-AZSGTocNotesReceiptHash([byte[]]$Bytes, [string]$ExpectedSHA256) {
    if ($ExpectedSHA256 -cnotmatch '^[a-fA-F0-9]{64}$') { return $false }
    try {
        $canonical = Get-AZSGTocNotesCanonicalBytes $Bytes
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($algorithm.ComputeHash($canonical)).Replace('-', '') }
        finally { $algorithm.Dispose() }
        return [string]::Equals($hash, $ExpectedSHA256, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}
