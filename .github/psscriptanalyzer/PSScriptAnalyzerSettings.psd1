@{
    # Static analysis settings for the V2 PowerShell runtime.
    #
    # The excluded rules are opinionated defaults that do not fit this codebase:
    #   PSUseSingularNouns      - these are internal stage helpers, not cmdlets.
    #   PSUseApprovedVerbs      - Ensure-*/Resolve-* are used deliberately.
    #   PSAvoidUsingWriteHost   - Write-Host is the console output of this CLI.
    #   PSUseShouldProcessForStateChangingFunctions
    #                           - the CLI has its own confirmation flow (--yes and prompts).
    #   PSReviewUnusedParameter - stage functions share one uniform parameter list.
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        'PSUseSingularNouns',
        'PSUseApprovedVerbs',
        'PSAvoidUsingWriteHost',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSReviewUnusedParameter'
    )
}
