# So...my vSphere license is the "Essentials Plus kit", which doesn't actually
# provide storage vMotion. That does not remove the need for us to very
# occasionally migrate from one datastore to another (much less frequently
# than in the Teaching cluster). 
#
# The fastest way that I've found is to detach any removable media from
# the VM, suspend the guest (which then frees up the machine to be moved
# anywhere), storage migrate the machine to the target datastore, revive
# the VM, then migrate to the new host as usual. 
#
# -MS 
# standalone.sysadmin@gmail.com 20130404

# Lets get the parameters sorted first. 
# Here's a good link for future reference: 
# https://devcentral.f5.com/blogs/us/powershell-abcs-p-is-for-parameters
param([string]$viserver = "", [string]$vm = "", [string]$targetDS = "", [string]$targetVMHost = "")

# Just in case someone's running ps1 scripts all willy-nilly instead 
# of straight through PowerCLI, lets add in the PowerCLI snap-in (but only
# if it isn't already loaded, of course). 
if ( ( Get-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null ) { 
	Try { add-pssnapin VMware.VimAutomation.Core } 
	Catch { "Sorry, couldn't load the PowerCLI snap-in from VMware. Is it installed?" + $error[0] ; exit }
}

##################
# Print usage information when we need it. 
function usage { 
	$Host.UI.WriteErrorLine("Usage: $0 [-viserver <servername>] [-vm <vm>] [-targetDS <target datastore>] [-targetVMHost <target VM Host>]")
	$Host.UI.WriteErrorLine("	-viserver is optional if the session is already connected to a VIserver")
	$Host.UI.WriteErrorLine("	-vm is non-optional"); 
	$Host.UI.WriteErrorLine("	One or both of -targetDS and -targetVMHost can be provided, depending on your intent"); 
	$Host.UI.WriteErrorLine("")
	$Host.UI.WriteErrorLine("The purpose of this program is to migrate a VM from where it is to another VM host or datastore (or both).")
	$Host.UI.WriteErrorLine("If storage vmotion is enabled, then the machine is migrated straight away. If not, then the machine")
	$Host.UI.WriteErrorLine("has its removable media detached, is suspended, then migrated, then revived on the new host or storage.")
	$Host.UI.WriteErrorLine("If we're migrating to a new host AND datastore, then it does the datastore first, revives the machine, then")
	$Host.UI.WriteErrorLine("vmotions the machine as normal")
}
##################

# InvalidCertificates are weak sauce, but I get it. 
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -confirm:$false | out-null

# Sanity check - we need a valid vm, VI server, and things to do.
if ( $vm -eq "" ) { 
	usage
	exit
} ElseIf ( $DefaultVIServers -eq $null ) { 
	if ( $viserver -ne "" ) { 
		Connect-VIServer $viserver 
	} else { 
		usage
		exit
	}
}
if ( ( $targetDS -eq "" ) -and ( $targetVMHost -eq "" ) ) { 
	Write-Host "viserver: $viserver"
	Write-Host "targetVMHost: $targetVMHost"
	usage
	exit
}

## TODO 
## Add license checking using the techniques here:
# http://www.peetersonline.nl/2009/01/getting-detailed-vmware-license-information-with-powershell/
## END TODO

#########################################
# Functions to perform the heavy lifting. 
############

function migrateDS { 
	Write-Host "In migrateDS"
	Try { $ds = Get-Datastore -VMHost ($vm2m.Host) -name $targetDS} 
	Catch { $Host.UI.WriteErrorLine( "Error finding $targetDS on the proper vmhost: " + $error[0]) ; exit } 

	Try { Move-VM -vm $vm2m -datastore $ds } 
	Catch { $Host.UI.WriteErrorLine( "Error migrating to new datastire: " + $error[0]) ; exit }
		
} # end function migrate

function migrateVHost { 
	Write-Host "In migrateVHost"
	Try { $vmh = Get-VMHost -name $targetVMHost } 
	Catch { $Host.UI.WriteErrorLine( "Error connecting to vmHost $targetVMHost: " + $error[0]) ; exit } 

	Try { Move-VM -VM $vm2m -Destination $vmh } 
	Catch { $Host.UI.WriteErrorLine( "Error moving $vm to $targetVMHost: " + $error[0]) ; exit }

} # end function migrateVHost

function suspend { 
	Write-Host "In suspend"
	# Before suspending, we really need to make sure that all of the removable media is detached because
	# it won't migrate with the VM. If it's not accessible to the remote host, the vmotion will fail. 
	Try { $vm2m | Get-CDDrive | Set-CDDrive -NoMedia -Confirm:$false }
	Catch { $Host.UI.WriteErrorLine( "Error detaching CD ROM contents to $vm2m: " + $error[0]) ; exit }

	# do the suspend, blocking so we're sure that it's complete
	Try { $vm2m | Suspend-VM -Confirm:$false } 
	Catch { $Host.UI.WriteErrorLine( "Error suspending vm $vm2m. Please check this out manually: " + $error[0]) ; exit }
	
} # end function suspend

function revive { 
	# There is a weird bug. If we use the original variable assignment, it sees 
	# the VM as PoweredOn. If we reassign the variable, it triggers a reread, 
	# and it gets the proper state of Suspended. Since we're not holding open
	# any pointers to the object, we'll be ok reassigning it here. 
	$vm2m = Get-VM -name $vm
	
	# Wake the machine back up after suspension
	if ( $vm2m.PowerState -ne "Suspended" ) { 
		Write-Warning "Warning: $vm2m is not not suspended. Maybe this is okay? Continuing..." 
	} else { 
		Try { $vm2m | Start-VM } 
		Catch { $Host.UI.WriteErrorLine( "Error reviving $vm2m. Please fix by hand: " + $error[0]) ; exit } 
	} 
}

#########################################
# At this point, we can be reasonably sure that we can do what we need. 

$vm2m = get-vm -name $vm 

# There are ways to do this which involve fewer lines of code, but 
# I'll trade the code length for the ability to edit it later to add
# provisions for doing other things under certain conditions with the
# VMs. 
Write-Host "vm: -$vm-"
Write-Host "targetDS: -$targetDS-"
Write-Host "targetVMHost: -$targetVMHost-"
switch ($vm2m.PowerState) { 
	"PoweredOff" { 
		if ( $targetDS -ne $null ) { 
			migrateDS
		} 
		if ( $targetVMHost -ne $null ) { 
			migrateVHost
		}
	}
	"PoweredOn" { 
		# We only suspend if we're doing a DS migration, since we can do a live vMotion 
		if ( $targetDS -ne "" ) { 
			Write-Host "Suspending VM $vm2m"
			suspend 
			Write-Host "Migrating VM $vm2m to new datastore"
			migrateDS
			# We want the machine to be back up asap, so we revive as soon as 
			# we're on the new datastore. 
			Write-Host "Reviving $vm2m"
			revive
		} 
		if ( $targetVMHost -ne "" ) { 
			Write-Host "Migrating $vm2m to new vHost"
			migrateVHost
		}
	}
	"Suspended" {
		Write-Host "Found a suspended VM"
		if ( $targetDS -ne "" ) { 
			Write-Host "Migrating $vm2m to new datastore: $targetDS!"
			migrateDS
		} 
		if ( $targetVMHost -ne "" ) { 
			Write-Host "Migrating $vm2m to new vHost"
			migrateVHost
		}
	}
	default { 
		# some kind of problem. punt.
		$Host.UI.WriteErrorLine( "Error: $vm2m is in an unknown state (not PoweredOff, PoweredOn, or Suspended): ")
		exit
	}
} # end switch statement


