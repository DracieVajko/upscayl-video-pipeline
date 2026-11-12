# Upscayl Video Pipeline V2 - errors module.
# Pipeline exception type shared by every stage.
# Dot-sourced by UpscaylVideo.ps1; not meant to be run directly.

class PipelineException : System.Exception {

    [int]$ExitCode

    [string]$Hint

    PipelineException([string]$Message, [string]$HintText, [int]$Code) : base($Message) {

        $this.Hint = $HintText

        $this.ExitCode = $Code

    }

    [string] ToString() {

        if ($this.Hint) {

            return $this.Message + [Environment]::NewLine + 'Hint: ' + $this.Hint

        }

        return $this.Message

    }

}
