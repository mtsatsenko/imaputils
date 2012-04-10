#!/usr/bin/perl

# $Header: /mhub4/sources/imap-tools/imapsync.pl,v 1.27 2012/03/01 05:32:58 rick Exp $

#######################################################################
#   Program name    imapsync.pl                                       #
#   Written by      Rick Sanders                                      #
#                                                                     #
#   Description                                                       #
#                                                                     #
#   imapsync is a utility for synchronizing a user's account on two   #
#   IMAP servers.  When supplied with host/user/password information  #
#   for two IMAP hosts imapsync does the following:                   #
#	1.  Adds any messages on the 1st host which aren't on the 2nd #
#       2.  Deletes any messages from the 2nd which aren't on the 1st #
#       3.  Sets the message flags on the 2nd to match the 1st's flags#  
#                                                                     #
#   imapsync is called like this:                                     #
#      ./imapsync -S host1/user1/password1 -D host2/user2/password2   # 
#                                                                     #
#   Optional arguments:                                               #
#	-d debug                                                      #
#       -L logfile                                                    #
#       -m mailbox list (sync only certain mailboxes,see usage notes) #
#######################################################################

use Socket;
use IO::Socket;
use IO::Socket::INET;
use FileHandle;
use Fcntl;
use Getopt::Std;

#################################################################
#            Main program.                                      #
#################################################################

   init();

   #  Get list of all messages on the source host by Message-Id
   #
   connectToHost($sourceHost, \$src)    or exit;
   login($sourceUser,$sourcePwd, $sourceHost,$src)  or exit;
   namespace( $src, \$srcPrefix, \$srcDelim, $opt_x );

   connectToHost( $destHost, \$dst ) or exit;
   login( $destUser,$destPwd, $destHost, $dst ) or exit;
   namespace( $dst, \$dstPrefix, \$dstDelim, $opt_y );

   #  Create mailboxes on the dst if they don't already exist
   my @source_mbxs = getMailboxList( $src );

   #  Exclude certain ones if that's what the user wants
   exclude_mbxs( \@source_mbxs ) if $excludeMbxs;

   map_mbx_names( \%mbx_map, $srcDelim, $dstDelim );

   createDstMbxs( \@source_mbxs, $dst );

   #  Check for new messages and existing ones with new flags
   $adds=$updates=$deletes=0;
   ($added,$updated) = check_for_adds( \@source_mbxs, \%REVERSE, $src, $dst );

   #  Remove messages from the dst that no longer exist on the src
   $deleted = check_for_deletes( \%REVERSE, $dst, $src );

   logout( $src );
   logout( $dst );

   Log("\nSummary of results");
   Log("   Added   $added");
   Log("   Updated $updated");
   Log("   Deleted $deleted");

   exit;


sub init {

   $os = $ENV{'OS'};

   processArgs();

   $timeout = 60 unless $timeout;

   #  Open the logFile
   #
   if ( $logfile ) {
      if ( !open(LOG, ">> $logfile")) {
         print STDOUT "Can't open $logfile: $!\n";
      } 
      select(LOG); $| = 1;
   }
   Log("$0 starting\n");

   #  Determine whether we have SSL support via openSSL and IO::Socket::SSL
   $ssl_installed = 1;
   eval 'use IO::Socket::SSL';
   if ( $@ ) {
      $ssl_installed = 0;
   }

   $debug = 1;
}

#
#  sendCommand
#
#  This subroutine formats and sends an IMAP protocol command to an
#  IMAP server on a specified connection.
#

sub sendCommand
{
    local($fd) = shift @_;
    local($cmd) = shift @_;

    print $fd "$cmd\r\n";

    if ($showIMAP) { Log (">> $cmd",2); }
}

#
#  readResponse
#
#  This subroutine reads and formats an IMAP protocol response from an
#  IMAP server on a specified connection.
#

sub readResponse
{
    local($fd) = shift @_;

    $response = <$fd>;
    chop $response;
    $response =~ s/\r//g;
    push (@response,$response);
    if ($showIMAP) { Log ("<< $response",2); }
}

#
#  Log
#
#  This subroutine formats and writes a log message to STDERR.
#

sub Log {
 
my $str = shift;

   #  If a logfile has been specified then write the output to it
   #  Otherwise write it to STDOUT

   if ( $logfile ) {
      ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
      if ($year < 99) { $yr = 2000; }
      else { $yr = 1900; }
      $line = sprintf ("%.2d-%.2d-%d.%.2d:%.2d:%.2d %s %s\n",
		     $mon + 1, $mday, $year + $yr, $hour, $min, $sec,$$,$str);
      print LOG "$line";
   } else {
      print STDOUT "$str\n";
   }

   print STDOUT "$str\n" if $opt_Q;

}

#  insertMsg
#
#  This routine inserts an RFC822 messages into a user's folder
#

sub insertMsg {

local ($conn, $mbx, *message, $flags, $date, $msgid) = @_;
local ($lenx);

   Log("Inserting message $msgid") if $debug;
   $lenx = length($message);
   $totalBytes = $totalBytes + $lenx;
   $totalMsgs++;

   $flags = flags( $flags );
   fixup_date( \$date );

   sendCommand ($conn, "1 APPEND \"$mbx\" ($flags) \"$date\" \{$lenx\}");
   readResponse ($conn);
   if ( $response !~ /^\+/ ) {
       Log ("unexpected APPEND response: $response");
       # next;
       push(@errors,"Error appending message to $mbx for $user");
       return 0;
   }

   print $conn "$message\r\n";

   undef @response;
   while ( 1 ) {
       readResponse ($conn);
       if ( $response =~ /^1 OK/i ) {
	   last;
       }
       elsif ( $response !~ /^\*/ ) {
	   Log ("unexpected APPEND response: $response");
	   # next;
	   return 0;
       }
   }

   return 1;
}

