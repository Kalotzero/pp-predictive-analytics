# Run once in an elevated PowerShell on the Windows server. Adjust the two paths.
$py  = "C:\Python\python.exe"       # where.exe python
$dir = "D:\pp"                      # folder with pp_client.py and .env
$act1 = New-ScheduledTaskAction -Execute $py -Argument "pp_client.py delta"   -WorkingDirectory $dir
$act2 = New-ScheduledTaskAction -Execute $py -Argument "pp_client.py nightly" -WorkingDirectory $dir
$t1 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 30)
$t2 = New-ScheduledTaskTrigger -Daily -At 2:00
# runs even when nobody is logged on; Windows asks for the service account password
Register-ScheduledTask -TaskName "PP analytics delta"   -Action $act1 -Trigger $t1 -User "DOMAIN\svc_account" -Password (Read-Host "password") -RunLevel Limited
Register-ScheduledTask -TaskName "PP analytics nightly" -Action $act2 -Trigger $t2 -User "DOMAIN\svc_account" -Password (Read-Host "password") -RunLevel Limited
