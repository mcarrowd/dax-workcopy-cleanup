[CmdletBinding()]
Param(
	[Parameter(Mandatory=$True,Position=1)]
	[string]$WorkDir
)

$DiffUtilsRegKey = 'HKLM:\SOFTWARE\GnuWin32\DiffUtils'
$PatchRegKey = 'HKLM:\SOFTWARE\GnuWin32\Patch'
$supportedWindowsEncodingWebName = 'windows-1251'
$supportedConsoleEncodingWebName = 'cp866'

$scriptDir = split-path -parent $MyInvocation.MyCommand.Definition

$diffCmdName = 'diff-cmd.cmd'
$diffCmdPath = "$scriptDir\$diffCmdName"
$diffCmdContent = '@echo off & echo ?%~6?%~7?'

$diffTool = ''
$patchTool = ''
$svn = ''

function ConvertTo-Encoding ([string]$From, [string]$To)
{
	Begin{
		$encFrom = [System.Text.Encoding]::GetEncoding($from)
		$encTo = [System.Text.Encoding]::GetEncoding($to)
	}
	Process{
		$bytes = $encTo.GetBytes($_)
		$bytes = [System.Text.Encoding]::Convert($encFrom, $encTo, $bytes)
		$encTo.GetString($bytes)
	}
}

function checkEncodings()
{
	$encodingWebName = [Console]::OutputEncoding.WebName
	if ($encodingWebName -ne $supportedConsoleEncodingWebName)
	{
		write-error "Console output encoding $encodingWebName unsupported"
		return $FALSE
	}
	$encodingWebName = [Console]::InputEncoding.WebName
	if ($encodingWebName -ne $supportedConsoleEncodingWebName)
	{
		write-error "Console input encoding $encodingWebName unsupported"
		return $FALSE
	}	
	$encodingWebName = [System.Text.Encoding]::Default.WebName
	if ($encodingWebName -ne $supportedWindowsEncodingWebName)
	{
		write-error "Windows encoding $encodingWebName unsupported"
		return $FALSE
	}	
	return $TRUE
}

Function initTools()
{
	write-verbose 'Verifying Subversion installation...'
	$svnApp = Get-Command 'svn.exe' -commandtype application
	if (!$svnApp)
	{
		write-error 'Apache Subversion not installed'
		return $FALSE
	}
	$svnAppPath = $svnApp.Definition
	$svnVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($svnAppPath)
	if (!$svnVersion )
	{
		write-error 'Could not verify SVN version'
		return $FALSE
	}
	if (($svnVersion.FileMajorPart -lt 1) -or (($svnVersion.FileMajorPart -ge 1) -and ($svnVersion.FileMinorPart -lt 6)))
	{
		write-error "Minimal supported version of SVN is 1.6.0. Installed version is $($svnVersion.FileVersion)"
		return $FALSE
	}
	$script:svn = $svnAppPath
	write-verbose "Found $svn"
	write-verbose 'Verifying GNU Diff Utils installation...'
	if ($(Test-Path $DiffUtilsRegKey) -ne $TRUE)
	{
		write-error 'GNU Diff utils not installed'
		return $FALSE
	}
	$Props = get-itemproperty $DiffUtilsRegKey
	if ($Props.InstallPath -eq '')
	{
		write-error 'GNU Diff utils not installed'
		return $FALSE
	}
	$Script:diffTool = "$($Props.InstallPath)\bin\diff.exe"
	write-verbose "Found $diffTool"
	write-verbose 'Verifying GNU Patch installation...'
	if ($(Test-Path $PatchRegKey) -ne $TRUE)
	{
		write-error 'GNU Patch not installed'
		return $FALSE
	}
	$Props = get-itemproperty $PatchRegKey
	if ($Props.InstallPath -eq '')
	{
		write-error 'GNU Patch not installed'
		return $FALSE
	}
	$Script:patchTool = "$($Props.InstallPath)\bin\patch.exe"
	write-verbose "Found $patchTool"
	return $TRUE
}