#  Make a connection to an IMAP host

sub connectToHost {

my $host = shift;
my $conn = shift;

   Log("Connecting to $host") if $verbose;
   
   ($host,$port) = split(/:/, $host);
   $port = 143 unless $port;

   # We know whether to use SSL for ports 143 and 993.  For any
   # other ones we'll have to figure it out.
   $mode = sslmode( $host, $port );

   if ( $mode eq 'SSL' ) {
      unless( $ssl_installed == 1 ) {
         warn("You must have openSSL and IO::Socket::SSL installed to use an SSL connection");
         Log("You must have openSSL and IO::Socket::SSL installed to use an SSL connection");
         exit;
      }
      Log("Attempting an SSL connection") if $verbose;
      $$conn = IO::Socket::SSL->new(
         Proto           => "tcp",
         SSL_verify_mode => 0x00,
         PeerAddr        => $host,
         PeerPort        => $port,
      );

      unless ( $$conn ) {
        $error = IO::Socket::SSL::errstr();
        Log("Error connecting to $host: $error");
        warn("Error connecting to $host: $error");
        exit;
      }
   } else {
      #  Non-SSL connection
      Log("Attempting a non-SSL connection") if $debug;
      $$conn = IO::Socket::INET->new(
         Proto           => "tcp",
         PeerAddr        => $host,
         PeerPort        => $port,
      );

      unless ( $$conn ) {
        Log("Error connecting to $host:$port: $@");
        exit;
      }
   } 
   Log("Connected to $host on port $port");

   return 1;
}

sub sslmode {

my $host = shift;
my $port = shift;
my $mode;

   #  Determine whether to make an SSL connection
   #  to the host.  Return 'SSL' if so.

   if ( $port == 143 ) {
      #  Standard non-SSL port
      return '';
   } elsif ( $port == 993 ) {
      #  Standard SSL port
      return 'SSL';
   }
      
   unless ( $ssl_installed ) {
      #  We don't have SSL installed on this machine
      return '';
   }

   #  For any other port we need to determine whether it supports SSL

   my $conn = IO::Socket::SSL->new(
         Proto           => "tcp",
         SSL_verify_mode => 0x00,
         PeerAddr        => $host,
         PeerPort        => $port,
    );

    if ( $conn ) {
       close( $conn );
       $mode = 'SSL';
    } else {
       $mode = '';
    }

   return $mode;
}


#  trim
#
#  remove leading and trailing spaces from a string
sub trim {
 
local (*string) = @_;

   $string =~ s/^\s+//;
   $string =~ s/\s+$//;

   return;
}


#  login
#
#  login in at the source host with the user's name and password
#

sub login {

my $user = shift;
my $pwd  = shift;
my $host = shift;
my $conn = shift;

   Log("Authenticating to $host as $user");
   sendCommand ($conn, "1 LOGIN \"$user\" \"$pwd\"");
   while (1) {
	readResponse ( $conn );
	last if $response =~ /^1 OK/i;
	if ($response =~ /^1 NO|^1 BAD/i) {
           Log ("unexpected LOGIN response: $response");
           return 0;
	}
   }
   Log("Logged in as $user") if $debug;

   return 1;
}


#  logout
#
#  log out from the host
#
sub logout {

my $conn = shift;

   undef @response;
   sendCommand ($conn, "1 LOGOUT");
   while ( 1 ) {
	readResponse ($conn);
	if ( $response =~ /^1 OK/i ) {
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected LOGOUT response: $response");
		last;
	}
   }
   close $conn;
   return;
}

#  getMailboxList
#
#  get a list of the user's mailboxes from the source host
#
sub getMailboxList {

my $conn  = shift;
my $delim = shift;
my @mbxs;
my @mailboxes;

  #  Get a list of the user's mailboxes
  #
  if ( $mbxList ) {
      #  The user has supplied a list of mailboxes so only processes
      #  the ones in that list
      @mbxs = split(/,/, $mbxList);
      foreach $mbx ( @mbxs ) {
         # trim( *mbx );
         push( @mailboxes, $mbx );
      }
      return @mailboxes;
   }

   Log("Get list of mailboxes") if $verbose;

   sendCommand ($conn, "1 LIST \"\" *");
   undef @response;
   while ( 1 ) {
	readResponse ($conn);
	if ( $response =~ /^1 OK/i ) {
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected response: $response");
		return 0;
	}
   }

   @mbxs = ();

   for $i (0 .. $#response) {
        $response[$i] =~ s/\s+/ /;
        if ( $response[$i] =~ /"$/ ) {
           $response[$i] =~ /\* LIST \((.*)\) "(.+)" "(.+)"/i;
           $mbx = $3;
        } elsif ( $response[$i] =~ /\* LIST \((.*)\) NIL (.+)/i ) {
           $mbx   = $2;
        } else {
           $response[$i] =~ /\* LIST \((.*)\) "(.+)" (.+)/i;
           $mbx = $3;
        }

	$mbx =~ s/^\s+//;  $mbx =~ s/\s+$//;

        if ($response[$i] =~ /NOSELECT/i) {
           if ( $include_nosel_mbxs ) {
              $nosel_mbxs{"$mbx"} = 1;
           } else {
              Log("$mbx is set NOSELECT, skipping it");
              next;
           }
        }
	if ($mbx =~ /^\#|^Public Folders/i)  {
	   #  Skip public mbxs
	   next;
	}
	push ( @mbxs, $mbx ) if $mbx ne '';
   }

   return @mbxs;
}

