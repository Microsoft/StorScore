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

package DiskSpdRunner;

use strict;
use warnings;
use Moose;
use Util;
use Compressibility;

with 'IOGenerator';

has 'output_dir' => (
    is => 'ro',
    isa => 'Str',
    required => 1
);

has 'target' => (
    is => 'ro',
    isa => 'Target',
    required => 1
);

has 'cmd_line' => (
    is      => 'ro',
    isa     => 'CommandLine',
    required => 1
);

my $affinity_string;

if( hyperthreading_enabled() )
{
    my @all_cores = ( 0 .. num_physical_cores() - 1 );

    # Prefer even-numbered (physical) cores...
    my @physical_cores = grep { $_ % 2 == 0 } @all_cores;

    # ...but use odd-numbered (logical) if we must
    my @logical_cores = grep { $_ % 2 } @all_cores;

    $affinity_string = join ',', ( @physical_cores, @logical_cores ); 
}
# Else do nothing, DiskSpd uses simple round-robin affinity by default

sub run($$)
{
    my $self = shift;

    my $test_ref = shift;
    my $run_type = shift;

    my $run_time = $test_ref->{'run_time'};

    if( $run_type eq 'warmup' )
    {
        $run_time = $test_ref->{'warmup_time'};
    }
    elsif( $run_type eq 'precondition' )
    {
        $run_time = '3600' 
            unless ( $pretend or $self->cmd_line->demo_mode );
    }
   
    my $cmd;

    if( $test_ref->{'target_count'} > 1 )
    {
        $cmd = $self->get_xml_cmdline($test_ref, $run_time);
    }
    else
    {
        $cmd = $self->get_cmdline($test_ref, $run_time);
    }

    my $out_file = $self->output_dir .
        "\\$run_type-$test_ref->{'description'}.txt";
    
    open( my $OUT, ">$out_file" )
        or die "could not open $out_file: $!";
   
    # Save the command line as line 1 of the file
    print $OUT "$cmd\n";

    my ( $errorlevel, $stdout, $stderr ) = execute_task( $cmd );
   
    print $OUT "$stdout\n";
    print $OUT "$stderr\n";

    close( $OUT );

    print STDERR "\n\tDiskSpd returned non-zero errorlevel" if $errorlevel;

}

sub get_xml_cmdline($$$)
{
    my $self = shift;
    my $test_ref = shift;
    my $run_time = shift;

    my $compressibility  = $test_ref->{'compressibility'};
    my $profile_template = $recipes_dir .
        "\\xmlProfiles\\$test_ref->{'xml_profile'}";

    my $parser = XML::LibXML->new();
    my $doc = $parser->parse_file( $profile_template );

    for my $timespan ( $doc->findnodes( '//TimeSpan' ) )
    {
        my $duration_node = XML::LibXML::Element->new( 'Duration' );
        $duration_node->appendTextNode( "$run_time" );
        $timespan->addChild( $duration_node );
    }

    # Use default unless compressibility is specified by the test
    my $entropy_file = 
        Compressibility::get_filename( 
            $compressibility // $self->cmd_line->compressibility
        );

    my $entropy_file_size = int Compressibility::FILE_SIZE;

    for my $data_source ( $doc->findnodes( '//RandomDataSource' ) )
    {
        my $file_node = XML::LibXML::Element->new('FilePath');
        $file_node->appendTextNode( "$entropy_file" );
        $data_source->addChild( $file_node );

        my $file_size_node = XML::LibXML::Element->new( 'SizeInBytes' );
        $file_size_node->appendTextNode( "$entropy_file_size" );
        $data_source->addChild( $file_size_node );
    }

    my $profile_target_nodes = $doc->findnodes( '//Target' );
    my $profile_target_count = $profile_target_nodes->size();
    my $recipe_target_count  = $test_ref->{'target_count'};

    my $msg = "Number of targets in recipe ($recipe_target_count)" .
            "does not match profile ($profile_target_count)\n";
    die $msg unless( $profile_target_count == $recipe_target_count );

    my $file_num = 0;
    for my $target ( $profile_target_nodes->get_nodelist )
    {
        $file_num++;
        
        my $path = $self->target->volume . "\\$TEST_FILE_STUB$file_num.dat";

        my $path_node = XML::LibXML::Element->new( 'Path' );
        $path_node->appendTextNode( $path );
        $target->addChild( $path_node );
    }

    my $profile_file = $self->output_dir .
        "\\profile-$test_ref->{'description'}.xml";
    
    $doc->toFile($profile_file);

    my $cmd = "DiskSpd.exe -X$profile_file";

    return $cmd;
}

sub get_cmdline($$$)
{
    my $self = shift;
    my $test_ref = shift;
    my $run_time = shift;

    my $write_percentage = $test_ref->{'write_percentage'};
    my $access_pattern   = $test_ref->{'access_pattern'};
    my $block_size       = $test_ref->{'block_size'};
    my $queue_depth      = $test_ref->{'queue_depth'};
    my $compressibility  = $test_ref->{'compressibility'};
  
    # Gradually increase the number of threads as queue_depth
    # increases in order to prevent CPU limitation.
    my $num_threads = 1;

    if( $queue_depth >= 16 )
    {
        $num_threads = 4;
    }
    elsif( $queue_depth >= 4 )
    {
        $num_threads = 2;
    }
   
    my $ios_per_thread = $queue_depth / $num_threads; 

    my $cmd = "DiskSpd.exe ";

    $cmd .= "-w$write_percentage " if $write_percentage != 0;

    if( $access_pattern eq 'random' )
    {
        $cmd .= "-r ";
    }
    else
    {
        # interlocked mode so we are truly sequential with multi-threads
        $cmd .= "-si ";
    }

    $cmd .= "-b$block_size ";
    $cmd .= "-t$num_threads ";  
    $cmd .= "-o$ios_per_thread ";
    $cmd .= "-a$affinity_string " if defined $affinity_string;
    $cmd .= "-L ";
    $cmd .= "-h "; # match SQLIO2 default: no buffering, write-through
    $cmd .= "-d$run_time ";
   
    # Use default unless compressibility is specified by the test
    my $entropy_file = 
        Compressibility::get_filename( 
            $compressibility // $self->cmd_line->compressibility
        );
    
    my $entropy_file_size_MB = 
        int Compressibility::FILE_SIZE / 1024 / 1024;

    $cmd .= "-Z$entropy_file_size_MB" . qq(M,"$entropy_file" );
    
    # All-purpose escape hatch.  Support arbitrary args.
    $cmd .= " " . $self->cmd_line->io_generator_args . " "
        if defined $self->cmd_line->io_generator_args;

    if( $self->cmd_line->raw_disk )
    {
        $cmd .= "#" . $self->target->physical_drive;
    }
    else
    {
        $cmd .= $self->target->file_name;
    }
    
    return $cmd;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
