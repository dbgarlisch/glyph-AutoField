if { [namespace exists AutoField] } {
  return 1
}
package require PWI_Glyph 2.18

# Inputs
# Domains to be wrapped
# Ground Plane location
# Primary flow direction
# Nearfield Margins (factor of extent)
# Nearfield edge length
# Ground plane boundary layer info
#   Initial dS
#   Growth Rate

# Farfield Parameters
#   Growth Rate
#   Spacing
#   Distance

# Wake params
#   Distance
#   Spacing
#   Growth Rate

# Todo
# Apply distributions on vertical connectors
# Split extruded blocks into constituent parts
# TRex boundary conditions???


# All nearfield (NF) settings are stored in the dictionary AutoField::db_. Some
# of these settings are set by the user prior to running, others are populated
# during the run by this script.
#
# For instance, as the NF grid entities are created at runtime, they are stored
# in AutoField::db_ under the root key "Grid":
#     dict set db_ Grid Points n {x y z} ;# where n is point number 0, 1, etc
#     dict set db_ Grid Cons n con  ;# where n is 0, 1, etc
#     dict set db_ Grid Domains bcId dom ;# where bcId is -x, +x, etc
#
# The nearfield topology numbering follows the same scheme used for the
# Pointwise Hex cell connectivity defined at:
#    http://www.pointwise.com/plugins/html/cell-topology-hex.png
#
# where,
#   * +x, -x are faces 3, 5
#   * +y, -y are faces 4, 2
#   * +z, -z are faces 1, 0
#   * edge n are edge n
#   * point n is node n


########################################################################
########################################################################
########################################################################

namespace eval AutoField {

  # Input Parameters
  #variable groundPlane_        ;# Ground Plane entity
  #variable flowDirection_      ;# Flow direction vector
  #variable nfSpacing_          ;# NearField Edge Length
  #variable blInitialDs_        ;# Boundary Layer intial delta s
  #variable blGrowthRate_       ;# Boundary Layer growth rate
  #
  #variable wakeBlkDist_        ;# Wake block Distance
  #variable wakeBlkSpacing_     ;# Wake block Spacing
  #variable wakeBlkGrowthRate_  ;# Wake block growth rate
  #
  #variable ffSpacing_          ;# Farfield Edge Length
  #variable ffGrowthRate_       ;# Farfield growth rate
  #variable ffMargins_          ;# Farfield margins

  #variable dropShadowSpacing_
  #variable dropShadowGrowthRate_

  # TODO: replace ff spacing with these parameters
  #variable upSpacing_               ;# Farfield Up Edge Length
  #variable upGrowthRate_            ;# Farfield Up growth rate
  #variable upMargins_               ;# Farfield Up margins
  #
  #variable rightSideSpacing_        ;# Farfield right side Edge Length
  #variable rightSideGrowthRate_     ;# Farfield right side growth rate
  #variable rightSideMargins_        ;# Farfield right side margins
  #
  #variable leftSideSpacing_         ;# Farfield left side Edge Length
  #variable leftSideGrowthRate_      ;# Farfield left side growth rate
  #variable leftSideMargins_         ;# Farfield left side margins

  # Runtime variables
  variable tol_           [pw::Database getSamePointTolerance]
  variable validBcIds_    {x+ x- y+ y- z+ z-}
  variable validBcTypes_  {Margin Symmetry Wall}
  variable db_            [dict create]   ;# Runtime settings


  #========================================================================
  # PUBLIC PROCS
  #========================================================================

  namespace export run
  proc run { doms } {
    pw::Display setCurrentLayer 5
    ctor $doms
    validateRuntimeSettings
    buildNearField
    #buildFarField
  }

  namespace export setNearFieldBC
  proc setNearFieldBC { bcId type args } {
    assertIsBcId $bcId
    assertIsBcType [set type [string trim $type]]
    unsetNearFieldBCVal $bcId ;# unsets everything for $bcId
    setNearFieldBCVal $bcId Type $type
    # always define distance - may be changed by type call below
    setNearFieldBCVal $bcId Distance 0.0
    set procName "setNearField$type"
    if { ![assertIsCallable $procName 0] } {
      return -code error "Invalid BC type ($type)"
    }
    if { [catch {$procName $bcId {*}$args} err] } {
      return -code error $err
    }
    return 1
  }

  namespace export setVerbose
  variable verbose_   0
  proc setVerbose { {onOff 1} } {
    variable verbose_
    set verbose_ $onOff
  }


  #========================================================================
  # PRIVATE PROCS
  #========================================================================

  proc ctor { doms } {
    # capture all doms to be "wrapped" by NF
    setGridVal SurfDoms $doms

    # compute axis-aligned dom extents
    setGridVal SurfDomExts [set exts [getExtents $doms]]

    # compute margin-inflated NF extents
    setGridVal NearFieldExts [set nfExts [adjustExtents $exts]]

    # compute corner points of the NF extents
    setGridVal Points [createCornerPtsFromExts $nfExts]

    # compute base (two point) edges for NF extents. The ctor$Type calls might
    # insert shadow or lamina connector (open loop) end points into edges.
    setGridVal NearFieldEdgeDb [initNfEdgeDbFromExts $nfExts]

    # Capture all lamina cons
    setGridVal LaminaCons [getLaminaCons $doms]

    # Preload with all lamina cons. May get reduced by ctor$Type calls.
    set unusedLaminaCons [getGridVal LaminaCons]
    foreachBC {
      # Capture plane on $nfExts boundary that corresponds to $Id
      setNearFieldBCVal $Id ExtPlane [calcExtentsPlane $Id $nfExts]
      # Invoke BC specific ctor.
      assertIsCallable [set procName "ctor${Type}"]
      $procName $Id unusedLaminaCons
    }

    # Capture the lamina cons that are NOT coplanar with any of the BC planes
    setGridVal UnusedLaminaCons $unusedLaminaCons

    foreachBC {
      # Invoke BC specific finalize.
      assertIsCallable [set procName "ctorFinalize${Type}"]
      $procName $Id
    }
  }

  proc ctorWall { Id unusedLaminaConsVar } {
    # Update runtime data for this Wall BC
    upvar $unusedLaminaConsVar unusedLaminaCons
    set bcPlane [getNearFieldBCVal $Id ExtPlane]
    set shadowCons {}
    if { [getNearFieldBCVal $Id ShadowType] == "DropShadow" } {
      # Capture drop shadow corner points
      #setNearFieldBCVal $Id DropShadowPts \
      #  [set pts [projectExtsToRectInPlane [getGridVal SurfDomExts] $bcPlane]]
      set pts [projectExtsToRectInPlane [getGridVal SurfDomExts] $bcPlane]
      # Add shadow points to edges with which they are colinear
      set ptInfo {}
      foreach pt $pts {
        set ptType [insertPtIntoAllNfEdges $pt SrcDropShadow]
        switch -- $ptType {
        ColinearDup -
        ColinearNew {
          lappend ptInfo Edge $pt
        }
        NotColinear {
          lappend ptInfo Interior $pt
        }
        default {
          return -code error "Unexpected shadow point type ($ptType)"
        }}
      }

      # build drop shadow cons that do NOT lie on outer loop edge
      # grab first pair as previous pt
      set ptInfo [lassign $ptInfo prevUsage prevPt]
      # append first pair again to make logic simpler
      lappend ptInfo $prevUsage $prevPt
      for {set ii 0} {$ii < 4} {incr ii} {
        set ptInfo [lassign $ptInfo usage pt]
        if { "${prevUsage}${usage}" != "EdgeEdge" } {
          # create shadow connector
          set con [createCon $prevPt $pt]
          $con setName "ShadowCon-1"
          lappend shadowCons $con
        }
        set prevUsage $usage
        set prevPt $pt
      }
    }
    # Capture drop shadow cons
    setNearFieldBCVal $Id DropShadowCons $shadowCons
    # Capture lamina cons that are coplanar with $bcPlane.
    setNearFieldBCVal $Id InPlnCons \
      [getInPlaneCons $unusedLaminaCons $bcPlane unusedLaminaCons]
  }