#  exclude_mbxs 
#
#  Exclude certain mailboxes from the list if the user
#  has provided an exclude list with the -e argument

sub exclude_mbxs {

my $mbxs = shift;
my @new_list;
my %exclude;

   foreach my $exclude ( split(/,/, $excludeMbxs ) ) {
      $exclude{"$exclude"} = 1;
   }
   foreach my $mbx ( @$mbxs ) {
      next if $exclude{"$mbx"};
      push( @new_list, $mbx );
   }

   @$mbxs = @new_list;

}

#  getMsgList
#
#  Get a list of the user's messages in the indicated mailbox on
#  the source host
#

sub getMsgList {

my $mailbox = shift;
my $msgs    = shift;
my $conn    = shift;
my $seen;
my $empty;
my $msgnum;
my $from;
my $flags;
my $msgid;

   #  Get a list of the msgs in this mailbox

   @$msgs = ();
   trim( *mailbox );
   sendCommand ($conn, "1 EXAMINE \"$mailbox\"");
   undef @response;
   $empty=0;
   while ( 1 ) {
	readResponse ( $conn );
	if ( $response =~ / 0 EXISTS/i ) { $empty=1; }
	if ( $response =~ /^1 OK/i ) {
		# print STDERR "response $response\n";
		last;
	}
	elsif ( $response !~ /^\*/ ) {
		Log ("unexpected response: $response");
		# print STDERR "Error: $response\n";
		return 0;
	}
   }

   return if $empty;

   sendCommand ( $conn, "1 FETCH 1:* (uid flags internaldate body[header.fields (From Date Message-ID Subject)])");
   undef @response;
   while ( 1 ) {
	readResponse ( $conn );
	if ( $response =~ /^1 OK/i ) {
		# print STDERR "response $response\n";
		last;
	} 
        last if $response =~ /^1 NO|^1 BAD/;
   }

   @$msgs  = ();
   $flags = '';
   for $i (0 .. $#response) {
	last if $response[$i] =~ /^1 OK FETCH complete/i;

        if ($response[$i] =~ /FLAGS/) {
           #  Get the list of flags
           $response[$i] =~ /FLAGS \(([^\)]*)/;
           $flags = $1;
           $flags =~ s/\\Recent|\\Forwarded//ig;
        }

        # if ( $response[$i] =~ /^Message-ID:\s*\<(.+)\>/i ) {
        #  Consider the < and > to be part of the message-id.
        if ( $response[$i] =~ /^Message-ID:\s*(.+)/i ) {
           $msgid = $1;
        }

        if ( $response[$i] =~ /INTERNALDATE/) {
           $response[$i] =~ /INTERNALDATE (.+) BODY/i;
           $date = $1;
           
           $date =~ /"(.+)"/;
           $date = $1;
           $date =~ s/"//g;
        }

        # if ( $response[$i] =~ /\* (.+) [^FETCH]/ ) {
        if ( $response[$i] =~ /\* (.+) FETCH/ ) {
           ($msgnum) = split(/\s+/, $1);
        }

        if ( $msgnum and $date and $msgid ) {
	   push (@$msgs,"$msgid||||||$msgnum||||||$flags||||||$date");
           $msgnum=$msgid=$date=$flags='';
        }
   }

}

#  getDatedMsgList
#
#  Get a list of the user's messages in a mailbox on
#  the host which were sent after the specified date
#
sub getDatedMsgList {

my $mailbox = shift;
my $date    = shift;
my $msgs    = shift;
my $conn    = shift;
my ($seen, $empty, @list,$msgid);
my $loops;

    #  Get a list of messages sent after the specified date

    my @list;
    my @msgs;

    if (  $date !~ /-/ ) {
       # Delta in days, convert to DD-MMM-YYYY
       $date = get_date( $sync_since ); 
    }
    sendCommand ($conn, "1 SELECT \"$mailbox\"");
    while ( 1 ) {
        readResponse ($conn);
        if ( $response =~ / EXISTS/i) {
            $response =~ /\* ([^EXISTS]*)/;
            Log("     There are $1 messages in $mailbox");
        } elsif ( $response =~ /^1 OK/i ) {
            last;
        } elsif ( $response !~ /^\*/ ) {
            Log ("unexpected SELECT response: $response");
            return 0;
        }
        if ( $loops++ > 1000 ) {
           Log("No response to SELECT command, skipping this mailbox"); 
           last;
        }
    }

    #
    #  Get list of messages sent before the reference date
    #
    Log("Get messages sent after $date") if $debug;
    $nums = "";
    sendCommand ($conn, "1 SEARCH SENTSINCE \"$date\"");
    while ( 1 ) {
	readResponse ($conn);
	if ( $response =~ /^1 OK/i ) {
	    last;
	}
	elsif ( $response =~ /^\*\s+SEARCH/i ) {
	    ($nums) = ($response =~ /^\*\s+SEARCH\s+(.*)/i);
	}
	elsif ( $response !~ /^\*/ ) {
	    Log ("unexpected SEARCH response: $response");
	    return;
	}
    }
    if ( $nums eq "" ) {
	Log ("     $mailbox has no messages sent after $date") if $debug;
	return;
    }
    # Log("     Msgnums for messages in $mailbox sent after $date $nums") if $debug;
    $nums =~ s/\s+/ /g;
    @msgList = ();
    @msgList = split(/ /, $nums);

    if ($#msgList == -1) {
	#  No msgs in this mailbox
	return 1;
    }

@$msgs  = ();
for $num (@msgList) {

     sendCommand ( $conn, "1 FETCH $num (uid flags internaldate body[header.fields (Message-Id Date)])");
     
     undef @response;
     while ( 1 ) {
	readResponse   ( $conn );
	if   ( $response =~ /^1 OK/i ) {
		last;
	}   
        last if $response =~ /^1 NO|^1 BAD|^\* BYE/;
     }

     $flags = '';
     foreach $_ ( @response ) {
	last   if /^1 OK FETCH complete/i;

          if ( /FLAGS/ ) {
             #  Get the list of flags
             /FLAGS \(([^\)]*)/;
             $flags = $1;
             $flags =~ s/\\Recent|\\Forwarded//ig;
          }
   
          if ( /Message-Id:\s*(.+)/i ) {
             $msgid = $1;
          }

          if ( /INTERNALDATE/) {
             /INTERNALDATE (.+) BODY/i;
             $date = $1;
             $date =~ /"(.+)"/;
             $date = $1;
             $date =~ s/"//g;
          }

          if ( /\* (.+) FETCH/ ) {
             ($msgnum) = split(/\s+/, $1);
          }

          if ( $msgid and $msgnum and $date and $msgid ) {
             push (@$msgs,"$msgid||||||$msgnum||||||$flags||||||$date");
             $msgnum=$msgid=$date=$flags='';
          }
      }
   }

#  @msgs = ();
#  @$msgs = @list;

   return 1;
}

