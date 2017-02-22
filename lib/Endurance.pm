# StorScore
#
# Copyright (c) Microsoft Corporation
#
# All rights reserved. 
#
# MIT License
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

package Endurance;

use strict;
use warnings;
use Moose;
use Util;
use DeviceDB;

use Exporter;
use vars qw(@ISA @EXPORT);

@ISA = qw(Exporter);
@EXPORT = 'compute_endurance';

sub compute_endurance($)
{
    my $stats_ref = shift;
    my $smart_tool = shift;
    
    my $model_name = $stats_ref->{'Device Model'};
    my $ddb_ref = $device_db{ $model_name };

    unless( defined $ddb_ref )
    {
        warn "\tNo entry in DeviceDB for $model_name. Cannot compute WAF.\n";
        return;
    }
    
    $stats_ref->{'Rated PE Cycles'} = $ddb_ref->{'Rated PE Cycles'};

    return unless test_contains_writes( $stats_ref );

    compute_host_writes( $stats_ref, $ddb_ref );
    compute_controller_writes( $stats_ref, $ddb_ref );

    compute_file_system_waf( $stats_ref, $ddb_ref );
    compute_drive_waf( $stats_ref, $ddb_ref );
    compute_total_waf( $stats_ref, $ddb_ref );

    compute_nand_metrics( $stats_ref, $ddb_ref );
    compute_dwpd( $stats_ref, $ddb_ref );
}

sub compute_host_writes($$)
{
    my $stats_ref = shift;
    my $ddb_ref = shift;

    return unless exists $stats_ref->{'Measurements'}{'Total'}{'Host Writes Before'};  

    my $before = $stats_ref->{'Measurements'}{'Total'}{'Host Writes Before'};
    my $after = $stats_ref->{'Measurements'}{'Total'}{'Host Writes After'};
    my $diff = $after - $before;

    # if the device db doesn't define a unit, assume it's an NVMe drive with the default units
    my $units = $ddb_ref->{'Host Writes'}{'Unit'} // BYTES_PER_MB_BASE2;

    warn "\tPossible overflow in host writes SMART counter. WAF is wrong.\n"
        if $after < $before;

    $stats_ref->{'Notes'} .= "Host writes too small ($diff). WAF is wrong; "
        if $diff < 5;

    $stats_ref->{'Measurements'}{'Total'}{'Host Writes'} =
        ( $after - $before ) * $units;
}

sub compute_controller_writes($$)
{
    my $stats_ref = shift;
    my $ddb_ref = shift;

    return unless exists $stats_ref->{'Measurements'}{'Total'}{'Controller Writes Before'};  

    my $before = $stats_ref->{'Measurements'}{'Total'}{'Controller Writes Before'};
    my $after = $stats_ref->{'Measurements'}{'Total'}{'Controller Writes After'};
    my $diff = $after - $before;

    my $units = $ddb_ref->{'Controller Writes'}{'Unit'} // BYTES_PER_MB_BASE2;

    warn "\tPossible overflow in ctlr writes SMART counter. WAF is wrong.\n"
	    if $after < $before;

    $stats_ref->{'Notes'} .= "Ctlr writes too small ($diff).  WAF is wrong; "
        if $diff < 5;

    $stats_ref->{'Measurements'}{'Total'}{'Controller Writes'} =
        ( $after - $before ) * $units;

    $stats_ref->{'Measurements'}{'Total'}{'Controller Writes'} +=
        $stats_ref->{'Measurements'}{'Total'}{'Host Writes'} 
        if exists $ddb_ref->{'Controller Writes'}{'Additive'};
}

sub compute_file_system_waf($$)
{
    my $stats_ref = shift;
    my $ddb_ref = shift;

    return unless exists $stats_ref->{'Measurements'}{'Total'}{'Host Writes'};

    my $host_writes_in_GB =
        $stats_ref->{'Measurements'}{'Total'}{'Host Writes'} /
        BYTES_PER_GB_BASE2;

    $stats_ref->{'Measurements'}{'Total'}{'Filesystem Write Amplification'} = 
        $host_writes_in_GB / $stats_ref->{'Measurements'}{'Total'}{'GB Write'};
}
                 