function checkOrCreateDiffCmd()
{
	try
	{
		if (Test-Path $diffCmdPath)
		{
			$diffCmdCurrentContent = Get-Content $diffCmdPath
		}	
		if ($diffCmdCurrentContent -ne $diffCmdContent)
		{
			Set-Content -path $diffCmdPath $diffCmdContent
		}
		return $true
	}
	catch
	{
		write-error 'Cannot create or verify integrity of diff cmd'
		return $false
	}
}

Function runTool($path, $arguments, $standardInputEncodingName, $standardInputContent, $standardOutputEncodingName)
{
	Write-Verbose "runTool $path $arguments"
	$exitCode = 0
	if ($standardOutputEncodingName)
	{
		$stdOutEncoding = [System.Text.Encoding]::GetEncoding($standardOutputEncodingName);
	}
	else
	{
		$stdOutEncoding = [System.Console]::OutputEncoding;
	}
	if ($standardInputEncodingName -and ($standardInputEncodingName -ne [System.Console]::InputEncoding.BodyName))
	{
		$lastStdInEncoding = [System.Console]::InputEncoding;
		[System.Console]::InputEncoding = [System.Text.Encoding]::GetEncoding($standardInputEncodingName);
	}
	try
	{
		$process = New-Object System.Diagnostics.Process
		$process.StartInfo.UseShellExecute = $false
		$process.StartInfo.FileName = $path
		$process.StartInfo.Arguments = $arguments
		if ($standardInputContent)
		{
			$process.StartInfo.RedirectStandardInput = $true
		}
		$process.StartInfo.RedirectStandardOutput = $true
		$process.StartInfo.StandardOutputEncoding  = $stdOutEncoding
		[void]$process.Start()		
		if ($standardInputContent)
		{
			$StreamWriter = $process.StandardInput
			$standardInputContent | foreach { $StreamWriter.Write($_ + "`n") }
			$StreamWriter.Close()
		}
		$stdout = $process.StandardOutput.ReadToEnd()
		$process.WaitForExit()
		$exitCode = $process.ExitCode
		$process.Close()
	}
	finally
	{
		if ($lastStdInEncoding)
		{
			[System.Console]::InputEncoding = $lastStdInEncoding;
		}
	}
	return New-Object PSObject -Property @{
		ExitCode = $exitCode;
		StandardOutputContent = $stdout;
	}
}

Function svnDiff($targetdir)
{
	Write-Verbose "svnDiff $targetdir"
	$result = runTool $svn "diff --no-diff-added --no-diff-deleted --ignore-properties --diff-cmd ""$diffCmdPath"" ""$targetdir"""
	if ($result.ExitCode -eq 0)
	{
		$diffOutput = $result.StandardOutputContent.split("`n")
		if ($diffOutput)
		{
			$diffOutput = $diffOutput | where-object { $_.Contains('?') } | foreach { $firstIndex = $_.IndexOf('?');  $_.Substring($firstIndex + 1, $_.LastIndexOf('?') - $firstIndex - 1) }
			$diffOutput = "File1?File2", $diffOutput
			return $diffOutput | ConvertFrom-Csv -Delimiter ?
		}
	}
	else
	{
		write-error "SVN DIFF return non-zero exit code ($($result.exitcode))"
	}
}

Function svnRevert($targetFile)
{
	Write-Verbose "svnRevert $targetFile"
	$result = runTool $svn "revert ""$targetFile"""
	if ($result.exitcode -ne 0)
	{
		write-error "SVN REVERT return non-zero exit code ($($result.exitcode))"
	}
}

Function diffToolCheckEqual($arguments, $file1, $file2)
{
	Write-Verbose "diffToolCheckEqual $file1 $file2"
	$result = runTool $diffTool "$arguments ""$file1"" ""$file2"""
	switch ($result.ExitCode)
	{
		0 { return $TRUE }
		1 { return $FALSE }
		default 
		{
			write-error "Diff tool return error code $($result.ExitCode)"
			return $FALSE
		}
	}
}