sub createMbx {

my $mbx  = shift;
my $conn = shift;
my $created;

   #  Create the mailbox if necessary

   sendCommand ($conn, "1 CREATE \"$mbx\"");
   while ( 1 ) {
      readResponse ($conn);
      if ( $response =~ /^1 OK/i ) {
         $created = 1;
         last;
      }
      last if $response =~ /already exists/i;
      if ( $response =~ /^1 NO|^1 BAD/ ) {
         Log ("Error creating $mbx: $response");
         last;
      }

   }
   Log("Created mailbox $mbx") if $created;
}

sub fetchMsg {

my $msgnum = shift;
my $conn   = shift;
my $message;

   sendCommand( $conn, "1 FETCH $msgnum (rfc822)");
   while (1) {
	readResponse ($conn);
	if ( $response =~ /^1 BAD|^1 NO/i ) {
           Log("Unexpected FETCH response: $response");
           return '';
        }
	if ( $response =~ /^1 OK/i ) {
		$size = length($message);
		last;
	} 
	elsif ($response =~ /message number out of range/i) {
		Log ("Error fetching uid $uid: out of range",2);
		$stat=0;
		last;
	}
	elsif ($response =~ /Bogus sequence in FETCH/i) {
		Log ("Error fetching uid $uid: Bogus sequence in FETCH",2);
		$stat=0;
		last;
	}
	elsif ( $response =~ /message could not be processed/i ) {
		Log("Message could not be processed, skipping it ($user,msgnum $msgnum,$dstMbx)");
		push(@errors,"Message could not be processed, skipping it ($user,msgnum $msgnum,$dstMbx)");
		$stat=0;
		last;
	}
	elsif 
	   ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{[0-9]+\}/i) {
		($len) = ($response =~ /^\*\s+$msgnum\s+FETCH\s+\(.*RFC822\s+\{([0-9]+)\}/i);
		$cc = 0;
		$message = "";
		while ( $cc < $len ) {
			$n = 0;
			$n = read ($conn, $segment, $len - $cc);
			if ( $n == 0 ) {
				Log ("unable to read $len bytes");
				return 0;
			}
			$message .= $segment;
			$cc += $n;
		}
	}
   }

   return $message;

}

sub fetchMsgFlags {

my $msgnum = shift;
my $conn   = shift;
my $flags;

   #  Read the IMAP flags for a message

   sendCommand( $conn, "1 FETCH $msgnum (flags)");
   while (1) {
        readResponse ($conn);
        if ( $response =~ /^1 OK|^1 BAD|^1 NO/i ) {
           last;
        }
        if ( $response =~ /\* $msgnum FETCH \(FLAGS \((.+)\)\)/i ) {
           $flags = $1;
           Log("   $msgnum - flags $flags") if $verbose;
        }
   }

   return $flags;
}

sub usage {

   print STDOUT "usage:\n";
   print STDOUT " imapsync -S sourceHost/sourceUser/sourcePassword\n";
   print STDOUT "          -D destHost/destUser/destPassword\n";
   print STDOUT "          -d debug\n";
   print STDOUT "          -L logfile\n";
   print STDOUT "          -s <since> Sync messages since this date (DD-MMM-YYYY) or number of days ago\n";
   print STDOUT "          -m mailbox list (eg \"Inbox, Drafts, Notes\". Default is all mailboxes)\n";
   print STDOUT "          -e exclude mailbox list\n";
   print STDOUT "          -n do not delete messages from destination\n";
   exit;

}