  proc ctorFinalizeWall { Id } {
    buildLaminaEdges $Id
  }

  proc ctorSymmetry { Id unusedLaminaConsVar } {
    # Update runtime data for this Symmetry BC
    upvar $unusedLaminaConsVar unusedLaminaCons
    set bcPlane [getNearFieldBCVal $Id ExtPlane]
    # Capture lamina cons that are coplanar with $bcPlane.
    setNearFieldBCVal $Id InPlnCons \
      [getInPlaneCons $unusedLaminaCons $bcPlane unusedLaminaCons]
  }

  proc ctorFinalizeSymmetry { Id } {
    # At this point, all BCs have been associated with their lamina cons and
    # all near field edges have been split as needed to account for any drop
    # shadows. This final pass will now look for unclosed loops in Symmetry BCs.
    # To be valid, unclosed loop end points MUST lie in a near field edge. This
    # will cause a gap in the near field edge. When assembling the Symmetry
    # domain, the near field outer edges combined with the unclosed loop(s)
    # will form the BC domains outer loop.
    #
    #  .----------.      .----------.
    #  |  .----.  |      |  .----.  |
    #  |  |    |  |      |  |    |  |  <-- closed lamina symmetry edge
    #  |  `----'  |      |  `----'  |
    #  |  .----.  |  =>  |  .----.  |
    #  |  |    |  |      |  |    |  |  <-- unclosed lamina symmetry edge merges
    #  |  |    |  |      |  |    |  |      with domain's outer edge
    #  '--'----'--'      '--'    '--'
    #
    # It is not checked here, but to be valid, the other BC domain along this
    # edge will need to be a Wall with another unclosed closed loop that spans
    # this gap.
    buildLaminaEdges $Id
  }

  proc ctorMargin { Id unusedLaminaConsVar } {
    # Update runtime data for this Margin BC
    #upvar $unusedLaminaConsVar unusedLaminaCons
    # NOP
  }

  proc ctorFinalizeMargin { Id } {
    # NOP
  }

  proc validateRuntimeSettings {} {
    set shadowCnt 0
    set symmetryCnt 0
    foreachBC {
      switch $Type {
      Wall {
        if { "$ShadowType" == "DropShadow" } {
          incr shadowCnt
        }
      }
      Symmetry {
        incr symmetryCnt
      }
      Margin {
      }
      default {
        # NOP
      }}
    }
    assertRange $shadowCnt 0 1 ": DropShadow Count"
    assertRange $symmetryCnt 0 1 ": Symmetry BC Count"
  }

  proc buildNearField {} {
    set edgeDb [getGridVal NearFieldEdgeDb]
    setGridVal Cons [createEdgeCons $edgeDb "NfEdgeCon_"]
    # Maps each bndry face (bcId) to its loop edges and edge's neighbor face.
    # For example,
    #    x+ has neighbor face z- across edge 1
    # bcId {EdgeIdList EdgeNeighborFaceList}
    set bndryEdgeMap {
      x+ {{ 1 10  5  9} {z- y+ z+ y-}}
      x- {{ 3  8  7 11} {z- y- z+ y+}}
      y+ {{ 2 11  6 10} {z- x- z+ x+}}
      y- {{ 0  9  4  8} {z- x+ z+ x-}}
      z+ {{ 4  5  6  7} {y- x+ y+ x-}}
      z- {{ 0  1  2  3} {y- x+ y+ x-}}
    }
    foreachBC {
      assertIsCallable [set procName "createNearFieldDom${Type}"]
      $procName $Id {*}[dict get $bndryEdgeMap $Id]
    }

    # Car Drop shadow points
    #set domExtents [getGridVal SurfDomExts]
    #lassign [getPt 0] minx miny minz
    #lassign [lindex $domExtents 0] dbMinx dbMiny dbMinz
    #lassign [lindex $domExtents 1] dbMaxx dbMaxy dbMaxz
    #setGridVal Points 8 [list $dbMinx $dbMiny $minz]
    #setGridVal Points 9 [list $dbMaxx $dbMiny $minz]
    #setGridVal Points 10 [list $dbMaxx $dbMaxy $minz]
    #setGridVal Points 11 [list $dbMinx $dbMaxy $minz]
    #createGrndPlnDoms

    #set doms [getGridVal SurfDoms]
    #lappend doms [getDom DF]
    #lappend doms [getDom DG]
    #
    #set cons [getEdgeCons CA]
    #lappend cons [setCon CF [createCon [getPt 1] [getPt 5]]]
    #setConSpacing [getEdgeCons CF] $blGrowthRate_ $nfSpacing_ $blInitialDs_ $nfSpacing_
    #lappend cons [setCon CI [createCon [getPt 5] [getPt 4]]]
    #lappend cons [setCon CE [createCon [getPt 4] [getPt 0]]]
    #setConSpacing [getEdgeCons CE] $blGrowthRate_ $nfSpacing_ $nfSpacing_ $blInitialDs_
    #lappend doms [setDom DA [pw::DomainStructured createFromConnectors $cons]]
    #
    #
    #set cons [getEdgeCons CB]
    #lappend cons [setCon CG [createCon [getPt 2] [getPt 6]]]
    #setConSpacing [getEdgeCons CG] $blGrowthRate_ $nfSpacing_ $blInitialDs_ $nfSpacing_
    #lappend cons [setCon CJ [createCon [getPt 6] [getPt 5]]]
    #lappend cons [getEdgeCons CF]
    #lappend doms [setDom DB [pw::DomainStructured createFromConnectors $cons]]
    #
    #
    #set cons [getEdgeCons CC]
    #lappend cons [getEdgeCons CG]
    #lappend cons [setCon CK [createCon [getPt 6] [getPt 7]]]
    #lappend cons [setCon CH [createCon [getPt 7] [getPt 3]]]
    #setConSpacing [getEdgeCons CH] $blGrowthRate_ $nfSpacing_ $nfSpacing_ $blInitialDs_
    #lappend doms [setDom DC [pw::DomainStructured createFromConnectors $cons]]
    #
    #
    #set cons [getEdgeCons CD]
    #lappend cons [getEdgeCons CH]
    #lappend cons [setCon CL [createCon [getPt 7] [getPt 4]]]
    #lappend cons [getEdgeCons CE]
    #lappend doms [setDom DD [pw::DomainStructured createFromConnectors $cons]]
    #
    #
    #set cons [getEdgeCons CI]
    #lappend cons [getEdgeCons CJ]
    #lappend cons [getEdgeCons CK]
    #lappend cons [getEdgeCons CL]
    #lappend doms [setDom DE [pw::DomainStructured createFromConnectors $cons]]
    #
    #set blk [setBlk NearFieldBlk [pw::BlockUnstructured createFromDomains $doms]]
    #$blk setName "Near Field"
    #$blk setLayer -parents 9
    #pw::Layer setDescription 9 {Near Field Block}
    #if { ![$blk isValid] } {
    #  puts "Nearfield Block is not valid."
    #}
    #
    #set mode [pw::Application begin Dimension]
    #setConEdgeLength [getEdgeCons CA] $nfSpacing_
    #setConEdgeLength [getEdgeCons CB] $nfSpacing_
    #setConEdgeLength [getEdgeCons CM] $nfSpacing_
    #setConEdgeLength [getEdgeCons CN] $nfSpacing_
    #setConEdgeLength [getEdgeCons CO] $nfSpacing_
    #setConEdgeLength [getEdgeCons CP] $nfSpacing_
    ## Connectors CF, CG, CH, CE had their edge lengths set above by setConSpacing.
    #$mode balance -resetGeneralDistributions
    #$mode end
  }