Function diffToolGetPatch($arguments, $file1, $file2)
{
	Write-Verbose "diffToolGetPatch $file1 $file2"
	$result = runTool $diffTool "$arguments ""$file1"" ""$file2""" -standardOutputEncodingName $supportedWindowsEncodingWebName
	switch ($result.ExitCode)
	{
		{($_ -eq 0) -or ($_ -eq 1)} 
		{
			return New-Object PSObject -Property @{
				Success = $TRUE;
				Content = $result.StandardOutputContent;
			}
		}
		default 
		{
			return New-Object PSObject -Property @{
				Success = $FALSE;
			}
		}
	}
}

Function patchToolApplyPatch($arguments, $patch, $fileToPatch, $outFile)
{
	Write-Verbose "patchToolApplyPatch $fileToPatch $outFile"
	$result = runTool $patchTool "-o""$outFile"" ""$fileToPatch""" $supportedWindowsEncodingWebName $patch
	switch ($result.ExitCode)
	{
		0 { return $TRUE }
		default 
		{
			write-error "Patch tool return error code $($result.ExitCode)"
			return $FALSE
		}
	}
}

Function diffAndRevert($targetdir, $arguments)
{
	Write-Verbose "diffAndRevert $targetdir"
	$filesToRevert = @()
	svnDiff $targetdir | foreach {
		if (diffToolCheckEqual $arguments $_.File1 $_.File2)
		{
			$filesToRevert += $_.File2
		}	
	}
	if ($filesToRevert)
	{
		$filesToRevert | foreach { svnRevert $_ }
	}
	else
	{
		Write-Verbose "Unnecessary changes not found"
	}
}

Function diffAndPatch($targetdir, $arguments)
{
	Write-Verbose "diffAndPatch $targetdir"
	svnDiff $targetdir | foreach {
		$result = diffToolGetPatch $arguments $_.File1 $_.File2
		if ($result.Success -eq $TRUE)
		{
			$patch = $result.Content #.split("`n")
			if ($patch)
			{
				[void](patchToolApplyPatch $arguments $patch $_.File1 $_.File2)
			}
			else
			{
				$file = get-item $_.File2
				$attributes = $file.attributes
				copy-item $_.File1 $_.File2
				$file = get-item $_.File2
				$file.attributes = $attributes
			}
		}
	}
}

Function revertCase()
{
	Write-Verbose 'Reverting files with letter case differences only...'
	diffAndRevert $workdir '-iqs'
}

Function revertForms()
{
	Write-Verbose 'Reverting forms with control comments differences only...'
	diffAndRevert "$workdir\aot\forms" '-I ";==== controlId:"'
}

Function revertProjects()
{
	Write-Verbose 'Reverting projects with timestamp differences only...'
	diffAndRevert "$workdir\projects" '-I "; Microsoft Business Solutions-Axapta Project :"'
}

Function revertFormsControls()
{
	Write-Verbose 'Patching forms to remove control comments changes...'
	diffAndPatch "$workdir\aot\forms" '-I ";==== controlId:"'
}

Write-Progress -Activity "Cleanup unnecessary changes" -status "init" -percentComplete 0
if ((checkEncodings -eq $TRUE) -and (checkOrCreateDiffCmd -eq $TRUE) -and (initTools -eq $TRUE))
{
	Write-Progress -Activity "Cleanup unnecessary changes" -status "revertFormsControls" -percentComplete 25
	revertFormsControls
	Write-Progress -Activity "Cleanup unnecessary changes" -status "revertCase" -percentComplete 50
	revertCase
	Write-Progress -Activity "Cleanup unnecessary changes" -status "revertForms" -percentComplete 75
	revertForms
	Write-Progress -Activity "Cleanup unnecessary changes" -status "revertProjects" -percentComplete 100
	revertProjects
}