sub processArgs {

   if ( !getopts( "dvS:D:L:m:e:hIx:y:FM:s:nNQ" ) ) {
      usage();
   }

   ($sourceHost,$sourceUser,$sourcePwd) = split(/\//, $opt_S);
   ($destHost,  $destUser,  $destPwd)   = split(/\//, $opt_D);
   $mbxList     = $opt_m;
   $excludeMbxs = $opt_e;
   $logfile     = $opt_L;
   $mbx_map_fn  = $opt_M;
   $sync_since  = $opt_s;
   $no_deletes  = 1 if $opt_n;
   $debug    = 1 if $opt_d;
   $verbose  = 1 if $opt_v;
   $showIMAP = 1 if $opt_I;
   $include_nosel_mbxs = 1 if $opt_N;

   usage() if $opt_h;

}

sub findMsg {

my $msgid = shift;
my $conn  = shift;
my $msgnum;

   # Search a mailbox on the server for a message by its msgid.

   Log("   Search for $msgid") if $verbose;
   sendCommand ( $conn, "1 SEARCH header Message-Id \"$msgid\"");
   while (1) {
	readResponse ($conn);
	if ( $response =~ /\* SEARCH /i ) {
	   ($dmy, $msgnum) = split(/\* SEARCH /i, $response);
	   ($msgnum) = split(/ /, $msgnum);
	}

	last if $response =~ /^1 OK|^1 NO|^1 BAD/;
	last if $response =~ /complete/i;
   }

   if ( $verbose ) {
      Log("$msgid was not found") unless $msgnum;
   }

   return $msgnum;
}

sub deleteMsg {

my $conn   = shift;
my $msgnum = shift;
my $rc;

   #  Mark a message for deletion by setting \Deleted flag

   Log("   msgnum is $msgnum") if $verbose;

   sendCommand ( $conn, "1 STORE $msgnum +FLAGS (\\Deleted)");
   while (1) {
        readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
	   $rc = 1;
	   Log("   Marked $msgid for delete") if $verbose;
	   last;
	}

	if ( $response =~ /^1 BAD|^1 NO/i ) {
	   Log("Error setting \Deleted flag for msg $msgnum: $response");
	   $rc = 0;
	   last;
	}
   }

   return $rc;

}

sub expungeMbx {

my $conn  = shift;
my $mbx   = shift;
my $status;
my $loops;

   #  Remove the messages from a mailbox

   Log("Expunging $mbx mailbox") if $verbose;
   sendCommand ( $conn, "1 SELECT \"$mbx\"");
   while (1) {
        readResponse ($conn);
        if ( $response =~ /^1 OK/ ) {
           $status = 1;
           last;
        }

	if ( $response =~ /^1 NO|^1 BAD/i ) {
	   Log("Error selecting mailbox $mbx: $response");
	   last;
	}
        if ( $loops++ > 1000 ) {
           Log("No response to SELECT command, skipping this mailbox"); 
           last;
        }
   }

   return unless $status;

   sendCommand ( $conn, "1 EXPUNGE");
   while (1) {
        readResponse ($conn);
        last if $response =~ /^1 OK/;

	if ( $response =~ /^1 BAD|^1 NO/i ) {
	   print "Error expunging messages: $response\n";
	   last;
	}
   }

}

sub check_for_adds {

my $source_mbxs = shift;
my $REVERSE     = shift;
my $src         = shift;
my $dst         = shift;
my @sourceMsgs;

   #  Compare the contents of the user's mailboxes on the source
   #  with those on the destination.  Add any new messages to the
   #  destination and update if necessary the flags on the existing
   #  ones.

   Log("Checking for adds & updates");
   my $added=$updated=0;
   foreach my $src_mbx ( @$source_mbxs ) {
        Log("Mailbox $src_mbx");
        if ( $include_nosel_mbxs ) {
           #  If a mailbox was 'Noselect' on the src but the user wants
           #  it created as a regular folder on the dst then do so.  They
           #  don't hold any messages so after creating them we don't need
           #  to do anything else.
           next if $nosel_mbxs{"$src_mbx"};
        }

        expungeMbx( $src, $src_mbx );
        $dst_mbx = mailboxName( $src_mbx,$srcPrefix,$srcDelim,$dstPrefix,$dstDelim );

        #  Record the association between source and dest mailboxes
        $$REVERSE{"$dst_mbx"} = $src_mbx;

        selectMbx( $src_mbx, $src, 'EXAMINE' );

	@sourceMsgs=();

        if ( $sync_since ) {
           getDatedMsgList( $src_mbx, $sync_since, \@sourceMsgs, $src );
        } else {
           getMsgList( $src_mbx, \@sourceMsgs, $src );
        }

        if ( $verbose ) {
          Log("src_mbx $src_mbx has the following messages");
          foreach $_ ( @sourceMsgs ) {
             Log("  $_");
          }
        }

        selectMbx( $dst_mbx, $dst, 'SELECT' );
        my $msgcount = $#sourceMsgs + 1;
        Log("$src_mbx has $msgcount messages");
        foreach $_ ( @sourceMsgs ) {
           Log("   $_") if $verbose;
           ($msgid,$msgnum,$src_flags,$date) = split(/\|\|\|\|\|\|/, $_,5);
           next if $src_flags =~ /\\Deleted/;  # Don't sync deleted messages

           Log("Searching on dst in $dst_mbx for $msgid ($msgnum)") if $verbose;

           my $dst_msgnum = findMsg( $msgid, $dst );
           if ( !$dst_msgnum ) {
              #  The msg doesn't exist in the mailbox on the dst, need to add it.
              $message = fetchMsg( $msgnum, $src );
              next unless $message;
              Log("   Need to insert $msgnum") if $verbose;
              insertMsg( $dst, $dst_mbx, *message, $src_flags, $date, $msgid );
              $added++;
           } else {
             #  The message exists, see if the flags have changed.
             Log("   msgnum=$msgnum exists, fetch its flags") if $verbose;
             $dst_flags = fetchMsgFlags( $dst_msgnum, $dst );

             sort_flags( \$src_flags );
             sort_flags( \$dst_flags );

             unless ( $dst_flags eq $src_flags ) {
                Log("   Updating the flags") if $verbose;
                setFlags( $dst_msgnum, $src_flags, $dst_flags, $dst );
                $updated++;
             }
           }
      }
   }
   return ($added,$updated);
}

sub check_for_deletes {

my $REVERSE = shift;
my $dst = shift;
my $src = shift;
my $deleted=0;
my $total_deletes=0;

   #  Delete any messages on the dst that are no longer on the src.

   return 0 if $no_deletes;

   Log("Checking for messages to delete on the dst");

   if ( %mbx_map ) {
      #  Reverse the mbx mapping
      my $new_map;
      while( my($src,$dst) = each( %mbx_map ) ) {
         $new_map{"$dst"} = $src;
      }
      %mbx_map = %new_map;
   }
   while( my($src,$dst) = each( %mbx_map ) ) {
       Log("Mapping $src  == > $dst");
   }

   my @dst_mbxs = getMailboxList( $dst );
   exclude_mbxs( \@dst_mbxs ) if $excludeMbxs;

   foreach my $dst_mbx ( @dst_mbxs ) {
        Log("Checking $dst_mbx for deletes") if $verbose;
        $deleted=0;
        ## $src_mbx = mailboxName( $dst_mbx,$dstPrefix,$dstDelim,$srcPrefix,$srcDelim );
        $src_mbx = $$REVERSE{"$dst_mbx"};

        if ( $sync_since ) {
           getDatedMsgList( $dst_mbx, $sync_since, \@dstMsgs, $dst );
        } else {
           getMsgList( $dst_mbx, \@dstMsgs, $dst );
        }

        selectMbx( $dst_mbx, $dst, 'SELECT' );
        selectMbx( $src_mbx, $src, 'EXAMINE' );
        foreach $_ ( @dstMsgs ) {
           ($msgid,$dst_msgnum,$dst_flags,$date) = split(/\|\|\|\|\|\|/, $_,5);
           if ( $verbose ) {
              Log("   msgid      $msgid");
              Log("   dst msgnum $dst_msgnum");
              Log("   dst_mbx    $dst_mbx");
           }
           my $src_msgnum = findMsg( $msgid, $src );
           if ( !$src_msgnum ) {
              Log("Deleting $msgid from $dst_mbx on the dst");
              if ( deleteMsg( $dst, $dst_msgnum ) ) {
                 #  Need to expunge messages from this mailbox when we're done
                 $total_deletes++;
                 $deleted=1;
              }
           }
        }
        expungeMbx( $dst, $dst_mbx ) if $deleted;
   }
   return $total_deletes;
}

sub namespace {

my $conn      = shift;
my $prefix    = shift;
my $delimiter = shift;
my $mbx_delim = shift;
my $namespace;

   #  Query the server with NAMESPACE so we can determine its
   #  mailbox prefix (if any) and hierachy delimiter.

   if ( $mbx_delim ) {
      #  The user has supplied a mbx delimiter and optionally a prefix.
      Log("Using user-supplied mailbox hierarchy delimiter $mbx_delim");
      ($$delimiter,$$prefix) = split(/\s+/, $mbx_delim);
      return;
   }

   @response = ();
   sendCommand( $conn, "1 NAMESPACE");
   while ( 1 ) {
      readResponse( $conn );
      if ( $response =~ /^1 OK/i ) {
         last;
      } elsif ( $response =~ /NO|BAD/i ) {
         Log("Unexpected response to NAMESPACE command: $response");
         $namespace = 0;
         last;
      }
   }

#  if ( !$namespace and !$opt_x ) {
#     #  Not implemented yet.  Needs more testing
#     #  NAMESPACE is not supported by the server so try to 
#     #  figure out the mbx delimiter and prefix
#     $$delimiter = get_mbx_delimiter( $conn );
#     $$prefix    = get_mbx_prefix( $delimiter, $conn );
#
#     return;
#  }

   foreach $_ ( @response ) {
      if ( /NAMESPACE/i ) {
         my $i = index( $_, '((' );
         my $j = index( $_, '))' );
         my $val = substr($_,$i+2,$j-$i-3);
         ($val) = split(/\)/, $val);
         ($$prefix,$$delimiter) = split( / /, $val );
         $$prefix    =~ s/"//g;
         $$delimiter =~ s/"//g;
         last;
      }
      last if /^1 NO|^1 BAD/;
   }
 
   if ( $verbose ) {
      Log("prefix  $$prefix");
      Log("delim   $$delimiter");
   }

}

