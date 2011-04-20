#!/usr/bin/perl

# Version 0.1

use strict;
use warnings;
use Digest::MD5("md5_hex");
use Fcntl;
use File::Find;
use IO::Socket;
use LWP::Simple;
use threads;
use threads::shared;
use Thread::Queue;
use Thread::Semaphore;
use Config;
$Config{useithreads} or die( "Recompile Perl with threads to run this program!" );

### vars

my $source = $ARGV[0] || die &print_usage();
my $TARGET_DIR = $ARGV[1] || "./.";
my $ZONE;
my $RS_USERNAME;
my $RS_PASSWORD;
my $RAR_APPENDIX = "test";
my $RAR_SIZE = 102400;
my $uploadserver;
my $path;
my $name = "";
my $compression_queue = Thread::Queue->new();
my $upload_queue = Thread::Queue->new();
my $semaphore = new Thread::Semaphore;
my $t_id = 0;
my $target_done = $TARGET_DIR."/done";


### start Threads!
if( !-d$target_done ){
			DEBUG( "$target_done is not existing! Creating..." );
			system( "mkdir $TARGET_DIR"."done" );
}
my $rar_thread = threads->create( \&rar );
DEBUG( "Compression thread created!" );
my @upload_threads;
for( my $i=0; $i<10; $i++ ) {
    my $upload_thread = threads->create( \&upload );
    push( @upload_threads, $upload_thread );
}
DEBUG( "Upload threads created!" );
if( !-e $source ){ die ERROR( "$source is not a directory or file!" ); }
if( -d $source ){
	DEBUG( "Source is Directory! Searching for sample..." );
	INFO( "Searching for a sample..." );
	my $sample_dir;
	my $sample_file;
	my @content;
	my @find_sample;
	# search for a sample
	opendir( DIR, "$source");
	@content = readdir( DIR );
	closedir(DIR);
	
	foreach( @content ){
		if( $_ =~ m/^sample$/i ){
			$sample_dir = $source.$_;
			DEBUG( "Sample found in: $sample_dir" );
			last;
		} 
	}	

	if( $sample_dir ){
		opendir(DIR, "$sample_dir");
		@find_sample = grep( /.*sample.*$/i,readdir(DIR) );
		closedir(DIR);
		
		$sample_file = $find_sample[0];
		DEBUG( "Found Sample! [$sample_file]" );
		INFO( "[$sample_file] found sample!" );
		INFO( "[$sample_file] uploading sample..." );
		$upload_queue->enqueue( $sample_file );
		DEBUG( "Sample Upload Thread created!" );
	} else {
			DEBUG( "No sample found!" );
			INFO( "No sample found!" );
	}
}
$compression_queue->enqueue($source); #vllt ne referenz, statt eines objectes?!
$compression_queue->enqueue(undef);

foreach my $thr ( threads->list() ) {
    DEBUG( "Waiting for all threads to finish..." );
    DEBUG( "Still running: ".threads->list() );
    $thr->join(); # end of program
}

sub rar {
    my $element;
    my @find_files;
    while( $element = $compression_queue->dequeue() ) {
		if( !-d $element ){
			($path, $name) = $element =~ m/(.*\/)(.*)$/;
		} else {
			($path, $name) = $element =~ m/(.*\/)(.*\/)$/;
			$name =~ s/\/$//;
		}
		
		### RAR!
		INFO( "[$name] Compressing..." );
		my $find_files_thread = threads->create( \&find_files );
		DEBUG( "Finding_Files thread initiated..." );
		
		system( "cd $TARGET_DIR && rar a -ep1 -m0 -r -v$RAR_SIZE ".$name.".".$RAR_APPENDIX.".rar ".$element." > rar.log" ); # -v1024000 !!!

		DEBUG( "Compression done! ($element)" );
		INFO( "[$name] Compression finished!" );
    }
    $upload_queue->enqueue(undef);
}

