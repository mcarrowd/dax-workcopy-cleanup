# Dynamics AX SVN working copy cleanup tool
====================

This Powershell script is intended to facilitate maintenance of Microsoft Dynamics AX 4 Subversion working copy. Script resolves some painfull issues with unloading AOT items into *.xpo files:

* random letter case changes in object identifiers
* unnecessary comments in forms
* unnecessary comments in projects

## Usage

You can use this script as start commit hook in Tortoise SVN. Just create Windows batch script with simular content

```Batchfile
powershell -file "c:\scripts\dax-workcopy-cleanup.ps1" -WorkDir %3

```

and assign it as start commit hook in Tortoise SVN settings.