sub mailboxName {

my $srcmbx    = shift;
my $srcPrefix = shift;
my $srcDelim  = shift;
my $dstPrefix = shift;
my $dstDelim  = shift;
my $direction = shift;
my $dstmbx;

   #  Adjust the mailbox name if the source and destination server
   #  have different mailbox prefixes or hierarchy delimiters.

   #  Change the mailbox name if the user has supplied mapping rules.
   if ( $mbx_map{"$srcmbx"} ) {
      $srcmbx = $mbx_map{"$srcmbx"}
   }

   $dstmbx = $srcmbx;

   if ( $srcDelim ne $dstDelim ) {
       #  Need to substitute the dst's hierarchy delimiter for the src's one
       $srcDelim = '\\' . $srcDelim if $srcDelim eq '.';
       $dstDelim = "\\" . $dstDelim if $dstDelim eq '.';
       $dstmbx =~ s#$srcDelim#$dstDelim#g;
       $dstmbx =~ s/\\//g;
   }
   if ( $srcPrefix ne $dstPrefix ) {
       #  Replace the source prefix with the dest prefix
       $dstmbx =~ s#^$srcPrefix## if $srcPrefix;
       if ( $dstPrefix ) {
          $dstmbx = "$dstPrefix$dstmbx" unless uc($srcmbx) eq 'INBOX';
       }
       $dstDelim = '\.' if $dstDelim eq '.';
       $dstmbx =~ s#^$dstDelim##;
   } 

   return $dstmbx;
}