sub compute_drive_waf($$)
{
    my $stats_ref = shift;
    my $ddb_ref = shift;

    return unless 
        exists $stats_ref->{'Measurements'}{'Total'}{'Host Writes'} and
        exists $stats_ref->{'Measurements'}{'Total'}{'Controller Writes'};
    
    my $ctrl_writes = $stats_ref->{'Measurements'}{'Total'}{'Controller Writes'};
    my $host_writes = $stats_ref->{'Measurements'}{'Total'}{'Host Writes'};

    $stats_ref->{'Measurements'}{'Total'}{'Drive Write Amplification'} =
        $ctrl_writes / $host_writes
        unless $host_writes == 0;
}

sub compute_total_waf($$)
{
    my $stats_ref = shift;
    my $ddb_ref = shift;

    return
        unless exists $stats_ref->{'Measurements'}{'Total'}{'Controller Writes'};

    my $ctrl_writes_in_GB =
        $stats_ref->{'Measurements'}{'Total'}{'Controller Writes'} /
        BYTES_PER_GB_BASE2;

    $stats_ref->{'Measurements'}{'Total'}{'Total Write Amplification'} = 
        $ctrl_writes_in_GB / $stats_ref->{'Measurements'}{'Total'}{'GB Write'};
}

sub compute_nand_metrics($$)
{
    my $stats_ref = shift;
    my $ddb_ref = shift;

    return unless exists
        $stats_ref->{'Measurements'}{'Total'}{'Drive Write Amplification'};

    my $drive_waf =
        $stats_ref->{'Measurements'}{'Total'}{'Drive Write Amplification'};
    my $app_write_bw =
        $stats_ref->{'Measurements'}{'Total'}{'MB/sec Write'};
    my $app_gb_written =
        $stats_ref->{'Measurements'}{'Total'}{'GB Write'};

    $stats_ref->{'Measurements'}{'Total'}{'NAND Writes (GB)'} =
        $app_gb_written * $drive_waf;

    $stats_ref->{'Measurements'}{'Total'}{'NAND Write BW (MB/sec)'} =
        $app_write_bw * $drive_waf
        if exists $stats_ref->{'Measurements'}{'Total'}{'MB/sec Write'};
}

sub compute_dwpd($$)
{
    my $stats_ref = shift;
    my $ddb_ref = shift;

    return unless 
        exists $ddb_ref->{'Rated PE Cycles'} and
        exists $stats_ref->{'Measurements'}{'Total'}{'Drive Write Amplification'};
   
    my $rated_cycles = $ddb_ref->{'Rated PE Cycles'};
    my $waf = $stats_ref->{'Measurements'}{'Total'}{'Drive Write Amplification'};

    return unless $waf > 0;
 
    my $internal_capacity = $ddb_ref->{'Internal Capacity'};
   
    my $total_nand_bytes;

    # If DeviceDB contains the actual internal capacity, use that.
    # Otherwise make a resonable assumption.
    if( defined $internal_capacity )
    {
        $total_nand_bytes = human_to_bytes( $internal_capacity );
    }
    else
    {
        $total_nand_bytes =
            round_up_power2( $stats_ref->{'User Capacity (B)'} );
    }
   
    # Give the drive credit for OP and TRIM'd space
    my $mapped_bytes = $stats_ref->{'Partition Size (B)'};

    # Compute cycles per user-visible byte
    my $adjusted_cycles = $rated_cycles *
        ( $total_nand_bytes / $mapped_bytes );
    
    $stats_ref->{'Measurements'}{'Total'}{'DWPD 3yr'} =
        $adjusted_cycles / ( $waf * 3 * 365 );
    $stats_ref->{'Measurements'}{'Total'}{'DWPD 5yr'} =
        $adjusted_cycles / ( $waf * 5 * 365 );
}

sub test_contains_writes($)
{
     my $stats_ref = shift;

     die "Writes Mix is not defined\n"
        unless exists $stats_ref->{'Workloads'}{'Total'}{'W Mix'};

     return $stats_ref->{'Workloads'}{'Total'}{'W Mix'} > 0;
}

1;