  proc createCornerPtsFromExts { exts } {
    # Calc the corner points on the $exts box hex where the hex is defined by
    # a baseQuad(pt0,pt3) and topQuad(pt4,pt7). The baseQuad normal points
    # towards the topQuad. The topQuad normal is same direction as the baseQuad.
    set ret [dict create]
    dict set ret 0 [set min [lindex $exts 0]]
    dict set ret 6 [set max [lindex $exts 1]]
    lassign $min minx miny minz
    lassign $max maxx maxy maxz
    dict set ret 1 [list $maxx $miny $minz]
    dict set ret 2 [list $maxx $maxy $minz]
    dict set ret 3 [list $minx $maxy $minz]
    dict set ret 4 [list $minx $miny $maxz]
    dict set ret 5 [list $maxx $miny $maxz]
    dict set ret 7 [list $minx $maxy $maxz]
    return $ret
  }

  proc initNfEdgeDbFromExts { exts } {
    # Calc initial hex edges as end-points on the $exts box. More points may be
    # inserted into the edge by subsequent operations.
    set pts [createCornerPtsFromExts $exts]
    set edgeDb [dict create]
    # base edges
    dict set edgeDb  0 Pts  [list [dict get $pts 0] [dict get $pts 1]]
    dict set edgeDb  0 Srcs [list SrcCorner SrcCorner]
    dict set edgeDb  1 Pts  [list [dict get $pts 1] [dict get $pts 2]]
    dict set edgeDb  1 Srcs [list SrcCorner SrcCorner]
    dict set edgeDb  2 Pts  [list [dict get $pts 2] [dict get $pts 3]]
    dict set edgeDb  2 Srcs [list SrcCorner SrcCorner]
    dict set edgeDb  3 Pts  [list [dict get $pts 3] [dict get $pts 0]]
    dict set edgeDb  3 Srcs [list SrcCorner SrcCorner]
    # top edges
    dict set edgeDb  4 Pts  [list [dict get $pts 4] [dict get $pts 5]]
    dict set edgeDb  4 Srcs [list SrcCorner SrcCorner]
    dict set edgeDb  5 Pts  [list [dict get $pts 5] [dict get $pts 6]]
    dict set edgeDb  5 Srcs [list SrcCorner SrcCorner]
    dict set edgeDb  6 Pts  [list [dict get $pts 6] [dict get $pts 7]]
    dict set edgeDb  6 Srcs [list SrcCorner SrcCorner]
    dict set edgeDb  7 Pts  [list [dict get $pts 7] [dict get $pts 4]]
    dict set edgeDb  7 Srcs [list SrcCorner SrcCorner]
    # base to top edges
    dict set edgeDb  8 Pts  [list [dict get $pts 0] [dict get $pts 4]]
    dict set edgeDb  8 Srcs [list SrcCorner SrcCorner]
    dict set edgeDb  9 Pts  [list [dict get $pts 1] [dict get $pts 5]]
    dict set edgeDb  9 Srcs [list SrcCorner SrcCorner]
    dict set edgeDb 10 Pts  [list [dict get $pts 2] [dict get $pts 6]]
    dict set edgeDb 10 Srcs [list SrcCorner SrcCorner]
    dict set edgeDb 11 Pts  [list [dict get $pts 3] [dict get $pts 7]]
    dict set edgeDb 11 Srcs [list SrcCorner SrcCorner]

    return $edgeDb
  }

  proc buildLaminaEdges { Id } {
    # get this BC's in-plane lamina cons
    set inPlaneCons [getNearFieldBCVal $Id InPlnCons]
    set closedEdgeCons [list]
    set unclosedEdgeCons [list]
    foreach edge [pw::Edge createFromConnectors $inPlaneCons] {
      if { [$edge isClosed] } {
        # cache the inner edge loop connectors
        lappend closedEdgeCons [getConsFromPwEdge $edge]
      } else {
        # Found an unclosed edge. Imprint endpoints on outer loop.
        imprintEndPt [[$edge getNode Begin] getXYZ] "begin"
        imprintEndPt [[$edge getNode End] getXYZ] "end"
        lappend unclosedEdgeCons [getConsFromPwEdge $edge]
      }
    }
    setNearFieldBCVal $Id InPlnClosedEdgeCons $closedEdgeCons
    setNearFieldBCVal $Id InPlnUnclosedEdgeCons $unclosedEdgeCons
  }


  proc imprintEndPt { xyz which } {
    set ptType [insertPtIntoAllNfEdges $xyz SrcInPlnCons]
    switch -- $ptType {
    ColinearDup -
    ColinearNew {
      # all is good
    }
    default {
      return -code error "Unclosed edge $which node not on boundary ($ptType)"
    }}
  }


  proc insertPtIntoAllNfEdges { pt src } {
    set ptType {}
    set edgeDb [getGridVal NearFieldEdgeDb]
    set edgeDbChanged 0
    for {set ii 0} {$ii < 12} {incr ii} {
      if { [insertPtIntoEdgeNdx edgeDb $ii $pt $src ptType] } {
        # $pt added to edge $ii (ptType = ColinearNew)
        set edgeDbChanged 1
        break ;# we can stop looking
      } elseif { [string match Colinear* $ptType] } {
        # $pt is colinear with but not added to edge because a point already
        # exists (ptType = ColinearDup), or $pt is at or outside of edge's endpoints
        # (ptType = ColinearLT0, Colinear0, Colinear1, or ColinearGT1).
        break ;# we can stop looking
      }
    }
    if { $edgeDbChanged } {
      setGridVal NearFieldEdgeDb $edgeDb
    }
    return $ptType
  }

  proc getConsFromPwEdge { edge } {
    set ret [list]
    for {set ii 1} {$ii <= [$edge getConnectorCount]} {incr ii} {
      lappend ret [$edge getConnector $ii]
    }
    return $ret
  }

  proc insertPtIntoEdgeNdx { edgeDbVar ndx pt src ptTypeVar } {
    upvar $edgeDbVar edgeDb
    upvar $ptTypeVar ptType
    assertValidEdgeIndex $ndx
    set ret 0
    set edgeInfo [dict get $edgeDb $ndx]
    if { [insertColinearEdgePt edgeInfo $pt $src ptType] } {
      # $pt was added to $edge - update $edges
      dict set edgeDb $ndx $edgeInfo
      set ret 1
    }
    return $ret
  }