sub flags {

my $flags = shift;
my @newflags;
my $newflags;

   #  Make sure the flags list contains only standard
   #  IMAP flags.

   return unless $flags;

   $flags =~ s/\\Recent|\\Forwarded//ig;

   foreach $_ ( split(/\s+/, $flags) ) {
      next unless substr($_,0,1) eq '\\';
      push( @newflags, $_ );
   }

   $newflags = join( ' ', @newflags );

   $newflags =~ s/\\Deleted//ig if $opt_r;
   $newflags =~ s/^\s+|\s+$//g;

   return $newflags;
}

sub createDstMbxs {

my $mbxs = shift;
my $dst  = shift;

   #  Create a corresponding mailbox on the dst for each one
   #  on the src.

   foreach my $mbx ( @$mbxs ) {
      $dstmbx = mailboxName( $mbx,$srcPrefix,$srcDelim,$dstPrefix,$dstDelim );
      createMbx( $dstmbx, $dst ) unless mbxExists( $dstmbx, $dst );
   }
}

sub mbxExists {

my $mbx  = shift;
my $conn = shift;
my $status = 1;
my $loops;

   #  Determine whether a mailbox exists

   sendCommand ($conn, "1 SELECT \"$mbx\"");
   while (1) {
        readResponse ($conn);
        last if $response =~ /^1 OK/i;
        if ( $response =~ /^1 NO|^1 BAD/ ) {
           $status = 0;
           last;
        }
        if ( $loops++ > 1000 ) {
           Log("No response to SELECT command, skipping this mailbox"); 
           last;
        }
   }

   return $status;
}

sub sort_flags {

my $flags = shift;
my @newflags;
my $newflags;

   #  Make sure the flags list contains only standard
   #  IMAP flags.  Sort the list to make comparision
   #  easier.

   return unless $$flags;

   $$flags =~ s/\\Recent|\\Forwarded//ig;
   foreach $_ ( split(/\s+/, $$flags) ) {
      next unless substr($_,0,1) eq '\\';
      push( @newflags, $_ );
   }

   @newflags = sort @newflags;
   $newflags = join( ' ', @newflags );
   $newflags =~ s/^\s+|\s+$//g;

   $$flags = $newflags;
}

sub setFlags {

my $msgnum    = shift;
my $new_flags = shift;
my $old_flags = shift;
my $conn      = shift;
my $rc;

   #  Set the message flags as indicated.

   if ( $verbose ) {
      Log("old flags   $old_flags");
      Log("new flags   $new_flags");
   }

   # Clear the old flags

   sendCommand ( $conn, "1 STORE $msgnum -FLAGS ($old_flags)");
   while (1) {
        readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
           $rc = 1;
           last;
        }

        if ( $response =~ /^1 BAD|^1 NO/i ) {
           Log("Error setting flags for msg $msgnum: $response");
           $rc = 0;
           last;
        }
   }

   # Set the new flags

   sendCommand ( $conn, "1 STORE $msgnum +FLAGS ($new_flags)");
   while (1) {
        readResponse ($conn);
        if ( $response =~ /^1 OK/i ) {
           $rc = 1;
           last;
        }

        if ( $response =~ /^1 BAD|^1 NO/i ) {
           Log("Error setting flags for msg $msgnum: $response");
           $rc = 0;
           last;
        }
   }
}

sub selectMbx {

my $mbx  = shift;
my $conn = shift;
my $type = shift;
my $status;
my $loops;

   #  Select the mailbox. Type is either SELECT (R/W) or EXAMINE (R).

   sendCommand( $conn, "1 $type \"$mbx\"");
   while ( 1 ) {
      readResponse( $conn );
      if ( $response =~ /^1 OK/i ) {
         $status = 1;
         last;
      } elsif ( $response =~ /does not exist/i ) {
         $status = 0;
         last;
      } elsif ( $response =~ /^1 NO|^1 BAD/i ) {
         Log("Unexpected response to SELECT/EXAMINE $mbx command: $response");
         last;
      }
      
      if ( $loops++ > 1000 ) {
         Log("No response to $type command, skipping this mailbox"); 
         last;
      }
   }

   return $status;

}

