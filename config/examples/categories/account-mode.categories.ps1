<#
    EXAMPLE / PROPOSAL -- see docs/settings-config-strategy.md. Not loaded by asl-win11maker.ps1 today.

    Account mode: two mutually exclusive named entries mapping onto -LocalAccountName vs. the default/
    -KeepCorporateApps path (docs/build-options-reference.md).
#>
@(
    @{
        Name        = 'Local'
        Description = 'OOBE creates a local administrator account automatically via -LocalAccountName; ' +
                       'no Microsoft/Entra account required. SECURITY NOTE: the password equals the ' +
                       'account name in plaintext and is left readable in C:\Windows\Panther\unattend.xml ' +
                       'on the installed system with no cleanup step today -- see ' +
                       'docs/answer-file-generators-options.md''s sensitive-file finding and ' +
                       'docs/optimization-checklists.md. Fine for disposable/dev/VM images only.'
        Source      = 'build-options-reference.md#-localaccountname-name'
    }
    @{
        Name        = 'Online'
        Description = 'Default OOBE behavior (or -KeepCorporateApps, which also keeps Copilot/Teams/' +
                       'Outlook/OneDrive) -- OOBE offers Microsoft/Entra account sign-in, suitable for ' +
                       'Autopilot/Intune enrollment.'
        Source      = 'build-options-reference.md#-keepcorporateapps'
    }
)