  proc insertColinearEdgePt { edgeInfoVar pt src ptTypeVar } {
    upvar $edgeInfoVar edgeInfo
    upvar $ptTypeVar ptType
    set ret 0
    set ptType NotColinearUnknown
    set edgePts [dict get $edgeInfo Pts]
    set begEdgePt [lindex $edgePts 0]
    set endEdgePt [lindex $edgePts end]
    if { ![ptIsColinearTo $pt $begEdgePt $endEdgePt s] } {
      # $pt does not lie on edge - skip it
      set ptType NotColinear
    } elseif { $s < 0.0 } {
      # bad - pt is before segment start point
      set ptType ColinearLT0
    } elseif { $s > 1.0 } {
      # bad - pt is after segment end point
      set ptType ColinearGT1
    } elseif { $s == 0.0 } {
      # $pt is coincident with segment start point
      set ptType Colinear0
    } elseif { $s == 1.0 } {
      # $pt is coincident with segment end point
      set ptType Colinear1
    } else {
      # $pt is between $begEdgePt $endEdgePt
      set numEdgePts [llength $edgePts]
      # distance from $begEdgePt to $pt
      set distPt [distPtToPt $begEdgePt $pt]
      # Find the edge point before which $pt should be inserted. No need to
      # check the first edge point. Checking last pt is overkill but it makes
      # logic simpler.
      for {set ii 1} {$ii < $numEdgePts} {incr ii} {
        set edgePt [lindex $edgePts $ii]
        set dist0 [distPtToPt $begEdgePt $edgePt]
        if { [areEqual $dist0 $distPt] } {
          # $pt and $edgePt are equal (same distance from $begEdgePt)!
          set ptType ColinearDup
          break
        } elseif { $distPt < $dist0 } {
          # $pt is between prev edge pt and $edgePt. Insert $pt into $edgePts
          # just before $ii and break
          dict set edgeInfo Pts [linsert $edgePts $ii $pt]
          dict set edgeInfo Srcs [linsert [dict get $edgeInfo Srcs] $ii $src]
          set ret 1
          set ptType ColinearNew
          break
        }
      }
    }
    return $ret
  }

  proc assertValidEdgeIndex { ndx } {
    assertRange $ndx 0 11 "Edge Index"
  }

  proc ptIsColinearTo { pt end0 end1 sVar } {
    upvar $sVar s
    set s UNDEF
    set ret 1
    set dir [pwu::Vector3 subtract $end1 $end0]
    set segLen [pwu::Vector3 length $dir]
    if { [isZero $segLen] } {
      set ret 0 ;# bad segment
    } elseif { [ptsAreEqual $end0 $pt] } {
      set s 0.0
    } elseif { [ptsAreEqual $end1 $pt] } {
      set s 1.0
    } elseif { ![isZero [pwu::Vector3 distanceToLine $pt $end0 $dir]] } {
      set ret 0 ;# pt is not colinear
    } else {
      # find largest segment length delta to give s calc best precision
      lassign $dir dx dy dz
      if { $dx > $dy } {
        if { $dx > $dz } {
          set n 0 ;# dx is largest delta
        } else {
          set n 2 ;# dz is largest delta
        }
      } elseif { $dy > $dz } {
        set n 1 ;# dy is largest delta
      } else {
        set n 2 ;# dz is largest delta
      }
      # s = (pt.N - end0.N) / dir.N
      # where,
      #   dir.N = (end1.N - end0.N)
      #   N is x, y, or z component
      set s [expr {([lindex $pt $n] - [lindex $end0 $n]) / [lindex $dir $n]}]
    }
    return $ret
  }

  proc distPtToPt { pt0 pt1 } {
    return [pwu::Vector3 length [pwu::Vector3 subtract $pt0 $pt1]]
  }

  proc createEdgeCons { edgeDb {baseNm ""} } {
    set ret [dict create]
    for {set ii 0} {$ii < 12} {incr ii} {
      set edgePts [dict get $edgeDb $ii Pts]
      set edgeSrcs [dict get $edgeDb $ii Srcs]
      # init edge $ii cons to empty list
      dict set ret $ii [list]
      # shift out first edge point into pt0
      set edgePts [lassign $edgePts pt0]
      if { [llength $edgePts] > 1 } {
        # edge has more than one con - use numeric suffix
        set nameSfx "-1"
      } else {
        set nameSfx ""
      }
      # create con between each successive pair of pts in edge if !$isGap
      set isGap 0
      while { 0 != [llength $edgePts] } {
        # shift out next edge point into pt1
        set edgePts [lassign $edgePts pt1]
        # shift out edge point src type into src0
        set edgeSrcs [lassign $edgeSrcs src0]
        # deal with pt src type
        switch -- $src0 {
        SrcInPlnCons {
          # either start or end pt of a gap caused by unclosed in plane cons.
          # First gap pt will set isGap 1, second will set it back to 0
          set isGap [expr {!$isGap}]
        }
        SrcCorner -
        SrcDropShadow {
          # NOP
        }
        default {
          return -code error "Unexpected edge point source type"
        }}
        if { !$isGap } {
          set con [createCon $pt0 $pt1]
          #puts "### con: $con [list $pt0 $pt1]"
          $con setName "$baseNm$ii$nameSfx"
          # append $con to edge $ii
          dict lappend ret $ii $con
        }
        # prepare pt0 for possible next pass
        set pt0 $pt1
      }
    }
    return $ret
  }

  proc projectExtsToRectInPlane { exts pln } {
    lassign $exts minPt maxPt
    set pt0 [pwu::Plane project $pln $minPt]
    set pt2 [pwu::Plane project $pln $maxPt]
    set diag [pwu::Vector3 subtract $pt2 $pt0]
    lassign $diag dx dy dz
    if { [isZero $dx] } {
      # in YZ plane
      set pt1 [pwu::Vector3 add $pt0 [list 0 $dy   0]]
      set pt3 [pwu::Vector3 add $pt0 [list 0   0 $dz]]
    } elseif { [isZero $dy] } {
      # in XZ plane
      set pt1 [pwu::Vector3 add $pt0 [list $dx 0   0]]
      set pt3 [pwu::Vector3 add $pt0 [list 0   0 $dz]]
    } elseif { [isZero $dz] } {
      # in XY plane
      set pt1 [pwu::Vector3 add $pt0 [list $dx   0 0]]
      set pt3 [pwu::Vector3 add $pt0 [list 0   $dy 0]]
    } else {
      return -code error \
        "Unexpected projection in projectExtsToRectInPlane [list $diag]"
    }
    #[pw::Point create] setPoint $pt0
    #[pw::Point create] setPoint $pt1
    #[pw::Point create] setPoint $pt2
    #[pw::Point create] setPoint $pt3
    return [list $pt0 $pt1 $pt2 $pt3]
  }

  proc createNearFieldDomWall { bcId edgeIds edgeBcIds } {
    set shadowCons [getNearFieldBCVal $bcId DropShadowCons]
    if { 0 != [llength $shadowCons] } {
      # TODO
    } else {
      # TODO
    }
    set cons {}
    foreach edgeId $edgeIds edgeBcId $edgeBcIds {
      lappend cons {*}[getEdgeCons $edgeId]
    }
    set unclosedEdgeCons [getNearFieldBCVal $bcId InPlnUnclosedEdgeCons]
    set closedEdgeCons [getNearFieldBCVal $bcId InPlnClosedEdgeCons]
    if { 0 != [llength $unclosedEdgeCons] + [llength $closedEdgeCons] } {
      # outer loop uses inplane cons AND/OR there are inner loops
      foreach unclosedCons $unclosedEdgeCons {
        lappend cons {*}$unclosedCons
      }
      set dom [setDom $bcId [pw::DomainUnstructured createFromConnectors $cons]]
      set cons {}
      foreach closedCons $closedEdgeCons {
        lappend cons {*}$closedCons
      }
      insertLoopEdges $dom $cons
    } else {
      # outer loop does not use inplane cons AND there are zero inner loops
      setDom $bcId [pw::DomainStructured createFromConnectors $cons]
    }
  }

  proc createNearFieldDomMargin { bcId edgeIds edgeBcIds } {
    set cons {}
    foreach edgeId $edgeIds edgeBcId $edgeBcIds {
      lappend cons {*}[getEdgeCons $edgeId]
    }
    setDom $bcId [pw::DomainStructured createFromConnectors $cons]
  }

