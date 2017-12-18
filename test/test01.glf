package require PWI_Glyph 2.18

set scriptDir [file dirname [info script]]
source [file join $scriptDir .. AutoField.glf]


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

proc setupHalfPlane {} {
  pw::Application load [file join $::scriptDir halfPlane.pw]

  AutoField setNearFieldBC x- Symmetry
  AutoField setNearFieldBC x+ Margin 100.0
  AutoField setNearFieldBC y- Margin 50.0
  AutoField setNearFieldBC y+ Margin 50.0
  AutoField setNearFieldBC z- Margin 200.0
  AutoField setNearFieldBC z+ Margin 100.0
}

##########################################################################
#                             Main
##########################################################################
AutoField setVerbose

pw::Application reset

#setupHalfPlane
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

exit 0

  if {0} {
    #Input parameters to use
    set AutoField::groundPlane_   [pwu::Plane set { 0 0 1 } {0 0 -50}]
    set AutoField::flowDirection_ {-1 0 0}

    set AutoField::nfSpacing_     32.0

    set AutoField::blInitialDs_   0.01
    set AutoField::blGrowthRate_  1.2

    set AutoField::wakeBlkDist_       1000
    set AutoField::wakeBlkSpacing_    32
    set AutoField::wakeBlkGrowthRate_ 1.05

    set AutoField::ffSpacing_     32.0
    set AutoField::ffGrowthRate_  1.05
    set AutoField::ffMargins_     {1000 1500 1000 1000 0 5000}

    # Instead of farfield spacing, allow the user to specify
    # specific region spacing
    set AutoField::upSpacing_     32.0
    set AutoField::upGrowthRate_  1.05
    set AutoField::upMargins_     {1000 1500 1000 1000 0 5000}

    set AutoField::rightSideSpacing_     32.0
    set AutoField::rightSideGrowthRate_  1.05
    set AutoField::rightSideMargins_     {1000 1500 1000 1000 0 5000}

    set AutoField::leftSideSpacing_     32.0
    set AutoField::leftSideGrowthRate_  1.05
    set AutoField::leftSideMargins_     {1000 1500 1000 1000 0 5000}
  }



pw::Application load [file join $scriptDir bodyDomains-NoDb-HALF.pw]

if { [getDomains doms] } {
  AutoField setVerbose

  # Input parameters to use
  #set AutoField::groundPlane_   [pwu::Plane set { 0 0 1 } {0 0 -50}]
  #set AutoField::flowDirection_ {-1 0 0}

  AutoField setNearFieldBC x- Margin 110.0
  AutoField setNearFieldBC x+ Margin 220.0
  AutoField setNearFieldBC y- Symmetry
  AutoField setNearFieldBC y+ Margin 240.0
  AutoField setNearFieldBC z- Wall 0.01 1.2 DropShadow
  AutoField setNearFieldBC z+ Margin 150.0

if {0} {
  set AutoField::nfSpacing_     32.0

  set AutoField::blInitialDs_   0.01
  set AutoField::blGrowthRate_  1.2

  set AutoField::wakeBlkDist_       1000
  set AutoField::wakeBlkSpacing_    32
  set AutoField::wakeBlkGrowthRate_ 1.05

  set AutoField::ffSpacing_     32.0
  set AutoField::ffGrowthRate_  1.05
  set AutoField::ffMargins_     {1000 1500 1000 1000 0 5000}

  # Instead of farfield spacing, allow the user to specify
  # specific region spacing
#   set AutoField::upSpacing_     32.0
#   set AutoField::upGrowthRate_  1.05
#   set AutoField::upMargins_     {1000 1500 1000 1000 0 5000}
#
#   set AutoField::rightSideSpacing_     32.0
#   set AutoField::rightSideGrowthRate_  1.05
#   set AutoField::rightSideMargins_     {1000 1500 1000 1000 0 5000}
#
#   set AutoField::leftSideSpacing_     32.0
#   set AutoField::leftSideGrowthRate_  1.05
#   set AutoField::leftSideMargins_     {1000 1500 1000 1000 0 5000}
}

  AutoField run $doms
  AutoField::dump
}
