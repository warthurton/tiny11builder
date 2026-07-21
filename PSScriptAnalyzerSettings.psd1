@{
    # Analyze only errors and warnings by default.
    Severity     = @('Error', 'Warning')

    # Keep high-signal rules and suppress style-only noise for this legacy script repo.
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions'
        'PSAvoidUsingWriteHost'
        'PSUseSingularNouns'
        'PSUseBOMForUnicodeEncodedFile'
    )
}