  proc createNearFieldDomSymmetry { bcId edgeIds edgeBcIds } {
    set cons {}
    foreach edgeId $edgeIds edgeBcId $edgeBcIds {
      lappend cons {*}[getEdgeCons $edgeId]
    }
    set unclosedEdgeCons [getNearFieldBCVal $bcId InPlnUnclosedEdgeCons]
    foreach unclosedCons $unclosedEdgeCons {
      lappend cons {*}$unclosedCons
    }
    set dom [setDom $bcId [pw::DomainUnstructured createFromConnectors $cons]]
    set cons {}
    foreach closedCons [getNearFieldBCVal $bcId InPlnClosedEdgeCons] {
      lappend cons {*}$closedCons
    }
    insertLoopEdges $dom $cons
  }

  #proc publishNearFieldBCVals { bcId {pfx ""} } {
  #  dict for {key val} [getNearFieldBCVal $bcId] {
  #    uplevel 1 set ${pfx}$key [list $val]
  #  }
  #}

  #proc buildFarField {} {
  #    extrudeWakeBlock
  #    extrudePostWakeBlock
  #    extrudeUpStreamBlock
  #    extrudeLeftSide
  #    extrudeRightSide
  #    extrudeUp
  #}

  proc calcExtentsPlane { bcId exts } {
    assertIsBcId $bcId
    # plane normal points to outside of ext box
    lassign $exts minPt maxPt
    switch $bcId {
    x- {
      return [pwu::Plane set {-1  0  0} $minPt] }
    x+ {
      return [pwu::Plane set {+1  0  0} $maxPt] }
    y- {
      return [pwu::Plane set { 0 -1  0} $minPt] }
    y+ {
      return [pwu::Plane set { 0 +1  0} $maxPt] }
    z- {
      return [pwu::Plane set { 0  0 -1} $minPt] }
    z+ {
      return [pwu::Plane set { 0  0 +1} $maxPt] }
    }
  }

  proc getGridVal { args } {
    variable db_
    return [dict get $db_ Grid {*}$args]
  }

  proc setGridVal { args } {
    # setGridVal key ?key ...? value
    if { [llength $args] < 2 } {
      return -code error "wrong # args: should be \"setGridVal key ?key ...? value\""
    }
    variable db_
    dict set db_ Grid {*}$args
  }

  proc getNearFieldBCVal { bcId args } {
    variable db_
    return [dict get $db_ NearFieldBC $bcId {*}$args]
  }

  proc setNearFieldBCVal { bcId args } {
    # setNearFieldBCVal bcId ?key ...? value
    if { [llength $args] < 2 } {
      return -code error "wrong # args: should be \"setNearFieldBCVal bcId ?key ...? value\""
    }
    variable db_
    return [dict set db_ NearFieldBC $bcId {*}$args]
  }

  proc unsetNearFieldBCVal { args } {
    unsetSetting NearFieldBC {*}$args
  }

  proc nearFieldBCValExists { args } {
    return [settingExists NearFieldBC {*}$args]
  }

  proc settingExists { args } {
    variable db_
    return [dict exists $db_ {*}$args]
  }

  proc unsetSetting { args } {
    variable db_
    if { [dict exists $db_ {*}$args] } {
      dict unset db_ {*}$args
    }
  }

