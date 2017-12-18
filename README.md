# glyph-AutoField
Command ensemble to automatically build a nearfield and farfield around a
collection of domains.

Example usage:

```tcl
package require PWI_Glyph 2.18

set scriptDir [file dirname [info script]]
source [file join $scriptDir AutoField.glf]


proc getDomains { domsVar } {
  upvar $domsVar doms
  set doms {}
  set mask [pw::Display createSelectionMask -requireDomain Defined \
              -blockDomain Hidden]
  if { ![pw::Display getSelectedEntities -selectionmask $mask selection] } {
    # Nothing has been selected so grab all doms
    set tmpDoms [pw::Grid getAll -type pw::Domain]
    set doms {}
    foreach dom $tmpDoms {
      if {[$dom getEnabled] && [pw::Display isLayerVisible [$dom getLayer]]} {
        lappend doms $dom
      }
    }
  } else {
    # We have a selection. Ensure only domains are selected
    set doms $selection(Domains)
  }
  return [llength $doms]
}


proc setupNoDbHALF {} {
  pw::Application load [file join $::scriptDir bodyDomains-NoDb-HALF.pw]

  AutoField setNearFieldBC x- Margin 110.0
  AutoField setNearFieldBC x+ Margin 220.0
  AutoField setNearFieldBC y- Symmetry
  AutoField setNearFieldBC y+ Margin 240.0
  AutoField setNearFieldBC z- Wall 0.01 1.2 DropShadow
  AutoField setNearFieldBC z+ Margin 150.0
}

proc setupNoDbHALFUnclosed {} {
  pw::Application load [file join $::scriptDir bodyDomains-NoDb-HALF-unclosed.pw]

  AutoField setNearFieldBC x- Margin 110.0
  AutoField setNearFieldBC x+ Margin 220.0
  AutoField setNearFieldBC y- Symmetry
  AutoField setNearFieldBC y+ Margin 240.0
  AutoField setNearFieldBC z- Wall 0.01 1.2 DropShadow
  AutoField setNearFieldBC z+ Margin 150.0
}

proc setupNoDb {} {
  pw::Application load [file join $::scriptDir bodyDomains-NoDb.pw]

  AutoField setNearFieldBC x- Margin 110.0
  AutoField setNearFieldBC x+ Margin 220.0
  AutoField setNearFieldBC y- Margin 340.0
  AutoField setNearFieldBC y+ Margin 240.0
  AutoField setNearFieldBC z- Wall 0.01 1.2 DropShadow
  AutoField setNearFieldBC z+ Margin 150.0
}


##########################################################################
#                             Main
##########################################################################
AutoField setVerbose

pw::Application reset

#setupNoDb
#setupNoDbHALF
setupNoDbHALFUnclosed

if { [getDomains doms] } {
  if { ![catch {AutoField run $doms} err] } {
    AutoField::dump
  } else {
    puts "### AutoField error: $::errorInfo"
  }
}
```