sub map_mbx_names {

my $mbx_map = shift;
my $srcDelim = shift;
my $dstDelim = shift;

   #  The -M <file> argument causes imapcopy to read the
   #  contents of a file with mappings between source and
   #  destination mailbox names. This permits the user to
   #  to change the name of a mailbox when copying messages.
   #
   #  The lines in the file should be formatted as:
   #       <source mailbox name>: <destination mailbox name>
   #  For example:
   #       Drafts/2008/Save:  Draft_Messages/2008/Save
   #       Action Items: Inbox
   #
   #  Note that if the names contain non-ASCII characters such
   #  as accents or diacritical marks then the Perl module
   #  Unicode::IMAPUtf7 module must be installed.

   return unless $mbx_map_fn;

   unless ( open(MAP, "<$mbx_map_fn") ) {
      Log("Error opening mbx map file $mbx_map_fn: $!");
      exit;
   }
   $use_utf7 = 0;
   while( <MAP> ) {
      chomp;
      s/[\r\n]$//;   # In case we're on Windows
      s/^\s+//;
      next if /^#/;
      next unless $_;
      ($srcmbx,$dstmbx) = split(/\s*:\s*/, $_);

      #  Unless the mailbox name is entirely ASCII we'll have to use
      #  the Modified UTF-7 character set.
      $use_utf7 = 1 unless isAscii( $srcmbx );
      $use_utf7 = 1 unless isAscii( $dstmbx );

      $srcmbx =~ s/\//$srcDelim/g;
      $dstmbx =~ s/\//$dstDelim/g;

      $$mbx_map{"$srcmbx"} = $dstmbx;

   }
   close MAP;

   if ( $use_utf7 ) {
      eval 'use Unicode::IMAPUtf7';
      if ( $@ ) {
         Log("At least one mailbox map contains non-ASCII characters.  This means you");
         Log("have to install the Perl Unicode::IMAPUtf7 module in order to map mailbox ");
         Log("names between the source and destination servers.");
         print "At least one mailbox map contains non-ASCII characters.  This means you\n";
         print "have to install the Perl Unicode::IMAPUtf7 module in order to map mailbox\n";
         print "names between the source and destination servers.\n";
         exit;
      }
   }

   my %temp;
   foreach $srcmbx ( keys %$mbx_map ) {
Log("map has $srcmbx");
      $dstmbx = $$mbx_map{"$srcmbx"};
      Log("Mapping src:$srcmbx to dst:$dstmbx");
      if ( $use_utf7 ){
         #  Encode the name in Modified UTF-7 charset
         $srcmbx = Unicode::IMAPUtf7::imap_utf7_encode( $srcmbx );
         $dstmbx = Unicode::IMAPUtf7::imap_utf7_encode( $dstmbx );
      }
      $temp{"$srcmbx"} = $dstmbx;
   }
   %$mbx_map = %temp;
   %temp = ();

}

sub isAscii {

my $str = shift;
my $ascii = 1;

   #  Determine whether a string contains non-ASCII characters

   my $test = $str;
   $test=~s/\P{IsASCII}/?/g;
   $ascii = 0 unless $test eq $str;

   return $ascii;

}

sub get_date {

my $days = shift;
my $time = time();
my @months = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );

   #  Generate a date in DD-MMM-YYYY format.  The 'days' parameter
   #  indicates how many days to go back from the present date.

   my ($sec,$min,$hr,$mday,$mon,$year,$wday,$yday,$isdst) =
        localtime( $time - $days*86400 );

   $mday = '0' . $mday if length( $mday ) == 1;
   my $month = $months[$mon];
   my $date = $mday . '-' . $month . '-' . ($year+1900);

   return $date;
}

sub fixup_date {

my $date = shift;

   #  Make sure the hrs part of the date is 2 digits.  At least
   #  one IMAP server expects this.

   $$date =~ s/^\s+//;
   $$date =~ /(.+) (.+):(.+):(.+) (.+)/;
   my $hrs = $2;

   return if length( $hrs ) == 2;

   my $newhrs = '0' . $hrs if length( $hrs ) == 1;
   $$date =~ s/ $hrs/ $newhrs/;

}

sub get_mbx_prefix {

my $delim  = shift;
my $conn   = shift;
my %prefixes;
my @prefixes;

   #  Not implemented yet.
   #  Try to figure out whether the server has a mailbox prefix
   #  and if so what it is.

   $$delim = "\\." if $$delim eq '.';

   my @mbxs = getMailboxList( $conn );
   my $num_mbxs = $#mbxs + 1;
   foreach $mbx ( @mbxs ) {
      next if uc( $mbx ) eq 'INBOX';
      ($prefix,$rest) = split(/$$delim/, $mbx);
      $prefixes{"$prefix"}++;
   }

   my $num_prefixes = keys %prefixes;
   if ( $num_prefixes == 1 ) {
      while(($$prefix,$count) = each(%prefixes)) {
          push( @prefixes, "$$prefix|$count");
      }
      ($$prefix,$count) = split(/\|/, pop @prefixes);
      $num_mbxs--;   # Because we skipped the INBOX
      if ( $num_mbxs != $count ) {
         # Did not find a prefix 
         $$prefix = '';
      }      

   }

   $$delim =~ s/\\//;
   $$prefix .= $$delim if $$prefix;

   Log("Determined prefix to be $$prefix") if $debug;

   return $$prefix;

}

sub get_mbx_delimiter {

my $conn = shift;
my $delimiter;

   #  Not implemented yet.
   #  Determine the mailbox hierarchy delimiter 

   sendCommand ($conn, "1 LIST \"\" INBOX");
   undef @response;
   while ( 1 ) {
        readResponse ($conn);
        if ( $response =~ /INBOX/i ) {
           my @terms = split(/\s+/, $response );
           $delimiter = $terms[3];
           $delimiter =~ s/"//g;
        }
        last if $response =~ /^1 OK|^1 BAD|^1 NO/;
        last if $response !~ /^\*/;
   } 

   Log("Determined delimiter to be $delimiter") if $debug;
   return $delimiter;
}
   