sub upload {
    my $file;
    my $tid = threads->tid();
    while( $file = $upload_queue->dequeue() ) {
       	DEBUG( "Uploading ($file)..." );
		# split file into chunks and upload them via &uploadchunk
		if( !-e $TARGET_DIR.$file ){
			ERROR( "{$tid} $file disappeared before uploading! Skipping..." );
			DEBUG( "{$tid} $file disappeared before uploading! Skipping..." );
			next;
		}
		system( "mv $TARGET_DIR/$file $target_done" );
		DEBUG( "($file) Upload successfull!" );
		INFO( "{$tid}[$file] Upload complete!" );
    }
    if( threads->list() > 1 ){
	$upload_queue->enqueue(undef);
    }
    INFO( "{$tid} No files left... exiting." );
}

sub uploadchunk {
    DEBUG( "Entered 'uploadchunk'" );

}

sub find_files{
	my @input;
	my @find_files;
	my $done = 0;
	my $compression_started;
	my $compression_ended;
	my $part_counter = 1;
	while( !-e "$TARGET_DIR/rar.log"){
		next;
	}
	open( RAR, "< $TARGET_DIR/rar.log" );
	DEBUG( "Waiting 10s for rar to start and change first file..." );	
	INFO( "Waiting 10s for rar to start and change first file..." );	
	sleep( 10 );
	while( !$done ){
		@input = <RAR>;
		foreach( @input ){		
			if( $_ =~ m/^Creating archive $name.*$/i  ){
				# DEBUG( "[$name] RAR found! --> $_" );
				$compression_started = $name
				# vllt $_ uebergeben und  bei Calculating control sum einfach anhaengen?!
			}
			if( $_ =~ m/^Calculating the control sum.*$/ ){
				$compression_ended = $name;
				#sleep(5); #waiting for rar to change the filename
				DEBUG( "searching for Part$part_counter" );
				opendir(DIR, "$TARGET_DIR");
				@find_files = grep( /$name\.$RAR_APPENDIX\.part[0]{0,}$part_counter\.rar.*$/,readdir(DIR) );
				# DEBUG( "[$name\.$RAR_APPENDIX\.part$part_counter\.rar] new .rar found!" );
				closedir(DIR);
				foreach( @find_files ){
					# DEBUG( $_." <--- SHOULD UPLOAD? " );
					$upload_queue->enqueue( $_ );
					DEBUG( "Added $_ to upload_queue ..." );
				}
				$part_counter++;
			}
			if( $_ =~ m/^Done\s+$/ ){
				$done = 1;
			}	
			sleep(0.2);
		}
	}
	$upload_queue->enqueue(undef);
	close( RAR );
}

sub search {
	my $target = shift;
	my $search_name = shift;
	my $search_for = shift;
	my @result;
	DEBUG( "searching for $search_name\.$search_for..." );
	opendir(DIR, "$target");
	@result = grep( /$search_name\.{,1}$search_for.*$/,readdir(DIR) );
	closedir(DIR);
	return
}

sub change_md5 {
    DEBUG( "Entered 'change_md5'" );
	# necessary for mirrors
}

sub print_usage {
    print "Syntax: perl spru.pl <source> [<target>]\n[i]   conf is .spru!\n"
}

sub parse_conf {
    DEBUG( "Entered 'parse_conf'" );
	# read .spru and fill the vars
}

sub print_progress {
    DEBUG( "Entered 'print_progress'" );
    INFO( "Progress is not implemented yet!" );
 	# lock a shared var in which the threads write their progress and format and output the progress of each thread.
}

sub DEBUG {
	# if level = debug...
    my $message = shift;
    $semaphore->down();
    open( DEBUG, ">> debug.log" ) || die "[!]  $!\n";
    print DEBUG "$message\n";
    close( DEBUG );
    $semaphore->up();
}

sub INFO {
    my $message = shift;
    $semaphore->down();
    open( INFO, ">> info.log" ) || die "[!]  $!\n";
    print INFO "$message\n";
    print STDOUT "[i]   $message\n";
    close( INFO );
    $semaphore->up();
}

sub ERROR {
    my $message = shift;
    $semaphore->down();
    open( ERROR, ">> error.log" ) || die "[!]  $!\n";
    print ERROR "$message\n";
    print STDOUT "[!]   $message\n";
    close( ERROR );
    $semaphore->up();
}