  proc foreachBC { args } {
    switch [llength $args] {
    1 { set pfx [lassign $args body] }
    2 { lassign $args pfx body }
    default {
      return -code error {wrong # args: should be "foreachBC ?pfx? body"}
    }}
    set pfx [string trim $pfx]
    variable validBcIds_
    foreach bcId $validBcIds_ {
      set pfxKeys ${pfx}Id
      uplevel 1 set ${pfx}Id $bcId
      dict for {key val} [getNearFieldBCVal $bcId] {
        uplevel 1 set ${pfx}$key [list $val]
        lappend pfxKeys ${pfx}$key
      }
      uplevel 1 set _BCPARAMS [list $pfxKeys]
      uplevel 1 $body
    }
  }

  proc setNearFieldWall { bcId initDs growthRate shadowType {distance 0.0} } {
    assertIsDouble $initDs "Wall InitDs"
    assertIsDouble $growthRate "Wall GrowthRate"
    assertIsShadowType $shadowType
    assertRange $distance 0 Inf "Wall Distance"
    setNearFieldBCVal $bcId InitDs $initDs
    setNearFieldBCVal $bcId GrowthRate $growthRate
    setNearFieldBCVal $bcId ShadowType $shadowType
    setNearFieldBCVal $bcId Distance $distance
  }

  proc setNearFieldSymmetry { bcId } {
    # no other params
  }

  proc setNearFieldMargin { bcId distance } {
    assertIsDouble $distance "Margin distance"
    assertRange $distance {> 0} Inf "Margin Distance"
    setNearFieldBCVal $bcId Distance $distance
  }

  proc assertInList { val goodVals {valDesc "key"} {errorIfInvalid 1} } {
    if { $val in $goodVals } {
      return 1
    } elseif { $errorIfInvalid } {
      return -code error "Invalid $valDesc: $val not one of [list $goodVals]."
    }
    return 0
  }

  proc assertIsBcId { val {errorIfInvalid 1} } {
    variable validBcIds_
    return [assertInList $val $validBcIds_ "BcId" $errorIfInvalid]
  }

  proc assertIsBcType { val {errorIfInvalid 1} } {
    variable validBcTypes_
    return [assertInList $val $validBcTypes_ "BcType" $errorIfInvalid]
  }

  proc assertIsShadowType { val {errorIfInvalid 1} } {
    return [assertInList $val {NoShadow DropShadow} "ShadowType" $errorIfInvalid]
  }

  proc assertIsDouble { val {msg ""} {errorIfInvalid 1} } {
    if { [string is double -strict $val] } {
      return 1
    } elseif { $errorIfInvalid } {
      return -code error "Value is not a double ${msg}($val)."
    }
    return 0
  }

  proc assertIsInteger { val {msg ""} {errorIfInvalid 1} } {
    if { [string is integer -strict $val] } {
      return 1
    } elseif { $errorIfInvalid } {
      return -code error "Value is not an integer ${msg}($val)."
    }
    return 0
  }

  proc parseOpVal { opVal allowedOps opVar valVar} {
    upvar $opVar op
    upvar $valVar val
    switch -- [llength $opVal] {
    1 {
      # use first allowed op as default
      set op [lindex $allowedOps 0]
      set val $opVal
    }
    2 {
      lassign $opVal op val
    }
    default {
      return -code error \
        {Invalid Range Limit: should be "?op? val" or "Inf"}
    }}
    set val [string toupper $val]
    assertInList $op $allowedOps "Op"
  }

  proc assertRange { val minOpVal maxOpVal {msg ""} {errorIfInvalid 1} } {
    # minOpVal is {?minOp? val} or Inf
    # minOp is one of: >= >
    # maxOpVal is {?maxOp? val} or Inf
    # minOp is one of: <= <
    parseOpVal $minOpVal {>= >} minOp min
    parseOpVal $maxOpVal {<= <} maxOp max
    set minOK [expr [list "INF" eq "$min" || $val $minOp $min]]
    set maxOK [expr [list "INF" eq "$max" || $val $maxOp $max]]
    if { $minOK && $maxOK } {
      return 1
    } elseif { $errorIfInvalid } {
      return -code error \
        "Value is out of range ${msg}($val is not $minOp $min and $maxOp $max)."
    }
    return 0
  }

  proc assertIsCallable { procName {errorIfInvalid 1} } {
    if { "$procName" == [info procs $procName] } {
      return 1
    } elseif { $errorIfInvalid } {
      return -code error "Invalid proc ($procName)."
    }
    return 0
  }

  # Function that builds up the enclosing extense box for a list of domains.
  proc getExtents {doms} {
    #variable groundPlane_
    # set domExtents_ [pw::Entity getExtents $doms] ;# available in V18.1
    set ret [pwu::Extents empty]
    foreach dom $doms {
      set ext [$dom getExtents]
      set ret [pwu::Extents enclose $ret $ext]
    }
    #set gndPlnPoint [pwu::Plane project $groundPlane_ [pwu::Vector3 divide \
    #  [pwu::Vector3 add [lindex $ret 0] [lindex $ret 1]] 2.0]]
    #return [pwu::Extents enclose $ret $gndPlnPoint]
    return $ret
  }

  # Return extents inflated by the BC Distnace values
  proc adjustExtents { extents } {
     set min [lindex $extents 0]
     set max [lindex $extents 1]
     set dMin [list [getNearFieldBCVal x- Distance] \
                    [getNearFieldBCVal y- Distance] \
                    [getNearFieldBCVal z- Distance]]
     set dMax [list [getNearFieldBCVal x+ Distance] \
                    [getNearFieldBCVal y+ Distance] \
                    [getNearFieldBCVal z+ Distance]]
     set min [pwu::Vector3 subtract $min $dMin]
     set max [pwu::Vector3 add $max $dMax]
     return [list $min $max]
  }

  proc getPt {key} {
    getGridVal Points $key
  }

  #proc setBlk {key blk} {
  #  setGridVal Blocks $key $blk
  #  return $blk
  #}

  #proc getBlk {key} {
  #  getGridVal Blocks $key
  #}

  #proc setCon {key con} {
  #  setGridVal Cons $key $con
  #  $con setName $key
  #  return $con
  #}

  proc getEdgeCons {key} {
    getGridVal Cons $key
  }

  proc setDom {key dom} {
    if { "" == "$dom" } {
      return -code error "Invalid domain for setDom($key)"
    }
    setGridVal Domains $key $dom
    $dom setName "NfDom_$key"
    return $dom
  }

  #proc getDom {key} {
  #  getGridVal Domains $key
  #}

  #proc setConEdgeLength {con len} {
  #  $con resetGeneralDistributions
  #  $con setDimensionFromSpacing $len
  #}


  # Function that inserts edges formed by connectors into a domain.
  proc insertLoopEdges {dom inPlaneCons} {
    set init [pw::DomainUnstructured getInitializeInterior]
    # It is speed advantageous to turn off domain initialization
    pw::DomainUnstructured setInitializeInterior false
    set edges {}
    # Grab one of the edges
    set outerEdge [$dom getEdge 1]
    # Loop through each edge in the connectors
    foreach edge [pw::Edge createFromConnectors $inPlaneCons] {
      if { ![$edge isClosed] } {
        puts "Found unclosed edge."
        continue
      }
      # Add edge to domain if it's not open
      $dom addEdge $edge
      # Reversing the edge if the domain isn't valid
      if { ![$dom isValid] } {
        $edge reverse
      }
      # Add to edge to list of edges that form a loop
      if { [$dom isValid] } {
        vputs "Valid edge added to loop"
        lappend edges $edge
      } else {
        vputs "Could not add edge to loop."
      }
      # restore dom to its original form before orienting next inner edge.
      # All the edges gathered here will be re-added below when finished.
      $dom removeEdges -preserve
      $dom addEdge $outerEdge
    }
    # Restore domain initialization
    pw::DomainUnstructured setInitializeInterior true
    if { 0 != [llength $edges] } {
      # re-add properly oriented edges gathered above to the domain
      foreach edge $edges {
        $dom addEdge $edge
      }
      # Now we can initialize the domain
      set mode [pw::Application begin UnstructuredSolver [list $dom]]
      $mode run Initialize
      $mode end
      unset mode
    }
    # Restore domain initialization
    pw::DomainUnstructured setInitializeInterior $init
  }

  # Creates a connector from 2 points and dimensions them.
  proc createCon {pt1 pt2 {dim 10}} {
    set seg [pw::SegmentSpline create]
    $seg addPoint $pt1
    $seg addPoint $pt2
    set con [pw::Connector create]
    $con addSegment $seg
    unset seg
    $con setDimension $dim
    return $con
  }

  # Searches for connectors that are use only once
  proc getLaminaCons {doms} {
    # Loop through edges for the domains
    foreach edge [getEdges $doms] {
      # Loop through connectors for each edge
      foreach con [getEdgeConnectors $edge] {
        # Increment the connector's usage count
        dict incr conDict $con
      }
    }
    set ret {}
    dict for {con cnt} $conDict {
      if { $cnt == 1 } {
        lappend ret $con
      } else {
        # vputs "Ignoring connector. [$con getName] is used $cnt times."
      }
    }
    return $ret
  }

  proc getEdges {doms} {
    set edges {}
    foreach dom $doms {
      for {set i 1} {$i <= [$dom getEdgeCount] } {incr i} {
        lappend edges [$dom getEdge $i]
      }
    }
    return $edges
  }

  proc getEdgeConnectors {edge} {
    set ret {}
    for {set jj 1} {$jj <= [$edge getConnectorCount] } {incr jj} {
       lappend ret [$edge getConnector $jj]
    }
    return $ret
  }

  proc getInPlaneCons {cons pln {otherConsVar ""}} {
    if { "$otherConsVar" != "" } {
      upvar $otherConsVar otherCons
    }
    set otherCons {}
    set ret {}
    foreach con $cons {
      if { [conIsInPlane $con $pln] } {
        lappend ret $con
      } else {
        lappend otherCons $con
      }
    }
    return $ret
  }

  # Check if a connector is in plane.
  # Goes through each point in the connector and evaluates
  # its distance to the plane.  If this distance is greater
  # than some tolerance, the connector is NOT in the plane.
  proc conIsInPlane { con pln } {
    variable tol_
    set ret 1
    for {set ii 1} {$ii <= [$con getDimension] } {incr ii} {
      set xyz [$con getXYZ $ii]
      if { [pwu::Plane distance $pln $xyz] > $tol_ } {
        set ret 0
        break
      }
    }
    return $ret
  }

  proc isZero { val {tol -1} } {
    if { -1 == $tol } {
      variable tol_
      set tol $tol_
    }
    return [expr { [::tcl::mathfunc::abs $val] < $tol}]
  }

  proc areEqual { val1 val2 {tol -1} } {
    return [isZero [expr {$val1 - $val2}] $tol]
  }

  proc ptsAreEqual { pt0 pt1 {tol -1} } {
    if { -1 == $tol } {
      variable tol_
      set tol $tol_
    }
    return [pwu::Vector3 equal -tolerance $tol $pt0 $pt1]
  }

  ## Uses 8 points forming the inner and outer domains to create ground plane
  ## Uses the in-plane connectors to cut holes inside the inner domain
  #proc createGrndPlnDoms {} {
  #  set innerCons {}
  #  lappend innerCons [setCon CM [createCon [getPt 9] [getPt 8] ]]
  #  lappend innerCons [setCon CP [createCon [getPt 8] [getPt 11] ]]
  #  lappend innerCons [setCon CO [createCon [getPt 11] [getPt 10] ]]
  #  lappend innerCons [setCon CN [createCon [getPt 10] [getPt 9] ]]
  #  # puts "##################### innerCons: $innerCons"
  #  set innerDom [setDom DF [pw::DomainUnstructured createFromConnectors $innerCons]]
  #  #insertLoopEdges $innerDom [getGridVal InPlnCons]
  #
  #  set outerCons {}
  #  lappend outerCons [setCon CA [createCon [getPt 0] [getPt 1] ]]
  #  lappend outerCons [setCon CB [createCon [getPt 1] [getPt 2] ]]
  #  lappend outerCons [setCon CC [createCon [getPt 2] [getPt 3] ]]
  #  lappend outerCons [setCon CD [createCon [getPt 3] [getPt 0] ]]
  #  set outerDom [setDom DG [pw::DomainUnstructured createFromConnectors $outerCons]]
  #  addEdgeToDom $outerDom $innerCons
  #}

  #proc addEdgeToDom {dom cons} {
  #  set edge [pw::Edge create]
  #  foreach con $cons {
  #    $edge addConnector $con
  #  }
  #  $dom addEdge $edge
  #}

  ## Given the domain and the path "rail" connector, extrude a path block
  #proc extrudePath {doms rail {type Structured}} {
  #  pw::Application setGridPreference $type
  #  set ret {}
  #  foreach dom $doms {
  #    set mode [pw::Application begin Create]
  #    set face [pw::FaceStructured createFromDomains [list $dom]]
  #    set face [lindex $face 0]
  #    set extBlk [pw::BlockStructured create]
  #    $extBlk addFace $face
  #    $mode end
  #    set mode [pw::Application begin ExtrusionSolver [list $extBlk]]
  #    $mode setKeepFailingStep true
  #    $extBlk setExtrusionSolverAttribute Mode Path
  #    $extBlk setExtrusionSolverAttribute PathConnectors [list $rail]
  #    $extBlk setExtrusionSolverAttribute PathUseTangent 1
  #    set numPoints [$rail getDimension]
  #    $mode run [incr numPoints -1]
  #    $mode end
  #    lappend ret $extBlk
  #  }
  #  unset mode
  #  unset face
  #  if { 1 == [llength $ret] } {
  #    set ret [lindex $ret 0]
  #  }
  #  return $ret
  #}

  ## Set layer and name for an entity
  #proc setAttributes {ents baseName layer} {
  #  if { 1 < [llength ents] } {
  #    set baseName "${baseName}-1"
  #  }
  #  foreach ent $ents {
  #    $ent setName $baseName
  #    $ent setLayer -parents $layer
  #    pw::Layer setDescription $layer "[$ent getType] [$ent getName]"
  #  }
  #}

  ## Grab x, y, or z farfield margin
  #proc ffMargin {bcId} {
  #  variable ffMargins_
  #  return [getMargin $ffMargins_ $bcId]
  #}

  ## Gets a specified margin
  #proc getMargin {margins bcId} {
  #  assertIsBcId $bcId
  #  switch $bcId {
  #  x- {
  #    return [lindex $margins 0] }
  #  x+ {
  #    return [lindex $margins 1] }
  #  y- {
  #    return [lindex $margins 2] }
  #  y+ {
  #    return [lindex $margins 3] }
  #  z- {
  #    return [lindex $margins 4] }
  #  z+ {
  #    return [lindex $margins 5] }
  #  }
  #}

  ## Block Extrusions
  #proc extrudeWakeBlock {} {
  #  variable wakeBlkDist_
  #  variable wakeBlkGrowthRate_
  #  variable wakeBlkSpacing_
  #  variable nfSpacing_
  #  set dom [getDom DD]
  #  set pt0 [getPt 0]
  #  set pt1 [pwu::Vector3 subtract $pt0 [list $wakeBlkDist_ 0 0]]
  #  set con [setCon WakeRail [createCon $pt0 $pt1]]
  #  # $con setRenderAttribute PointMode All
  #  setConSpacing $con $wakeBlkGrowthRate_ $wakeBlkSpacing_ [expr {$nfSpacing_ / 2.0}]
  #  set blk [setBlk WakeBlk [extrudePath $dom $con]]
  #  setAttributes $blk "Wake" 10
  #}

  #proc extrudePostWakeBlock {} {
  #  variable wakeBlkSpacing_
  #  variable ffGrowthRate_
  #  variable ffSpacing_
  #  set dom [[[getBlk WakeBlk] getFace KMaximum] getDomain 1]
  #  set wakeRail [getEdgeCons WakeRail]
  #  set pt0 [$wakeRail getPoint [$wakeRail getDimension]]
  #  set pt1 [pwu::Vector3 subtract $pt0 [list [ffMargin x-] 0 0]]
  #  set con [setCon PostWakeRail [createCon $pt0 $pt1]]
  #  # $con setRenderAttribute PointMode All
  #  setConSpacing $con $ffGrowthRate_ $ffSpacing_ $wakeBlkSpacing_
  #  set blk [setBlk PostWakeBlk [extrudePath $dom $con]]
  #  setAttributes $blk "Post Wake" 11
  #  [getBlk WakeBlk] alignOrientation $blk
  #}

  #proc extrudeUpStreamBlock {} {
  #  variable wakeBlkDist_
  #  variable wakeBlkGrowthRate_
  #  variable wakeBlkSpacing_
  #  variable nfSpacing_
  #  variable ffGrowthRate_
  #  variable ffSpacing_
  #
  #  set dom [getDom DB]
  #  set pt0 [getPt 1]
  #  set pt1 [pwu::Vector3 add $pt0 [list [ffMargin x+] 0 0]]
  #  set con [setCon UpStreamRail [createCon $pt0 $pt1]]
  #  # $con setRenderAttribute PointMode All
  #  setConSpacing $con $ffGrowthRate_ $ffSpacing_ [expr {$nfSpacing_ / 2.0}]
  #  set blk [setBlk UpStreamBlk [extrudePath $dom $con]]
  #  setAttributes $blk "Up Stream" 12
  #  [getBlk WakeBlk] alignOrientation $blk
  #}

  #proc extrudeRightSide {} {
  #  variable ffGrowthRate_
  #  variable ffSpacing_
  #  variable nfSpacing_
  #
  #  variable rightSideGrowthRate_
  #  variable rightSideSpacing_
  #
  #
  #  set doms [getDom DA]
  #  lappend doms [[[getBlk UpStreamBlk] getFace IMinimum] getDomain 1]
  #  lappend doms [[[getBlk WakeBlk] getFace IMaximum] getDomain 1]
  #  lappend doms [[[getBlk PostWakeBlk] getFace IMaximum] getDomain 1]
  #  set pt0 [getPt 1]
  #  set pt1 [pwu::Vector3 subtract $pt0 [list 0 [ffMargin y-] 0]]
  #  set con [setCon SideNegRail [createCon $pt0 $pt1]]
  #  # $con setRenderAttribute PointMode All
  #  setConSpacing $con $ffGrowthRate_ $ffSpacing_ [expr {$nfSpacing_ / 2.0}]
  #  set blks [setBlk RightSideBlks [extrudePath $doms $con]]
  #  setAttributes $blks "Right Side" 13
  #
  #  # Realign orientation of blocks to match Wake Block
  #  [lindex $blks 1] setOrientation  KMinimum  IMaximum  JMaximum
  #  [getBlk WakeBlk] alignOrientation [lindex $blks 2]
  #  [lindex $blks 3] setOrientation  KMinimum  IMinimum  JMinimum
  #}

  #proc extrudeLeftSide {} {
  #  variable ffGrowthRate_
  #  variable ffSpacing_
  #  variable nfSpacing_
  #
  #  set doms [getDom DC]
  #  lappend doms [[[getBlk UpStreamBlk] getFace IMaximum] getDomain 1]
  #  lappend doms [[[getBlk WakeBlk] getFace IMinimum] getDomain 1]
  #  lappend doms [[[getBlk PostWakeBlk] getFace IMinimum] getDomain 1]
  #  set pt0 [getPt 2]
  #  set pt1 [pwu::Vector3 add $pt0 [list 0 [ffMargin y+] 0]]
  #  set con [setCon SidePosRail [createCon $pt0 $pt1]]
  #  # $con setRenderAttribute PointMode All
  #  setConSpacing $con $ffGrowthRate_ $ffSpacing_ [expr {$nfSpacing_ / 2.0}]
  #  set blks [setBlk LeftSideBlks [extrudePath $doms $con]]
  #  setAttributes $blks "Left Side" 14
  #
  #  # Realign orientation of blocks to match Wake Block
  #  [lindex $blks 1] setOrientation  KMaximum  IMinimum  JMinimum
  #  [getBlk WakeBlk] alignOrientation [lindex $blks 2]
  #  [lindex $blks 3] setOrientation  KMaximum  IMaximum  JMinimum
  #}

  #proc extrudeUp {} {
  #  variable ffGrowthRate_
  #  variable ffSpacing_
  #  variable nfSpacing_
  #
  #  set doms [getDom DE]
  #  lappend doms [[[getBlk UpStreamBlk] getFace JMaximum] getDomain 1]
  #  lappend doms [[[getBlk WakeBlk] getFace JMaximum] getDomain 1]
  #  lappend doms [[[getBlk PostWakeBlk] getFace JMaximum] getDomain 1]
  #
  #  foreach blk [getBlk RightSideBlks] {
  #    lappend doms [[$blk getFace JMaximum] getDomain 1]
  #  }
  #
  #  foreach blk [getBlk LeftSideBlks] {
  #    lappend doms [[$blk getFace JMaximum] getDomain 1]
  #  }
  #
  #  set pt0 [getPt 5]
  #  set pt1 [pwu::Vector3 add $pt0 [list 0 0 [ffMargin z+]]]
  #  set con [setCon UpRail [createCon $pt0 $pt1]]
  #  # $con setRenderAttribute PointMode All
  #  setConSpacing $con $ffGrowthRate_ $ffSpacing_ [expr {$nfSpacing_ / 2.0}]
  #  set blks [setBlk UpBlks [extrudePath $doms $con]]
  #  setAttributes $blks "Up" 15
  #
  #  # Realign orientation to match wake block.
  #  foreach blk $blks {
  #    [getBlk WakeBlk] alignOrientation $blk
  #  }
  #}

  #proc setConSpacing {con growthRate midSpacing beginSpacing {endSpacing 0}} {
  #  # puts "setConSpacing {$con GR=$growthRate Mid=$midSpacing Beg=$beginSpacing End=$endSpacing}"
  #  proc ComputeLayers {growthRate midSpacing initSpacing} {
  #    # puts "ComputeLayers $growthRate $midSpacing $initSpacing"
  #    # puts "  Numerator: [expr {log(($growthRate*$midSpacing)/$initSpacing)}]"
  #    # puts "  Denomenator: [expr {log($growthRate)}]"
  #    set numLayers [expr {int(log(($growthRate*$midSpacing)/$initSpacing)/log($growthRate))}]
  #    if { $numLayers > 5 } {
  #        incr numLayers -1
  #    } elseif { $numLayers < 0 } {
  #        set numLayers 0
  #    }
  #    #puts "  NumLayers: $numLayers"
  #    return $numLayers
  #  }
  #
  #  # set conMode [pw::Application begin Modify [list $con]]
  #  $con replaceDistribution 1 [pw::DistributionGrowth create]
  #  if { 0 == $endSpacing } {
  #    set endSpacing $midSpacing
  #  }
  #  set dist     [$con getDistribution 1]
  #  set beginObj [$dist getBeginSpacing]
  #  set endObj   [$dist getEndSpacing]
  #  $beginObj setValue $beginSpacing
  #  $endObj   setValue $endSpacing
  #  #puts "##### Begin Spacing: $beginSpacing [$beginObj getValue] End Spacing: $endSpacing [$endObj getValue]"
  #  set beginLayers [ComputeLayers $growthRate $midSpacing $beginSpacing]
  #  set endLayers   [ComputeLayers $growthRate $midSpacing $endSpacing]
  #  # puts "Begin Spacing: $beginSpacing End Spacing: $endSpacing Begin Layers: $beginLayers End Layers: $endLayers"
  #  $dist setBeginLayers $beginLayers
  #  $dist setEndLayers   $endLayers
  #  $dist setBeginRate   $growthRate
  #  $dist setEndRate     $growthRate
  #  $con setDimensionFromDistribution
  #}


  #========================================================================
  # DEBUG PROCS
  #========================================================================

  proc vputs {msg} {
    variable verbose_
    if { $verbose_ } {
      puts $msg
    }
  }

  proc dump {} {
    dump.BCs
    dump.Grid
    #variable groundPlane_
    #variable flowDirection_
    #variable nfSpacing_
    #variable blInitialDs_
    #variable blGrowthRate_
    #variable domExtents_
    #variable tol_
    #vputs "Ground plane: $groundPlane_"
    #vputs "Flow direction: $flowDirection_"
    #vputs "NearField Edge Length: $nfSpacing_"
    #vputs "Boundary Layer intial delta s: $blInitialDs_"
    #vputs "Boundary Layer growth rate: $blGrowthRate_"
    #vputs "Min Extents: [lindex $domExtents_ 0]"
    #vputs "Max Extents: [lindex $domExtents_ 1]"
    #vputs "Surface Domains: [getGridVal SurfDoms]"
    #vputs "Tolerance: $tol_"
  }

  proc dump.BCs {} {
    foreachBC {
      set wd 0
      foreach key $_BCPARAMS {
        if { [string length $key] > $wd } {
          set wd [string length $key]
        }
      }
      set fmt "%-${wd}.${wd}s = %s"
      foreach key $_BCPARAMS {
        puts [format $fmt "$key" [list [prettyVal [set $key]]]]
      }
      puts ""
    }
  }

  proc dump.Grid {} {
    variable db_
    dict for {key val} [dict get $db_ Grid] {
      switch $key {
      SurfDoms -
      SurfDomExts -
      NearFieldExts -
      LaminaCons -
      InPlnCons -
      UpBlks -
      RightSideBlks -
      LeftSideBlks -
      UnusedLaminaCons {
        if { 0 == [llength $val] } {
          continue
        }
        puts "## $key"
        foreach v $val {
          puts [format "  %s" [list [prettyVal $v]]]
        }
      }
      NearFieldEdgeDb {
        # $val edgeNdx Pts {pt-list}
        #              Srcs {src-list}
        puts "## $key"
        dict for {ndx ptsSrcs} $val {
          set pts [dict get $ptsSrcs Pts]
          set srcs [dict get $ptsSrcs Srcs]
          set pts [lassign $pts pt]
          set srcs [lassign $srcs src]
          puts [format "  Edge %2.2s Pts: %s (%s)" "$ndx" [list $pt] $src]
          foreach pt $pts src $srcs {
            puts [format "               %s (%s)" [list $pt] $src]
          }
        }
      }
      default {
        puts "##>> $key"
        dict for {key2 val2} $val {
          puts [format "  %5.5s: %s" "$key2" [list [prettyVal $val2]]]
        }
      }}
      puts ""
    }
  }

  proc prettyVal { v } {
    switch -glob -- $v {
    ::pw::Edge* {
      # NOP
    }
    "\{::pw::*" {
      # list of ent-lists: "{::pw::ent1 ::pw::ent2} {::pw::ent3 ::pw::ent4}"
      set tmp {}
      foreach pwEnts $v {
        lappend tmp [prettyVal $pwEnts]
      }
      set v $tmp
    }
    ::pw::* {
      if { 1 == [llength $v] } {
        set v [$v getName]
      } else {
        set tmp {}
        foreach pw $v {
          lappend tmp [prettyVal $pw]
        }
        set v $tmp
      }
    }
    default {
    }}
    return $v
  }

  namespace ensemble create
}
